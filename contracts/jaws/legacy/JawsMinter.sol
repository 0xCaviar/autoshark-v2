// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "../../interfaces/IJawsMinter.sol";
import "../../interfaces/legacy/IStakingRewards.sol";
import "./PantherSwap.sol";
import "../../interfaces/legacy/IStrategyHelper.sol";

contract JawsMinter is IJawsMinter, Ownable, PantherSwap {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    BEP20 private constant jaws = BEP20(0xdD97AB35e3C0820215bc85a395e13671d84CCBa2);
    address public constant dev = 0xe87f02606911223C2Cf200398FFAF353f60801F7;
    IBEP20 private constant WBNB = IBEP20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    uint public override WITHDRAWAL_FEE_FREE_PERIOD = 3 days;
    uint public override WITHDRAWAL_FEE = 50;
    uint public constant FEE_MAX = 10000;

    uint public PERFORMANCE_FEE = 3000; // 30%

    uint public override jawsPerProfitBNB;
    uint public jawsPerJawsBNBFlip;

    address public constant jawsPool = 0xCADc8CB26c8C7cB46500E61171b5F27e9bd7889D;
    IStrategyHelper public helper = IStrategyHelper(0xA84c09C1a2cF4918CaEf625682B429398b97A1a0);

    mapping (address => bool) private _minters;

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "not minter");
        _;
    }

    constructor() public {
        jawsPerProfitBNB = 10e18;
        jawsPerJawsBNBFlip = 6e18;
        jaws.approve(jawsPool, uint(~0));
    }

    function transferJawsOwner(address _owner) external onlyOwner {
        Ownable(address(jaws)).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");   // less 5%
        WITHDRAWAL_FEE = _fee;
    }

    function setPerformanceFee(uint _fee) external onlyOwner {
        require(_fee < 5000, "wrong fee");
        PERFORMANCE_FEE = _fee;
    }

    function setWithdrawalFeeFreePeriod(uint _period) external onlyOwner {
        WITHDRAWAL_FEE_FREE_PERIOD = _period;
    }

    function setMinter(address minter, bool canMint) external override onlyOwner {
        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }

    function setJawsPerProfitBNB(uint _ratio) external onlyOwner {
        jawsPerProfitBNB = _ratio;
    }

    function setJawsPerJawsBNBFlip(uint _jawsPerJawsBNBFlip) external onlyOwner {
        jawsPerJawsBNBFlip = _jawsPerJawsBNBFlip;
    }

    function setHelper(IStrategyHelper _helper) external onlyOwner {
        require(address(_helper) != address(0), "zero address");
        helper = _helper;
    }

    function isMinter(address account) override view public returns(bool) {
        if (jaws.getOwner() != address(this)) {
            return false;
        }

        if (block.timestamp < 1605585600) { // 12:00 SGT 17th November 2020
            return false;
        }
        return _minters[account];
    }

    function amountJawsToMint(uint bnbProfit) override view public returns(uint) {
        return bnbProfit.mul(jawsPerProfitBNB).div(1e18);
    }

    function amountJawsToMintForJawsBNB(uint amount, uint duration) override view public returns(uint) {
        return amount.mul(jawsPerJawsBNBFlip).mul(duration).div(365 days).div(1e18);
    }

    function withdrawalFee(uint amount, uint depositedAt) override view external returns(uint) {
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint profit) override view public returns(uint) {
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    function mintFor(address flip, uint _withdrawalFee, uint _performanceFee, address to, uint) override external onlyMinter {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        IBEP20(flip).safeTransferFrom(msg.sender, address(this), feeSum);

        uint jawsBNBAmount = tokenToJawsBNB(flip, IBEP20(flip).balanceOf(address(this)));
        address flipToken = jawsBNBFlipToken();
        IBEP20(flipToken).safeTransfer(jawsPool, jawsBNBAmount);
        IStakingRewards(jawsPool).notifyRewardAmount(jawsBNBAmount);

        uint contribution = helper.tvlInBNB(flipToken, jawsBNBAmount).mul(_performanceFee).div(feeSum);
        uint mintJaws = amountJawsToMint(contribution);
        mint(mintJaws, to);
    }

    function mintForJawsBNB(uint amount, uint duration, address to) override external onlyMinter {
        uint mintJaws = amountJawsToMintForJawsBNB(amount, duration);
        if (mintJaws == 0) return;
        mint(mintJaws, to);
    }

    function mint(uint amount, address to) private {
        jaws.mint(amount);
        jaws.transfer(to, amount);

        uint jawsForDev = amount.mul(15).div(100);
        jaws.mint(jawsForDev);
        IStakingRewards(jawsPool).stakeTo(jawsForDev, dev);
    }
}