// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ConcreteMerchant} from "../merchant/ConcreteMerchant.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

/**
 * @title AssetCxMultisigStrategyStorageLib
 * @notice EIP-7201 storage definitions for the AssetCxMultisigStrategy contract
 */
library AssetCxMultisigStrategyStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.AssetCxMultisigStrategy")) - 1)) &
    ///      ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_LOCATION = 0xd73148107e5daa3a03de4b53f078a41bd80a9ee6ba54293314dfd48a26335600;

    struct Storage {
        ConcreteMerchant merchant;
        /// @custom:deprecated Single-token yield asset from the pre-V2 design.
        ///  Retained ONLY to preserve the EIP-7201 storage layout for proxies upgraded
        IERC20 deprecatedYieldAsset;
        mapping(uint256 nonce => uint256 amount) pendingYieldByNonce;
        /// @custom:deprecated Pre-V2 single yield token pending amount.
        uint256 deprecatedTotalYieldPendingFinalization;
        /// @notice Outstanding pending yield denominated in `token` summed across
        ///         every nonce.
        mapping(address token => uint256 amount) totalPendingYieldByToken;
    }

    function fetch() internal pure returns (Storage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}

