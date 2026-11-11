// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {AssetCX} from "../AssetCX.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";

library ConcreteMerchantStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.ConcreteMerchant")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant CONCRETE_MERCHANT_STORAGE_LOCATION =
        0xbe6fb702577dfbdfe92ac8b5f55992faea1aa489ccbc4a455f42360c53f54800;

    struct VaultYieldConfig {
        address strategy;
        address yieldMultisig;
    }

    struct Storage {
        AssetCX assetCX;
        IERC4626 assetCXVault;
        /// @custom:deprecated Single-token yield asset from pre v2 design.
        ///  Retained ONLY to preserve the EIP-7201 storage layout
        IERC20 deprecatedYieldAsset;
        uint256 totalPendingQCRedemption;
        /// @custom:deprecated Pre-V2 - Field kept solely to preserve the
        ///  EIP-7201 storage layout.
        uint256 deprecatedTotalPendingYield;
        uint256 nextYieldNonce;
        mapping(address vault => VaultYieldConfig config) vaultYieldConfigs;
        mapping(bytes32 userId => address account) userAccounts;
        mapping(bytes32 userId => IERC4626 vault) userVaults;
        mapping(bytes32 userId => uint256 mintedAmount) totalMintedPerUser;
        mapping(bytes32 userId => uint256 burnedAmount) totalBurnedPerUser;
        mapping(bytes32 userId => uint256 pendingQCRedemption) pendingQCRedemptionPerUser;
        mapping(bytes32 userId => uint256 ctShares) mintedVaultShares;
        mapping(uint256 nonce => uint256 amount) pendingYieldByNonce;
        mapping(bytes32 txHash => uint256 amount) qcTxToAmount;
        mapping(address receiver => uint256 amount) pendingAssetCxRedemptionPerReceiver;
        /// @custom:deprecated Pre-V2 - Field kept solely
        ///  to preserve the EIP-7201 storage layout.
        mapping(address vault => uint256 amount) deprecatedPendingYieldPerVault;
        mapping(bytes32 userId => bytes data) userData;
        mapping(address account => bool used) usedUserAccounts;
        /// @notice Set of every ERC-20 currently authorised as a yield token.
        /// @dev Hard-capped at `ConcreteMerchant.MAX_WHITELISTED_YIELD_TOKENS`
        EnumerableSet.AddressSet whitelistedYieldTokens;
        mapping(uint256 nonce => address token) pendingYieldTokenByNonce;
        mapping(address token => uint256 amount) totalPendingYieldByToken;
        mapping(address vault => mapping(address token => uint256 amount)) pendingYieldPerVaultByToken;
    }

    function fetch() internal pure returns (Storage storage $) {
        assembly {
            $.slot := CONCRETE_MERCHANT_STORAGE_LOCATION
        }
    }

    function storageLocation() internal pure returns (bytes32) {
        return CONCRETE_MERCHANT_STORAGE_LOCATION;
    }
}

