// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "pantherswap-peripheral/contracts/interfaces/IPantherRouter02.sol";
import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherPair.sol';
import "../../interfaces/IPantherFactory.sol";


abstract contract PantherSwapV2 is OwnableUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    IPantherRouter02 private constant ROUTER = IPantherRouter02(0x24f7C33ae5f77e2A9ECeed7EA858B4ca2fa1B7eC);
    IPantherFactory private constant FACTORY = IPantherFactory(0x670f55c6284c629c23baE99F585e3f17E8b9FC31);

    address internal constant PANTHER = 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7;
    address internal constant JAWS = 0xdD97AB35e3C0820215bc85a395e13671d84CCBa2;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function __PantherSwapV2_init() internal initializer {
        __Ownable_init();
    }

    function tokenToJawsBNB(address token, uint amount) internal returns(uint flipAmount) {
        if (token == PANTHER) {
            flipAmount = _pantherToJawsBNBFlip(amount);
        } else if (token == JAWS) {
            // Burn JAWS!!
            IBEP20(JAWS).transfer(DEAD, amount);
            flipAmount = 0;
        } else {
            // flip
            flipAmount = _flipToJawsBNBFlip(token, amount);
        }
    }

    function _pantherToJawsBNBFlip(uint amount) private returns(uint flipAmount) {
        swapToken(PANTHER, amount.div(2), JAWS);
        swapToken(PANTHER, amount.sub(amount.div(2)), WBNB);

        flipAmount = generateFlipToken();
    }

    function _flipToJawsBNBFlip(address flip, uint amount) private returns(uint flipAmount) {
        IPantherPair pair = IPantherPair(flip);
        address _token0 = pair.token0();
        address _token1 = pair.token1();
        _approveTokenIfNeeded(flip);
        ROUTER.removeLiquidity(_token0, _token1, amount, 0, 0, address(this), block.timestamp);
        if (_token0 == WBNB) {
            swapToken(_token1, IBEP20(_token1).balanceOf(address(this)), JAWS);
            flipAmount = generateFlipToken();
        } else if (_token1 == WBNB) {
            swapToken(_token0, IBEP20(_token0).balanceOf(address(this)), JAWS);
            flipAmount = generateFlipToken();
        } else {
            swapToken(_token0, IBEP20(_token0).balanceOf(address(this)), JAWS);
            swapToken(_token1, IBEP20(_token1).balanceOf(address(this)), WBNB);
            flipAmount = generateFlipToken();
        }
    }

    function swapToken(address _from, uint _amount, address _to) private {
        if (_from == _to) return;

        address[] memory path;
        if (_from == WBNB || _to == WBNB) {
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else {
            path = new address[](3);
            path[0] = _from;
            path[1] = WBNB;
            path[2] = _to;
        }
        _approveTokenIfNeeded(_from);
        ROUTER.swapExactTokensForTokens(_amount, 0, path, address(this), block.timestamp);
    }

    function generateFlipToken() private returns(uint liquidity) {
        uint amountADesired = IBEP20(JAWS).balanceOf(address(this));
        uint amountBDesired = IBEP20(WBNB).balanceOf(address(this));
        _approveTokenIfNeeded(JAWS);
        _approveTokenIfNeeded(WBNB);

        (,,liquidity) = ROUTER.addLiquidity(JAWS, WBNB, amountADesired, amountBDesired, 0, 0, address(this), block.timestamp);

        // send dust
        IBEP20(JAWS).transfer(msg.sender, IBEP20(JAWS).balanceOf(address(this)));
        IBEP20(WBNB).transfer(msg.sender, IBEP20(WBNB).balanceOf(address(this)));
    }

    function _approveTokenIfNeeded(address token) private {
        if (IBEP20(token).allowance(address(this), address(ROUTER)) == 0) {
            IBEP20(token).safeApprove(address(ROUTER), uint(-1));
        }
    }
}
