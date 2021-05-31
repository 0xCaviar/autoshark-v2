// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

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

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "pantherswap-peripheral/contracts/interfaces/IPantherRouter02.sol";
// import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";

import "../interfaces/IJawsMinterV2.sol";
import "../interfaces/legacy/IStakingRewards.sol";
import "../dashboard/calculator/PriceCalculatorBSC.sol";
import "../zap/ZapBSC.sol";
import "../vaults/SimpleVaultZap.sol";

contract JawsMinterV2 is IJawsMinterV2, OwnableUpgradeable, SimpleVaultZap {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    address public constant PANTHER = 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant JAWS = 0xdD97AB35e3C0820215bc85a395e13671d84CCBa2;
    address public constant JAWS_BNB = 0x0CC7984B1D6cb4c709A84e012c6d9CD4886e143d;

    address public constant DEPLOYER = 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554;
    address private constant TIMELOCK = 0x85c9162A51E03078bdCd08D4232Bab13ed414cC3;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint public constant FEE_MAX = 10000;

    IPantherRouter02 private constant ROUTER = IPantherRouter02(0x24f7C33ae5f77e2A9ECeed7EA858B4ca2fa1B7eC);
    address public constant dev = 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554;

    /* ========== STATE VARIABLES ========== */

    ZapBSC public zapBSC;
    PriceCalculatorBSC public priceCalculator;

    address public jawsChef;
    mapping(address => bool) private _minters;
    address public _deprecated_helper; // deprecated

    uint public PERFORMANCE_FEE;
    uint public override WITHDRAWAL_FEE_FREE_PERIOD;
    uint public override WITHDRAWAL_FEE;

    uint public override jawsPerProfitBNB;
    uint public jawsPerJawsBNBFlip;   // will be deprecated
    address public JAWS_POOL;
    PantherSimpleOracle public jawsOracle;

    /* ========== MODIFIERS ========== */

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "JawsMinterV2: caller is not the minter");
        _;
    }

    modifier onlyJawsChef {
        require(msg.sender == jawsChef, "JawsMinterV2: caller not the jaws chef");
        _;
    }

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    function initialize(address payable _zapBSC, address _priceCalculator, address _jawsPool, address _jawsOracle) external initializer {
        __Ownable_init();
        WITHDRAWAL_FEE_FREE_PERIOD = 3 days;
        WITHDRAWAL_FEE = 50;
        PERFORMANCE_FEE = 3000;
        JAWS_POOL = _jawsPool;

        jawsPerProfitBNB = 200e18;
        jawsPerJawsBNBFlip = 6e18;

        zapBSC = ZapBSC(_zapBSC);
        priceCalculator = PriceCalculatorBSC(_priceCalculator);
        jawsOracle = PantherSimpleOracle(_jawsOracle);

        IBEP20(JAWS).approve(JAWS_POOL, uint(-1));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferJawsOwner(address _owner) external onlyOwner {
        Ownable(JAWS).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");
        // less 5%
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

    function setJawsChef(address _jawsChef) external onlyOwner {
        require(jawsChef == address(0), "JawsMinterV2: setJawsChef only once");
        jawsChef = _jawsChef;
    }

    /* ========== VIEWS ========== */

    function isMinter(address account) public view override returns (bool) {
        if (IBEP20(JAWS).getOwner() != address(this)) {
            return false;
        }
        return _minters[account];
    }

    function amountJawsToMint(uint bnbProfit) public view override returns (uint) {
        return bnbProfit.mul(jawsPerProfitBNB).div(1e18);
    }

    function amountJawsToMintForJawsBNB(uint amount, uint duration) public view override returns (uint) {
        return amount.mul(jawsPerJawsBNBFlip).mul(duration).div(365 days).div(1e18);
    }

    function withdrawalFee(uint amount, uint depositedAt) external view override returns (uint) {
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint profit) public view override returns (uint) {
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    /* ========== V1 FUNCTIONS ========== */

    function mintFor(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint) external payable override onlyMinter returns (uint mintedAmount) {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        uint beforeTransferAmount = IBEP20(asset).balanceOf(address(this));
        _transferAsset(asset, feeSum);
        uint transferAmount = IBEP20(asset).balanceOf(address(this)).sub(beforeTransferAmount);

        if (asset == JAWS) {
            IBEP20(JAWS).safeTransfer(DEAD, feeSum);
            return 0;
        }

        uint jawsBNBAmount = _zapAssetsToJawsBNB(asset, transferAmount);
        if (jawsBNBAmount == 0) return 0;
        IBEP20(JAWS_BNB).safeTransfer(JAWS_POOL, jawsBNBAmount);
        IStakingRewards(JAWS_POOL).notifyRewardAmount(jawsBNBAmount);
        
        (uint valueInBNB,) = priceCalculator.valueOfAsset(JAWS_BNB, jawsBNBAmount);

        // Update oracle if time has elapsed > 10mins
        if (uint(block.timestamp % 2 ** 32).sub(jawsOracle.blockTimestampLast()) >= jawsOracle.PERIOD()) {
            jawsOracle.update();
        }
        
        uint contribution = valueInBNB.mul(_performanceFee).div(feeSum);
        uint mintJaws = amountJawsToMint(contribution);
        if (mintJaws == 0) return 0;
        _mint(mintJaws, to);
        mintedAmount = mintJaws;
    }

    // @dev will be deprecated
    function mintForJawsBNB(uint amount, uint duration, address to) external override onlyMinter {
        uint mintJaws = amountJawsToMintForJawsBNB(amount, duration);
        if (mintJaws == 0) return;
        _mint(mintJaws, to);
    }

    function mintV1(uint amount, address to) override external onlyMinter {
        BEP20 jaws = BEP20(JAWS);
        jaws.mint(amount);
        jaws.transfer(to, amount);

        // uint sharkForDev = amount.mul(15).div(100);
        // jaws.mint(sharkForDev);
        // When minting for commissions, there's a chance that minted amount is 0
        // if (sharkForDev > 0) {
        //     IStakingRewards(JAWS_POOL).stakeTo(sharkForDev, dev);
        // }
    }

    /* ========== V2 FUNCTIONS ========== */

    function mint(uint amount) external override onlyJawsChef {
        if (amount == 0) return;
        _mint(amount, address(this));
    }

    function safeJawsTransfer(address _to, uint _amount) external override onlyJawsChef {
        if (_amount == 0) return;

        uint bal = IBEP20(JAWS).balanceOf(address(this));
        if (_amount <= bal) {
            IBEP20(JAWS).safeTransfer(_to, _amount);
        } else {
            IBEP20(JAWS).safeTransfer(_to, bal);
        }
    }

    // @dev should be called when determining mint in governance. Jaws is transferred to the timelock contract.
    function mintGov(uint amount) external override onlyOwner {
        if (amount == 0) return;
        _mint(amount, TIMELOCK);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _transferAsset(address asset, uint amount) private {
        if (asset == address(0)) {
            // case) transferred BNB
            require(msg.value >= amount);
        } else {
            IBEP20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _zapAssetsToJawsBNB(address asset, uint feeSum) private returns (uint) {
        uint beforeJawsBNB = IBEP20(JAWS_BNB).balanceOf(address(this));
        if (asset != address(0) && IBEP20(asset).allowance(address(this), address(zapBSC)) == 0) {
            IBEP20(asset).safeApprove(address(zapBSC), uint(-1));
        }
        
        if (asset == address(0)) {   
            zapBSC.zapIn{value : feeSum}(JAWS_BNB);
        }
        else if (keccak256(abi.encodePacked(IPantherPair(asset).symbol())) == keccak256("PANTHER-LP")) {
            // zapBSC.zapOut(asset, IBEP20(asset).balanceOf(address(this)));

            IPantherPair pair = IPantherPair(asset);
            address token0 = pair.token0();
            address token1 = pair.token1();

            uint beforeWbnbBalance = IBEP20(WBNB).balanceOf(address(this));
            uint beforeToken0Balance = IBEP20(token0).balanceOf(address(this));
            uint beforeToken1Balance = IBEP20(token1).balanceOf(address(this));
            _approveTokenIfNeeded(asset);
            _approveTokenIfNeeded(token0);
            _approveTokenIfNeeded(token1);
            _approveTokenIfNeeded(WBNB);

            ROUTER.removeLiquidity(token0, token1, feeSum, 0, 0, address(this), block.timestamp);

            uint token0Balance = IBEP20(token0).balanceOf(address(this)).sub(beforeToken0Balance);
            uint token1Balance = IBEP20(token1).balanceOf(address(this)).sub(beforeToken1Balance);
            
            if (token0 == WBNB) {
                zapToWBNB(token1, token1Balance);
            } else if (token1 == WBNB) {
                zapToWBNB(token0, token0Balance);
            } else {
                zapToWBNB(token0, token0Balance);
                zapToWBNB(token1, token1Balance);
            }
            uint wbnbBalance = IBEP20(WBNB).balanceOf(address(this)).sub(beforeWbnbBalance);
            if (IBEP20(WBNB).allowance(address(this), address(zapBSC)) == 0) {
                IBEP20(WBNB).safeApprove(address(zapBSC), uint(-1));
            }
            zapBSC.zapInToken(WBNB, wbnbBalance, JAWS_BNB);
        }
        else {
            zapBSC.zapInToken(asset, feeSum, JAWS_BNB);
        }

        return IBEP20(JAWS_BNB).balanceOf(address(this)).sub(beforeJawsBNB);
    }

    function _mint(uint amount, address to) private {
        BEP20 tokenJAWS = BEP20(JAWS);

        tokenJAWS.mint(amount);
        if (to != address(this)) {
            tokenJAWS.transfer(to, amount);
        }

        // uint jawsForDev = amount.mul(15).div(100);
        // tokenJAWS.mint(jawsForDev);
        // IStakingRewards(JAWS_POOL).stakeTo(jawsForDev, DEPLOYER);
    }
}
