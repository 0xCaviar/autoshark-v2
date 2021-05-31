// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/*

*
* MIT License
* ===========
*
* Copyright (c) 2020 AutoSharkFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import {PoolConstant} from "../library/PoolConstant.sol";
import "pantherswap-peripheral/contracts/interfaces/IPantherRouter02.sol";
import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherPair.sol';
import "../interfaces/IStrategy.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IJawsMinter.sol";
import "../zap/IZap.sol";

import "./VaultController.sol";
import "./SimpleVaultZap.sol";
import "./JawsVaultReferral.sol";

contract VaultFlipToFlip is VaultController, IStrategy, SimpleVaultZap, JawsVaultReferral {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;

    /* ========== CONSTANTS ============= */

    IPantherRouter02 private constant ROUTER = IPantherRouter02(0x24f7C33ae5f77e2A9ECeed7EA858B4ca2fa1B7eC);
    IBEP20 private constant PANTHER = IBEP20(0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7);
    IBEP20 private constant WBNB = IBEP20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IMasterChef private constant PANTHER_MASTER_CHEF = IMasterChef(0x058451C62B96c594aD984370eDA8B6FD7197bbd4);
    PoolConstant.PoolTypes public constant override poolType = PoolConstant.PoolTypes.FlipToFlip;

    uint private constant DUST = 1000;

    /* ========== STATE VARIABLES ========== */

    uint public override pid;

    address private _token0;
    address private _token1;

    uint public totalShares;
    mapping (address => uint) private _shares;
    mapping (address => uint) private _principal;
    mapping (address => uint) private _depositedAt;

    uint public pantherHarvested;

    IZap public zapBSC;

    /* ========== MODIFIER ========== */

    modifier updatePantherHarvested {
        uint before = PANTHER.balanceOf(address(this));
        _;
        uint _after = PANTHER.balanceOf(address(this));
        pantherHarvested = pantherHarvested.add(_after).sub(before);
    }

    /* ========== INITIALIZER ========== */

    function initialize(uint _pid, address _zapBSC) external initializer {
        require(_pid != 0, "VaultFlipToFlip: pid must not be zero");

        (address _token,,,) = PANTHER_MASTER_CHEF.poolInfo(_pid);
        __VaultController_init(IBEP20(_token));
        __JawsReferral_init();
        setFlipToken(_token);
        pid = _pid;
        zapBSC = IZap(_zapBSC);

        PANTHER.safeApprove(address(ROUTER), 0);
        PANTHER.safeApprove(address(ROUTER), uint(~0));
        PANTHER.safeApprove(address(zapBSC), uint(-1));
        IBEP20(address(WBNB)).safeApprove(address(zapBSC), uint(~0));
    }

    /* ========== VIEW FUNCTIONS ========== */

    function totalSupply() external view override returns (uint) {
        return totalShares;
    }

    function balance() public view override returns (uint amount) {
        (amount,) = PANTHER_MASTER_CHEF.userInfo(pid, address(this));
    }

    function balanceOf(address account) public view override returns(uint) {
        if (totalShares == 0) return 0;
        return balance().mul(sharesOf(account)).div(totalShares);
    }

    function withdrawableBalanceOf(address account) public view override returns (uint) {
        return balanceOf(account);
    }

    function sharesOf(address account) public view override returns (uint) {
        return _shares[account];
    }

    function principalOf(address account) public view override returns (uint) {
        return _principal[account];
    }

    function earned(address account) public view override returns (uint) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function depositedAt(address account) external view override returns (uint) {
        return _depositedAt[account];
    }

    function rewardsToken() external view override returns (address) {
        return address(_stakingToken);
    }

    function priceShare() external view override returns(uint) {
        if (totalShares == 0) return 1e18;
        return balance().mul(1e18).div(totalShares);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint _amount, address _referrer) public override {
        _depositTo(_amount, msg.sender, _referrer);
    }

    function depositAll(address _referrer) external override {
        deposit(_stakingToken.balanceOf(msg.sender), _referrer);
    }

    function withdrawAll() external override {
        uint amount = balanceOf(msg.sender);
        uint principal = principalOf(msg.sender);
        uint depositTimestamp = _depositedAt[msg.sender];

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        delete _principal[msg.sender];
        delete _depositedAt[msg.sender];

        amount = _withdrawTokenWithCorrection(amount);
        uint profit = amount > principal ? amount.sub(principal) : 0;

        uint withdrawalFee = canMint() ? _minter.withdrawalFee(principal, depositTimestamp) : 0;
        uint performanceFee = canMint() ? _minter.performanceFee(profit) : 0;
        if (withdrawalFee.add(performanceFee) > DUST) {
            uint mintedShark = _minter.mintFor(address(_stakingToken), withdrawalFee, performanceFee, msg.sender, depositTimestamp);
            payReferralCommission(msg.sender, mintedShark);

            if (performanceFee > 0) {
                emit ProfitPaid(msg.sender, profit, performanceFee);
            }
            amount = amount.sub(withdrawalFee).sub(performanceFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function harvest() external override onlyKeeper {
        _harvest();

        uint before = _stakingToken.balanceOf(address(this));
        uint bnbAmount = zapToWBNB(address(PANTHER), pantherHarvested); // Convert to BNB to save on taxes
        
        zapBSC.zapInToken(address(WBNB), bnbAmount, address(_stakingToken));
        uint harvested = _stakingToken.balanceOf(address(this)).sub(before);

        PANTHER_MASTER_CHEF.deposit(pid, harvested, 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554);
        emit Harvested(harvested);

        pantherHarvested = 0;
    }

    function _harvest() private updatePantherHarvested {
        PANTHER_MASTER_CHEF.withdraw(pid, 0);
    }

    function withdraw(uint shares) external override onlyWhitelisted {
        uint amount = balance().mul(shares).div(totalShares);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);

        amount = _withdrawTokenWithCorrection(amount);
        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, 0);
    }

    // @dev underlying only + withdrawal fee + no perf fee
    function withdrawUnderlying(uint _amount) external {
        uint amount = Math.min(_amount, _principal[msg.sender]);
        uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _principal[msg.sender] = _principal[msg.sender].sub(amount);

        amount = _withdrawTokenWithCorrection(amount);
        uint depositTimestamp = _depositedAt[msg.sender];
        uint withdrawalFee = canMint() ? _minter.withdrawalFee(amount, depositTimestamp) : 0;
        if (withdrawalFee > DUST) {
            uint mintedShark = _minter.mintFor(address(_stakingToken), withdrawalFee, 0, msg.sender, depositTimestamp);
            payReferralCommission(msg.sender, mintedShark);
            amount = amount.sub(withdrawalFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    // @dev profits only (underlying + jaws) + no withdraw fee + perf fee
    function getReward() external override {
        uint amount = earned(msg.sender);
        uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _cleanupIfDustShares();

        amount = _withdrawTokenWithCorrection(amount);
        uint depositTimestamp = _depositedAt[msg.sender];
        uint performanceFee = canMint() ? _minter.performanceFee(amount) : 0;
        if (performanceFee > DUST) {
            uint mintedShark = _minter.mintFor(address(_stakingToken), 0, performanceFee, msg.sender, depositTimestamp);
            payReferralCommission(msg.sender, mintedShark);
            amount = amount.sub(performanceFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit ProfitPaid(msg.sender, amount, performanceFee);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function setFlipToken(address _token) private {
        _token0 = IPantherPair(_token).token0();
        _token1 = IPantherPair(_token).token1();

        _stakingToken.safeApprove(address(PANTHER_MASTER_CHEF), uint(~0));

        IBEP20(_token0).safeApprove(address(ROUTER), 0);
        IBEP20(_token0).safeApprove(address(ROUTER), uint(~0));
        IBEP20(_token1).safeApprove(address(ROUTER), 0);
        IBEP20(_token1).safeApprove(address(ROUTER), uint(~0));
    }

    function _depositTo(uint _amount, address _to, address _referrer) private notPaused updatePantherHarvested {
        uint _pool = balance();
        uint _before = _stakingToken.balanceOf(address(this));
        _stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint _after = _stakingToken.balanceOf(address(this));
        _amount = _after.sub(_before); // Additional check for deflationary tokens
        uint shares = 0;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalShares)).div(_pool);
        }

        if (shares > 0 && address(jawsReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            jawsReferral.recordReferral(msg.sender, _referrer);
        }

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);
        _principal[_to] = _principal[_to].add(_amount);
        _depositedAt[_to] = block.timestamp;

        PANTHER_MASTER_CHEF.deposit(pid, _amount, 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554);
        emit Deposited(_to, _amount);
    }

    function _withdrawTokenWithCorrection(uint amount) private updatePantherHarvested returns (uint) {
        uint before = _stakingToken.balanceOf(address(this));
        PANTHER_MASTER_CHEF.withdraw(pid, amount);
        return _stakingToken.balanceOf(address(this)).sub(before);
    }

    function _cleanupIfDustShares() private {
        uint shares = _shares[msg.sender];
        if (shares > 0 && shares < DUST) {
            totalShares = totalShares.sub(shares);
            delete _shares[msg.sender];
        }
    }

    // Pay referral commission to the referrer who referred this user, based on profit
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(jawsReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = jawsReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                _minter.mintV1(commissionAmount, _user);
                _minter.mintV1(commissionAmount, referrer);
                
                jawsReferral.recordReferralCommission(referrer, commissionAmount);
                jawsReferral.recordReferralCommission(_user, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
                emit ReferralCommissionPaid(referrer, _user, commissionAmount);
            }
        }
    }

    /* ========== SALVAGE PURPOSE ONLY ========== */

    // @dev stakingToken must not remain balance in this contract. So dev should salvage staking token transferred by mistake.
    function recoverToken(address token, uint amount) external override onlyOwner {
        if (token == address(PANTHER)) {
            uint pantherBalance = PANTHER.balanceOf(address(this));
            require(amount <= pantherBalance.sub(pantherHarvested), "VaultFlipToFlip: cannot recover lp's harvested panther");
        }

        IBEP20(token).safeTransfer(owner(), amount);
        emit Recovered(token, amount);
    }
}
