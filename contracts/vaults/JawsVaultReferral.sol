// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

import "pantherswap-peripheral/contracts/interfaces/IPantherRouter02.sol";
import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherPair.sol';
import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherFactory.sol';

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../jaws/IJawsReferral.sol";

abstract contract JawsVaultReferral is OwnableUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;

    // Shark referral contract address
    IJawsReferral public jawsReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate;
    // Max referral commission rate: 10%.

    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    function __JawsReferral_init() internal initializer {
        __Ownable_init();
        referralCommissionRate = 1000;
    }

    function setJawsReferral(IJawsReferral _jawsReferral) public onlyOwner {
        jawsReferral = _jawsReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }
}