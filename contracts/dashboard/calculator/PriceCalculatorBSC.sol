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
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "pantherswap-peripheral/contracts/libraries/PantherOracleLibrary.sol";

import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherFactory.sol';
import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherPair.sol';
import "../../interfaces/AggregatorV3Interface.sol";
import "../../interfaces/IPriceCalculator.sol";
import "../../library/HomoraMath.sol";
import "../../library/PantherSimpleOracle.sol";


contract PriceCalculatorBSC is IPriceCalculator, OwnableUpgradeable {
    using SafeMath for uint;
    using HomoraMath for uint;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant PANTHER = 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7;
    address public constant JAWS = 0xdD97AB35e3C0820215bc85a395e13671d84CCBa2;
    address public constant VAI = 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address public constant JAWS_BNB_V1 = 0x0CC7984B1D6cb4c709A84e012c6d9CD4886e143d;
    address public constant JAWS_BNB_V2 = 0x0CC7984B1D6cb4c709A84e012c6d9CD4886e143d;
    address public constant PANTHER_BNB = 0xC24AD5197DaeFD97DF28C70AcbDF17d9fF92a49B;
    address public constant PANTHER_BUSD = 0xeA0D470d4AF27123Ca870c70CF41853A6e6E8313;
    IPantherFactory private constant factory = IPantherFactory(0x670f55c6284c629c23baE99F585e3f17E8b9FC31);
    
    /* ========== STATE VARIABLES ========== */
    mapping(address => address) private pairTokens;
    mapping(address => address) private tokenFeeds;
    mapping(address => address) private oracleFeeds;
    /* ========== INITIALIZER ========== */
    function initialize() external initializer {
        __Ownable_init();
        setPairToken(VAI, BUSD);
    }
    /* ========== Restricted Operation ========== */
    function setPairToken(address asset, address pairToken) public onlyOwner {
        pairTokens[asset] = pairToken;
    }

    function setTokenFeed(address asset, address feed) public onlyOwner {
        tokenFeeds[asset] = feed;
    }

    function setOracleFeed(address asset, address feed) public onlyOwner {
        oracleFeeds[asset] = feed;
    }

    /* ========== Value Calculation ========== */
    function priceOfBNB() view public returns (uint) {
        (, int price, , ,) = AggregatorV3Interface(tokenFeeds[WBNB]).latestRoundData();
        return uint(price).mul(1e10);
    }

    // @dev we can trust the "unsafe prices" of PANTHER as it has anti-whale
    function priceOfPanther() view public returns (uint) {
        // return PantherSimpleOracle(oracleFeeds[PANTHER]).consult(PANTHER, 1e18).mul(priceOfBNB()).div(1e18);
        (, uint pantherPriceInUSD) = valueOfAsset(PANTHER, 1e18);
        return pantherPriceInUSD;
    }

    function priceOfJaws() view public returns (uint) {
        // return PantherSimpleOracle(oracleFeeds[JAWS]).consult(JAWS, 1e18).mul(priceOfBNB()).div(1e18);
        (, uint jawsPriceInUSD) = valueOfAsset(JAWS, 1e18);
        return jawsPriceInUSD;
    }

    function pricesInUSD(address[] memory assets) public view override returns (uint[] memory) {
        uint[] memory prices = new uint[](assets.length);
        for (uint i = 0; i < assets.length; i++) {
            (, uint valueInUSD) = valueOfAsset(assets[i], 1e18);
            prices[i] = valueInUSD;
        }
        return prices;
    }

    function valueOfAsset(address asset, uint amount) public view override returns (uint valueInBNB, uint valueInUSD) {
        if (asset == address(0) || asset == WBNB) {
            return _oracleValueOf(WBNB, amount);
        } else if (oracleFeeds[asset] != address(0)) {
            return _simpleOracleValueOf(asset, amount);
        } else if (asset == JAWS || asset == JAWS_BNB_V1 || asset == JAWS_BNB_V2 || asset == PANTHER_BNB) {
            return _unsafeValueOfAsset(asset, amount);
        } else if (keccak256(abi.encodePacked(IPantherPair(asset).symbol())) == keccak256("PANTHER-LP")) {
            return _getPairPrice(asset, amount);
        } else {
            return _oracleValueOf(asset, amount);
        }
    }

    function _oracleValueOf(address asset, uint amount) private view returns (uint valueInBNB, uint valueInUSD) {
        (, int price, , ,) = AggregatorV3Interface(tokenFeeds[asset]).latestRoundData();
        valueInUSD = uint(price).mul(1e10).mul(amount).div(1e18);
        valueInBNB = valueInUSD.mul(1e18).div(priceOfBNB());
    }

    function _simpleOracleValueOf(address asset, uint amount) private view returns (uint valueInBNB, uint valueInUSD) {
        valueInBNB = PantherSimpleOracle(oracleFeeds[asset]).consult(asset, amount);
        valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
    }

    function _getPairPrice(address pair, uint amount) private view returns (uint valueInBNB, uint valueInUSD) {
        address token0 = IPantherPair(pair).token0();
        address token1 = IPantherPair(pair).token1();
        uint totalSupply = IPantherPair(pair).totalSupply();
        (uint r0, uint r1, ) = IPantherPair(pair).getReserves();
        uint sqrtK = HomoraMath.sqrt(r0.mul(r1)).fdiv(totalSupply);
        (uint px0,) = _oracleValueOf(token0, 1e18);
        (uint px1,) = _oracleValueOf(token1, 1e18);
        uint fairPriceInBNB = sqrtK.mul(2).mul(HomoraMath.sqrt(px0)).div(2**56).mul(HomoraMath.sqrt(px1)).div(2**56);
        valueInBNB = fairPriceInBNB.mul(amount).div(1e18);
        valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
    }

    function _unsafeValueOfAsset(address asset, uint amount) private view returns (uint valueInBNB, uint valueInUSD) {
        if (asset == address(0) || asset == WBNB) {
            valueInBNB = amount;
            valueInUSD = amount.mul(priceOfBNB()).div(1e18);
        }
        else if (keccak256(abi.encodePacked(IPantherPair(asset).symbol())) == keccak256("PANTHER-LP")) {
            if (IPantherPair(asset).totalSupply() == 0) return (0, 0);
            (uint reserve0, uint reserve1, ) = IPantherPair(asset).getReserves();
            if (IPantherPair(asset).token0() == WBNB) {
                valueInBNB = amount.mul(reserve0).mul(2).div(IPantherPair(asset).totalSupply());
                valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
            } else if (IPantherPair(asset).token1() == WBNB) {
                valueInBNB = amount.mul(reserve1).mul(2).div(IPantherPair(asset).totalSupply());
                valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
            } else {
                (uint token0PriceInBNB,) = valueOfAsset(IPantherPair(asset).token0(), 1e18);
                valueInBNB = amount.mul(reserve0).mul(2).mul(token0PriceInBNB).div(1e18).div(IPantherPair(asset).totalSupply());
                valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
            }
        }
        else {
            address pairToken = pairTokens[asset] == address(0) ? WBNB : pairTokens[asset];
            address pair = factory.getPair(asset, pairToken);
            if (IBEP20(asset).balanceOf(pair) == 0) return (0, 0);
            (uint reserve0, uint reserve1, ) = IPantherPair(pair).getReserves();
            if (IPantherPair(pair).token0() == pairToken) {
                valueInBNB = reserve0.mul(amount).div(reserve1);
            } else if (IPantherPair(pair).token1() == pairToken) {
                valueInBNB = reserve1.mul(amount).div(reserve0);
            } else {
                return (0, 0);
            }
            if (pairToken != WBNB) {
                (uint pairValueInBNB,) = valueOfAsset(pairToken, 1e18);
                valueInBNB = valueInBNB.mul(pairValueInBNB).div(1e18);
            }
            valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
        }
    }
}
