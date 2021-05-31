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

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IJawsMinter.sol";
import "../interfaces/IJawsChef.sol";

import "../vaults/legacy/JawsPool.sol";
import "../vaults/VaultVenus.sol";
import "./calculator/PriceCalculatorBSC.sol";


contract DashboardBSC is OwnableUpgradeable {
    using SafeMath for uint;
    using SafeDecimal for uint;

    PriceCalculatorBSC public constant priceCalculator = PriceCalculatorBSC(0x542c06a5dc3f27e0fbDc9FB7BC6748f26d54dDb0);

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant JAWS = 0xdD97AB35e3C0820215bc85a395e13671d84CCBa2;
    address public constant PANTHER = 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7;
    address public constant VaultPantherToPanther = 0xEDfcB78e73f7bA6aD2D829bf5D462a0924da28eD;

    IJawsChef private constant jawsChef = IJawsChef(0x40e31876c4322bd033BAb028474665B12c4d04CE);
    JawsPool private constant jawsPool = JawsPool(0xCADc8CB26c8C7cB46500E61171b5F27e9bd7889D);

    /* ========== STATE VARIABLES ========== */

    mapping(address => PoolConstant.PoolTypes) public poolTypes;
    mapping(address => uint) public pantherPoolIds;
    mapping(address => bool) public perfExemptions;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();
    }

    /* ========== Restricted Operation ========== */

    function setPoolType(address pool, PoolConstant.PoolTypes poolType) public onlyOwner {
        poolTypes[pool] = poolType;
    }

    function setPantherPoolId(address pool, uint pid) public onlyOwner {
        pantherPoolIds[pool] = pid;
    }

    function setPerfExemption(address pool, bool exemption) public onlyOwner {
        perfExemptions[pool] = exemption;
    }

    /* ========== View Functions ========== */

    function poolTypeOf(address pool) public view returns (PoolConstant.PoolTypes) {
        return poolTypes[pool];
    }

    /* ========== Utilization Calculation ========== */

    function utilizationOfPool(address pool) public view returns (uint liquidity, uint utilized) {
        if (poolTypes[pool] == PoolConstant.PoolTypes.Venus) {
            return VaultVenus(payable(pool)).getUtilizationInfo();
        }
        return (0, 0);
    }

    /* ========== Profit Calculation ========== */

    function calculateProfit(address pool, address account) public view returns (uint profit, uint profitInBNB) {
        PoolConstant.PoolTypes poolType = poolTypes[pool];
        profit = 0;
        profitInBNB = 0;

        if (poolType == PoolConstant.PoolTypes.JawsStake) {
            // profit as bnb
            (profit,) = priceCalculator.valueOfAsset(address(jawsPool.rewardsToken()), jawsPool.earned(account));
            profitInBNB = profit;
        }
        else if (poolType == PoolConstant.PoolTypes.Jaws) {
            // profit as jaws
            profit = jawsChef.pendingJaws(pool, account);
            (profitInBNB,) = priceCalculator.valueOfAsset(JAWS, profit);
        }
        else if (poolType == PoolConstant.PoolTypes.pantherStake || poolType == PoolConstant.PoolTypes.FlipToFlip || poolType == PoolConstant.PoolTypes.Venus) {
            // profit as underlying
            IStrategy strategy = IStrategy(pool);
            profit = strategy.earned(account);
            (profitInBNB,) = priceCalculator.valueOfAsset(strategy.stakingToken(), profit);
        }
        else if (poolType == PoolConstant.PoolTypes.FlipTopanther || poolType == PoolConstant.PoolTypes.JawsBNB) {
            // profit as panther
            IStrategy strategy = IStrategy(pool);
            profit = strategy.earned(account).mul(IStrategy(strategy.rewardsToken()).priceShare()).div(1e18);
            (profitInBNB,) = priceCalculator.valueOfAsset(PANTHER, profit);
        }
    }

    function profitOfPool(address pool, address account) public view returns (uint profit, uint jaws) {
        (uint profitCalculated, uint profitInBNB) = calculateProfit(pool, account);
        profit = profitCalculated;
        jaws = 0;

        if (!perfExemptions[pool]) {
            IStrategy strategy = IStrategy(pool);
            if (strategy.minter() != address(0)) {
                profit = profit.mul(70).div(100);
                jaws = IJawsMinter(strategy.minter()).amountJawsToMint(profitInBNB.mul(30).div(100));
            }

            if (strategy.jawsChef() != address(0)) {
                jaws = jaws.add(jawsChef.pendingJaws(pool, account));
            }
        }
    }

    /* ========== TVL Calculation ========== */

    function tvlOfPool(address pool) public view returns (uint tvl) {
        if (poolTypes[pool] == PoolConstant.PoolTypes.JawsStake) {
            (, tvl) = priceCalculator.valueOfAsset(address(jawsPool.stakingToken()), jawsPool.balance());
        }
        else {
            IStrategy strategy = IStrategy(pool);
            (, tvl) = priceCalculator.valueOfAsset(strategy.stakingToken(), strategy.balance());

            if (strategy.rewardsToken() == VaultPantherToPanther) {
                IStrategy rewardsToken = IStrategy(strategy.rewardsToken());
                uint jawsrewardsInPanther = rewardsToken.balanceOf(pool).mul(rewardsToken.priceShare()).div(1e18);
                (, uint rewardsInUSD) = priceCalculator.valueOfAsset(address(PANTHER), jawsrewardsInPanther);
                tvl = tvl.add(rewardsInUSD);
            }
        }
    }

    /* ========== Pool Information ========== */

    function infoOfPool(address pool, address account) public view returns (PoolConstant.PoolInfoBSC memory) {
        PoolConstant.PoolInfoBSC memory poolInfo;

        IStrategy strategy = IStrategy(pool);
        (uint pBASE, uint pJAWS) = profitOfPool(pool, account);
        (uint liquidity, uint utilized) = utilizationOfPool(pool);

        poolInfo.pool = pool;
        poolInfo.balance = strategy.balanceOf(account);
        poolInfo.principal = strategy.principalOf(account);
        poolInfo.available = strategy.withdrawableBalanceOf(account);
        poolInfo.tvl = tvlOfPool(pool);
        poolInfo.utilized = utilized;
        poolInfo.liquidity = liquidity;
        poolInfo.pBASE = pBASE;
        poolInfo.pJAWS = pJAWS;

        PoolConstant.PoolTypes poolType = poolTypeOf(pool);
        if (poolType != PoolConstant.PoolTypes.JawsStake && strategy.minter() != address(0)) {
            IJawsMinter minter = IJawsMinter(strategy.minter());
            poolInfo.depositedAt = strategy.depositedAt(account);
            poolInfo.feeDuration = minter.WITHDRAWAL_FEE_FREE_PERIOD();
            poolInfo.feePercentage = minter.WITHDRAWAL_FEE();
        }
        return poolInfo;
    }

    function poolsOf(address account, address[] memory pools) public view returns (PoolConstant.PoolInfoBSC[] memory) {
        PoolConstant.PoolInfoBSC[] memory results = new PoolConstant.PoolInfoBSC[](pools.length);
        for (uint i = 0; i < pools.length; i++) {
            results[i] = infoOfPool(pools[i], account);
        }
        return results;
    }

    /* ========== Portfolio Calculation ========== */

    function stakingTokenValueInUSD(address pool, address account) internal view returns (uint tokenInUSD) {
        PoolConstant.PoolTypes poolType = poolTypes[pool];

        address stakingToken;
        if (poolType == PoolConstant.PoolTypes.JawsStake) {
            stakingToken = JAWS;
        } else {
            stakingToken = IStrategy(pool).stakingToken();
        }

        if (stakingToken == address(0)) return 0;
        (, tokenInUSD) = priceCalculator.valueOfAsset(stakingToken, IStrategy(pool).principalOf(account));
    }

    function portfolioOfPoolInUSD(address pool, address account) internal view returns (uint) {
        uint tokenInUSD = stakingTokenValueInUSD(pool, account);
        (, uint profitInBNB) = calculateProfit(pool, account);
        uint profitInJAWS = 0;

        if (!perfExemptions[pool]) {
            IStrategy strategy = IStrategy(pool);
            if (strategy.minter() != address(0)) {
                profitInBNB = profitInBNB.mul(70).div(100);
                profitInJAWS = IJawsMinter(strategy.minter()).amountJawsToMint(profitInBNB.mul(30).div(100));
            }

            if ((poolTypes[pool] == PoolConstant.PoolTypes.Jaws || poolTypes[pool] == PoolConstant.PoolTypes.JawsBNB
            || poolTypes[pool] == PoolConstant.PoolTypes.FlipToFlip)
                && strategy.jawsChef() != address(0)) {
                profitInJAWS = profitInJAWS.add(jawsChef.pendingJaws(pool, account));
            }
        }

        (, uint profitBNBInUSD) = priceCalculator.valueOfAsset(WBNB, profitInBNB);
        (, uint profitJAWSInUSD) = priceCalculator.valueOfAsset(JAWS, profitInJAWS);
        return tokenInUSD.add(profitBNBInUSD).add(profitJAWSInUSD);
    }

    function portfolioOf(address account, address[] memory pools) public view returns (uint deposits) {
        deposits = 0;
        for (uint i = 0; i < pools.length; i++) {
            deposits = deposits.add(portfolioOfPoolInUSD(pools[i], account));
        }
    }
}
