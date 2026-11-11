// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {AsyncVaultHelperLib} from "@concrete-xyz/earn-v2-core/src/lib/AsyncVaultHelperLib.sol";

library AssetCxVaultHelperLib {
    /// @dev Wraps `AsyncVaultHelperLib.claimWithdrawalTo` so the recipient is
    ///      always the calling contract's `msg.sender` (the merchant), matching
    ///      AssetCx's "withdrawals flow back through the merchant" model.
    ///      The async vault's storage (via `ConcreteAsyncVaultImplStorageLib`)
    ///      already encodes the asset, so no `asset` argument is forwarded.
    function claimWithdrawal(address user, uint256[] calldata epochIDs, uint8 decimals) public {
        AsyncVaultHelperLib.claimWithdrawalTo(user, epochIDs, decimals, msg.sender);
    }
}

