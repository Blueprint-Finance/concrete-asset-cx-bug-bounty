// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";

/// @title IAssetCXVault
/// @notice ERC-4626 vault extended with the async-withdrawal surface the merchant relies on.
interface IAssetCXVault is IERC4626 {
    function claimWithdrawal(address user, uint256[] calldata epochIDs) external;

    function getUserEpochRequestInAssets(address user, uint256 epochID) external view returns (uint256);

    function getUserEpochRequest(address user, uint256 epochID) external view returns (uint256);

    function getHook() external view returns (address);
}
