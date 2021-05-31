// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

import "pantherswap-peripheral/contracts/interfaces/IPantherRouter02.sol";
import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherPair.sol';
import "../../interfaces/IPantherFactory.sol";

abstract contract PantherSwap {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    IPantherRouter02 private constant ROUTER = IPantherRouter02(0x24f7C33ae5f77e2A9ECeed7EA858B4ca2fa1B7eC);
    IPantherFactory private constant factory = IPantherFactory(0x670f55c6284c629c23baE99F585e3f17E8b9FC31);

    address internal constant panther = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address private constant _jaws = 0xdD97AB35e3C0820215bc85a395e13671d84CCBa2;
    address private constant _wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function jawsBNBFlipToken() internal view returns(address) {
        return factory.getPair(_jaws, _wbnb);
    }

    function tokenToJawsBNB(address token, uint amount) internal returns(uint flipAmount) {
        if (token == panther) {
            flipAmount = _pantherToJawsBNBFlip(amount);
        } else {
            // flip
            flipAmount = _flipToJawsBNBFlip(token, amount);
        }
    }

    function _pantherToJawsBNBFlip(uint amount) private returns(uint flipAmount) {
        swapToken(panther, amount.div(2), _jaws);
        swapToken(panther, amount.sub(amount.div(2)), _wbnb);

        flipAmount = generateFlipToken();
    }

    function _flipToJawsBNBFlip(address token, uint amount) private returns(uint flipAmount) {
        IPantherPair pair = IPantherPair(token);
        address _token0 = pair.token0();
        address _token1 = pair.token1();
        IBEP20(token).safeApprove(address(ROUTER), 0);
        IBEP20(token).safeApprove(address(ROUTER), amount);
        ROUTER.removeLiquidity(_token0, _token1, amount, 0, 0, address(this), block.timestamp);
        if (_token0 == _wbnb) {
            swapToken(_token1, IBEP20(_token1).balanceOf(address(this)), _jaws);
            flipAmount = generateFlipToken();
        } else if (_token1 == _wbnb) {
            swapToken(_token0, IBEP20(_token0).balanceOf(address(this)), _jaws);
            flipAmount = generateFlipToken();
        } else {
            swapToken(_token0, IBEP20(_token0).balanceOf(address(this)), _jaws);
            swapToken(_token1, IBEP20(_token1).balanceOf(address(this)), _wbnb);
            flipAmount = generateFlipToken();
        }
    }

    function swapToken(address _from, uint _amount, address _to) private {
        if (_from == _to) return;

        address[] memory path;
        if (_from == _wbnb || _to == _wbnb) {
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else {
            path = new address[](3);
            path[0] = _from;
            path[1] = _wbnb;
            path[2] = _to;
        }

        IBEP20(_from).safeApprove(address(ROUTER), 0);
        IBEP20(_from).safeApprove(address(ROUTER), _amount);
        ROUTER.swapExactTokensForTokens(_amount, 0, path, address(this), block.timestamp);
    }

    function generateFlipToken() private returns(uint liquidity) {
        uint amountADesired = IBEP20(_jaws).balanceOf(address(this));
        uint amountBDesired = IBEP20(_wbnb).balanceOf(address(this));

        IBEP20(_jaws).safeApprove(address(ROUTER), 0);
        IBEP20(_jaws).safeApprove(address(ROUTER), amountADesired);
        IBEP20(_wbnb).safeApprove(address(ROUTER), 0);
        IBEP20(_wbnb).safeApprove(address(ROUTER), amountBDesired);

        (,,liquidity) = ROUTER.addLiquidity(_jaws, _wbnb, amountADesired, amountBDesired, 0, 0, address(this), block.timestamp);

        // send dust
        IBEP20(_jaws).transfer(msg.sender, IBEP20(_jaws).balanceOf(address(this)));
        IBEP20(_wbnb).transfer(msg.sender, IBEP20(_wbnb).balanceOf(address(this)));
    }
}