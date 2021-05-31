// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
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

import '@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol';
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IJawsMinterV2.sol";
import "../interfaces/IJawsChef.sol";
import "../interfaces/IStrategy.sol";
import "./JawsToken.sol";


contract JawsChef is IJawsChef, OwnableUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    JawsToken public constant JAWS = JawsToken(0xdD97AB35e3C0820215bc85a395e13671d84CCBa2);

    /* ========== STATE VARIABLES ========== */

    address[] private _vaultList;
    mapping(address => VaultInfo) vaults;
    mapping(address => mapping(address => UserInfo)) vaultUsers;

    IJawsMinterV2 public minter;

    uint public startBlock;
    uint public override jawsPerBlock;
    uint public override totalAllocPoint;

    /* ========== MODIFIERS ========== */

    modifier onlyVaults {
        require(vaults[msg.sender].token != address(0), "JawsChef: caller is not on the vault");
        _;
    }

    modifier updateRewards(address vault) {
        VaultInfo storage vaultInfo = vaults[vault];
        if (block.number > vaultInfo.lastRewardBlock) {
            uint tokenSupply = tokenSupplyOf(vault);
            if (tokenSupply > 0) {
                uint multiplier = timeMultiplier(vaultInfo.lastRewardBlock, block.number);
                uint rewards = multiplier.mul(jawsPerBlock).mul(vaultInfo.allocPoint).div(totalAllocPoint);
                vaultInfo.accJawsPerShare = vaultInfo.accJawsPerShare.add(rewards.mul(1e12).div(tokenSupply));
            }
            vaultInfo.lastRewardBlock = block.number;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event NotifyDeposited(address indexed user, address indexed vault, uint amount);
    event NotifyWithdrawn(address indexed user, address indexed vault, uint amount);
    event JawsRewardPaid(address indexed user, address indexed vault, uint amount);

    /* ========== INITIALIZER ========== */

    function initialize(uint _startBlock, uint _jawsPerBlock) external initializer {
        __Ownable_init();

        startBlock = _startBlock;
        jawsPerBlock = _jawsPerBlock;
    }

    /* ========== VIEWS ========== */

    function timeMultiplier(uint from, uint to) public pure returns (uint) {
        return to.sub(from);
    }

    function tokenSupplyOf(address vault) public view returns (uint) {
        return IStrategy(vault).totalSupply();
    }

    function vaultInfoOf(address vault) external view override returns (VaultInfo memory) {
        return vaults[vault];
    }

    function vaultUserInfoOf(address vault, address user) external view override returns (UserInfo memory) {
        return vaultUsers[vault][user];
    }

    function pendingJaws(address vault, address user) public view override returns (uint) {
        UserInfo storage userInfo = vaultUsers[vault][user];
        VaultInfo storage vaultInfo = vaults[vault];

        uint accJawsPerShare = vaultInfo.accJawsPerShare;
        uint tokenSupply = tokenSupplyOf(vault);
        if (block.number > vaultInfo.lastRewardBlock && tokenSupply > 0) {
            uint multiplier = timeMultiplier(vaultInfo.lastRewardBlock, block.number);
            uint jawsRewards = multiplier.mul(jawsPerBlock).mul(vaultInfo.allocPoint).div(totalAllocPoint);
            accJawsPerShare = accJawsPerShare.add(jawsRewards.mul(1e12).div(tokenSupply));
        }
        return userInfo.pending.add(userInfo.balance.mul(accJawsPerShare).div(1e12).sub(userInfo.rewardPaid));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function addVault(address vault, address token, uint allocPoint) public onlyOwner {
        require(vaults[vault].token == address(0), "JawsChef: vault is already set");
        bulkUpdateRewards();

        uint lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        vaults[vault] = VaultInfo(token, allocPoint, lastRewardBlock, 0);
        _vaultList.push(vault);
    }

    function updateVault(address vault, uint allocPoint) public onlyOwner {
        require(vaults[vault].token != address(0), "JawsChef: vault must be set");
        bulkUpdateRewards();

        uint lastAllocPoint = vaults[vault].allocPoint;
        if (lastAllocPoint != allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(lastAllocPoint).add(allocPoint);
        }
        vaults[vault].allocPoint = allocPoint;
    }

    function setMinter(address _minter) external onlyOwner {
        require(address(minter) == address(0), "JawsChef: setMinter only once");
        minter = IJawsMinterV2(_minter);
    }

    function setJawsPerBlock(uint _jawsPerBlock) external onlyOwner {
        bulkUpdateRewards();
        jawsPerBlock = _jawsPerBlock;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function notifyDeposited(address user, uint amount) external override onlyVaults updateRewards(msg.sender) {
        UserInfo storage userInfo = vaultUsers[msg.sender][user];
        VaultInfo storage vaultInfo = vaults[msg.sender];

        uint pending = userInfo.balance.mul(vaultInfo.accJawsPerShare).div(1e12).sub(userInfo.rewardPaid);
        userInfo.pending = userInfo.pending.add(pending);
        userInfo.balance = userInfo.balance.add(amount);
        userInfo.rewardPaid = userInfo.balance.mul(vaultInfo.accJawsPerShare).div(1e12);
        emit NotifyDeposited(user, msg.sender, amount);
    }

    function notifyWithdrawn(address user, uint amount) external override onlyVaults updateRewards(msg.sender) {
        UserInfo storage userInfo = vaultUsers[msg.sender][user];
        VaultInfo storage vaultInfo = vaults[msg.sender];

        uint pending = userInfo.balance.mul(vaultInfo.accJawsPerShare).div(1e12).sub(userInfo.rewardPaid);
        userInfo.pending = userInfo.pending.add(pending);
        userInfo.balance = userInfo.balance.sub(amount);
        userInfo.rewardPaid = userInfo.balance.mul(vaultInfo.accJawsPerShare).div(1e12);
        emit NotifyWithdrawn(user, msg.sender, amount);
    }

    function safeJawsTransfer(address user) external override onlyVaults updateRewards(msg.sender) returns (uint) {
        UserInfo storage userInfo = vaultUsers[msg.sender][user];
        VaultInfo storage vaultInfo = vaults[msg.sender];

        uint pending = userInfo.balance.mul(vaultInfo.accJawsPerShare).div(1e12).sub(userInfo.rewardPaid);
        uint amount = userInfo.pending.add(pending);
        userInfo.pending = 0;
        userInfo.rewardPaid = userInfo.balance.mul(vaultInfo.accJawsPerShare).div(1e12);

        minter.mint(amount);
        minter.safeJawsTransfer(user, amount);
        emit JawsRewardPaid(user, msg.sender, amount);
        return amount;
    }

    function bulkUpdateRewards() public {
        for (uint idx = 0; idx < _vaultList.length; idx++) {
            if (_vaultList[idx] != address(0) && vaults[_vaultList[idx]].token != address(0)) {
                updateRewardsOf(_vaultList[idx]);
            }
        }
    }

    function updateRewardsOf(address vault) public updateRewards(vault) {
    }

    /* ========== SALVAGE PURPOSE ONLY ========== */

    function recoverToken(address _token, uint amount) virtual external onlyOwner {
        require(_token != address(JAWS), "JawsChef: cannot recover JAWS token");
        IBEP20(_token).safeTransfer(owner(), amount);
    }
}
