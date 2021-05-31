// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

import "pantherswap-peripheral/contracts/interfaces/IPantherRouter02.sol";

abstract contract SimpleVaultZap {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    IPantherRouter02 private constant ROUTER = IPantherRouter02(0x24f7C33ae5f77e2A9ECeed7EA858B4ca2fa1B7eC);

    address internal constant panther = 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7;
    address private constant _wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function zapToWBNB(address _from, uint _amount) internal returns (uint) {
        if (_from == _wbnb) return 0;
        if (_amount == 0) return 0;

        address[] memory path;
        path = new address[](2);
        path[0] = _from;
        path[1] = _wbnb;

        _approveTokenIfNeeded(_from);

        if (_from == panther) {
            uint before = IBEP20(_wbnb).balanceOf(address(this));
            ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(_amount, 0, path, address(this), block.timestamp);
            uint toBalance = IBEP20(_wbnb).balanceOf(address(this)).sub(before);
            return toBalance;
        } else {
            uint[] memory amounts = ROUTER.swapExactTokensForTokens(_amount, 0, path, address(this), block.timestamp);
            return amounts[amounts.length - 1];
        }
    }

    /* ========== Private Functions ========== */

    function _approveTokenIfNeeded(address token) internal {
        if (IBEP20(token).allowance(address(this), address(ROUTER)) == 0) {
            IBEP20(token).safeApprove(address(ROUTER), uint(~0));
        }
    }
}