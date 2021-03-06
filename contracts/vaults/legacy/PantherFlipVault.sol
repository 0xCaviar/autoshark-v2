// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../../library/legacy/RewardsDistributionRecipient.sol";
import "../../library/legacy/Pausable.sol";
import "../../interfaces/legacy/IStrategyHelper.sol";
import "../../interfaces/IMasterChef.sol";
import "../../interfaces/legacy/IPantherVault.sol";
import "../../interfaces/IJawsMinter.sol";
import "../../interfaces/legacy/IStrategyLegacy.sol";

contract pantherFlipVault is IStrategyLegacy, RewardsDistributionRecipient, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /* ========== STATE VARIABLES ========== */
    IPantherVault public rewardsToken;
    IBEP20 public stakingToken;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 24 hours;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    /* ========== PANTHER     ============= */
    address private constant PANTHER = 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7;
    IMasterChef private constant PANTHER_MASTER_CHEF = IMasterChef(0x058451C62B96c594aD984370eDA8B6FD7197bbd4);
    uint public poolId;
    address public keeper = 0x793074D9799DC3c6039F8056F1Ba884a73462051;
    mapping (address => uint) public depositedAt;

    /* ========== JAWS HELPER / MINTER ========= */
    IStrategyHelper public helper = IStrategyHelper(0x154d803C328fFd70ef5df52cb027d82821520ECE);
    IJawsMinter public minter;


    /* ========== CONSTRUCTOR ========== */

    constructor(uint _pid) public {
        (address _token,,,) = PANTHER_MASTER_CHEF.poolInfo(_pid);
        stakingToken = IBEP20(_token);
        stakingToken.safeApprove(address(PANTHER_MASTER_CHEF), uint(~0));
        poolId = _pid;

        rewardsDistribution = msg.sender;
        setMinter(IJawsMinter(0x0B4A714AAf59E46cb1900E3C031017Fd72667EfE));
        setRewardsToken(0x9a8235aDA127F6B5532387A029235640D1419e8D);
    }

    /* ========== VIEWS ========== */
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balance() override external view returns (uint) {
        return _totalSupply;
    }

    function balanceOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function principalOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function withdrawableBalanceOf(address account) override public view returns (uint) {
        return _balances[account];
    }

    // return pantherAmount, jawsAmount, 0
    function profitOf(address account) override public view returns (uint _usd, uint _jaws, uint _bnb) {
        uint pantherVaultPrice = rewardsToken.priceShare();
        uint _earned = earned(account);
        uint amount = _earned.mul(pantherVaultPrice).div(1e18);

        if (address(minter) != address(0) && minter.isMinter(address(this))) {
            uint performanceFee = minter.performanceFee(amount);
            // panther amount
            _usd = amount.sub(performanceFee);

            uint bnbValue = helper.tvlInBNB(PANTHER, performanceFee);
            // jaws amount
            _jaws = minter.amountJawsToMint(bnbValue);
        } else {
            _usd = amount;
            _jaws = 0;
        }

        _bnb = 0;
    }

    function tvl() override public view returns (uint) {
        uint stakingTVL = helper.tvl(address(stakingToken), _totalSupply);

        uint price = rewardsToken.priceShare();
        uint earned = rewardsToken.balanceOf(address(this)).mul(price).div(1e18);
        uint rewardTVL = helper.tvl(PANTHER, earned);

        return stakingTVL.add(rewardTVL);
    }

    function tvlStaking() external view returns (uint) {
        return helper.tvl(address(stakingToken), _totalSupply);
    }

    function tvlReward() external view returns (uint) {
        uint price = rewardsToken.priceShare();
        uint earned = rewardsToken.balanceOf(address(this)).mul(price).div(1e18);
        return helper.tvl(PANTHER, earned);
    }

    function apy() override public view returns(uint _usd, uint _jaws, uint _bnb) {
        uint dailyAPY = helper.compoundingAPY(poolId, 365 days).div(365);

        uint pantherAPY = helper.compoundingAPY(0, 1 days);
        uint pantherDailyAPY = helper.compoundingAPY(0, 365 days).div(365);

        // let x = 0.5% (daily flip apr)
        // let y = 0.87% (daily panther apr)
        // sum of yield of the year = x*(1+y)^365 + x*(1+y)^364 + x*(1+y)^363 + ... + x
        // ref: https://en.wikipedia.org/wiki/Geometric_series
        // = x * (1-(1+y)^365) / (1-(1+y))
        // = x * ((1+y)^365 - 1) / (y)

        _usd = dailyAPY.mul(pantherAPY).div(pantherDailyAPY);
        _jaws = 0;
        _bnb = 0;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
        rewardPerTokenStored.add(
            lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
        );
    }

    function earned(address account) public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function _deposit(uint256 amount, address _to) private nonReentrant notPaused updateReward(_to) {
        require(amount > 0, "amount");
        _totalSupply = _totalSupply.add(amount);
        _balances[_to] = _balances[_to].add(amount);
        depositedAt[_to] = block.timestamp;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        PANTHER_MASTER_CHEF.deposit(poolId, amount, 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554);
        emit Staked(_to, amount);

        _harvest();
    }

    function deposit(uint256 amount) override public {
        _deposit(amount, msg.sender);
    }

    function depositAll() override external {
        deposit(stakingToken.balanceOf(msg.sender));
    }

    function withdraw(uint256 amount) override public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "amount");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        PANTHER_MASTER_CHEF.withdraw(poolId, amount);

        if (address(minter) != address(0) && minter.isMinter(address(this))) {
            uint _depositedAt = depositedAt[msg.sender];
            uint withdrawalFee = minter.withdrawalFee(amount, _depositedAt);
            if (withdrawalFee > 0) {
                uint performanceFee = withdrawalFee.div(100);
                minter.mintFor(address(stakingToken), withdrawalFee.sub(performanceFee), performanceFee, msg.sender, _depositedAt);
                amount = amount.sub(withdrawalFee);
            }
        }

        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);

        _harvest();
    }

    function withdrawAll() override external {
        uint _withdraw = withdrawableBalanceOf(msg.sender);
        if (_withdraw > 0) {
            withdraw(_withdraw);
        }
        getReward();
    }

    function getReward() override public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.withdraw(reward);
            uint pantherBalance = IBEP20(PANTHER).balanceOf(address(this));

            if (address(minter) != address(0) && minter.isMinter(address(this))) {
                uint performanceFee = minter.performanceFee(pantherBalance);
                minter.mintFor(PANTHER, 0, performanceFee, msg.sender, depositedAt[msg.sender]);
                pantherBalance = pantherBalance.sub(performanceFee);
            }

            IBEP20(PANTHER).safeTransfer(msg.sender, pantherBalance);
            emit RewardPaid(msg.sender, pantherBalance);
        }
    }

    function harvest() override public {
        PANTHER_MASTER_CHEF.withdraw(poolId, 0);
        _harvest();
    }

    function _harvest() private {
        uint pantherAmount = IBEP20(PANTHER).balanceOf(address(this));
        uint _before = rewardsToken.sharesOf(address(this));
        rewardsToken.deposit(pantherAmount);
        uint amount = rewardsToken.sharesOf(address(this)).sub(_before);
        if (amount > 0) {
            _notifyRewardAmount(amount);
        }
    }

    function info(address account) override external view returns(UserInfo memory) {
        UserInfo memory userInfo;

        userInfo.balance = _balances[account];
        userInfo.principal = _balances[account];
        userInfo.available = withdrawableBalanceOf(account);

        Profit memory profit;
        (uint usd, uint jaws, uint bnb) = profitOf(account);
        profit.usd = usd;
        profit.jaws = jaws;
        profit.bnb = bnb;
        userInfo.profit = profit;

        userInfo.poolTVL = tvl();

        APY memory poolAPY;
        (usd, jaws, bnb) = apy();
        poolAPY.usd = usd;
        poolAPY.jaws = jaws;
        poolAPY.bnb = bnb;
        userInfo.poolAPY = poolAPY;

        return userInfo;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function setKeeper(address _keeper) external {
        require(msg.sender == _keeper || msg.sender == owner(), 'auth');
        require(_keeper != address(0), 'zero address');
        keeper = _keeper;
    }

    function setMinter(IJawsMinter _minter) public onlyOwner {
        // can zero
        minter = _minter;
        if (address(_minter) != address(0)) {
            IBEP20(PANTHER).safeApprove(address(_minter), 0);
            IBEP20(PANTHER).safeApprove(address(_minter), uint(~0));

            stakingToken.safeApprove(address(_minter), 0);
            stakingToken.safeApprove(address(_minter), uint(~0));
        }
    }

    function setRewardsToken(address _rewardsToken) private onlyOwner {
        require(address(rewardsToken) == address(0), "set rewards token already");

        rewardsToken = IPantherVault(_rewardsToken);

        IBEP20(PANTHER).safeApprove(_rewardsToken, 0);
        IBEP20(PANTHER).safeApprove(_rewardsToken, uint(~0));
    }

    function setHelper(IStrategyHelper _helper) external onlyOwner {
        require(address(_helper) != address(0), "zero address");
        helper = _helper;
    }

    function notifyRewardAmount(uint256 reward) override public onlyRewardsDistribution {
        _notifyRewardAmount(reward);
    }

    function _notifyRewardAmount(uint256 reward) private updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint _balance = rewardsToken.sharesOf(address(this));
        require(rewardRate <= _balance.div(rewardsDuration), "reward");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    function recoverBEP20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken) && tokenAddress != address(rewardsToken), "tokenAddress");
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(periodFinish == 0 || block.timestamp > periodFinish, "period");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}