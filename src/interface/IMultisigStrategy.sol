// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/// @title IMultisigStrategy
/// @notice Minimal view of the multisig strategy used by the merchant for yield accrual.
interface IMultisigStrategy {
    function getMultiSig() external view returns (address);
    function getVault() external view returns (address);
    function getNextAccountingNonce() external view returns (uint256);
    function adjustTotalAssets(int256 diff, uint256 accountingNonce_) external;
    function finalizeMerchantYieldAccrual(uint256 nonce, uint256 amountInAsset, address yieldToken) external;
}
