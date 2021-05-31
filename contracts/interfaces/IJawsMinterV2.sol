// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IJawsMinterV2 {
    function isMinter(address) view external returns(bool);
    function amountJawsToMint(uint bnbProfit) view external returns(uint);
    function amountJawsToMintForJawsBNB(uint amount, uint duration) view external returns(uint);
    function withdrawalFee(uint amount, uint depositedAt) view external returns(uint);
    function performanceFee(uint profit) view external returns(uint);
    function mintFor(address flip, uint _withdrawalFee, uint _performanceFee, address to, uint depositedAt) external payable returns (uint mintedAmount);
    function mintForJawsBNB(uint amount, uint duration, address to) external;

    function jawsPerProfitBNB() view external returns(uint);
    function WITHDRAWAL_FEE_FREE_PERIOD() view external returns(uint);
    function WITHDRAWAL_FEE() view external returns(uint);

    function setMinter(address minter, bool canMint) external;
    function mintV1(uint amount, address to) external;

    // V2 functions
    function mint(uint amount) external;
    function safeJawsTransfer(address to, uint256 amount) external;
    function mintGov(uint amount) external;
}