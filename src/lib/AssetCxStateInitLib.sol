// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ACL_OZ_5_2_0_Lib} from "@concrete-xyz/earn-v2-core/src/lib/AccessControlLib.sol";
import {ConcreteV2RolesLib} from "@concrete-xyz/earn-v2-core/src/lib/Roles.sol";
import {AssetCxRolesLib} from "./AssetCxRolesLib.sol";

library AssetCxStateInitLib {
    /// Sets `ROLE_ADMIN` (from earn-v2-core) as the admin of `MERCHANT_ROLE` on the
    /// AssetCx vault, so MERCHANT_ROLE is managed by the same key that manages every
    /// other vault role.
    function stateInitAssetCxVaultImpl() public {
        ACL_OZ_5_2_0_Lib._setRoleAdmin(AssetCxRolesLib.MERCHANT_ROLE, ConcreteV2RolesLib.ROLE_ADMIN);
    }

    /// Upgrade-time counterpart of `stateInitAssetCxVaultImpl`. Kept as an explicit
    /// duplicate rather than delegating to the init function so that future
    /// fresh-deployment-only initialization logic can be added to
    /// `stateInitAssetCxVaultImpl` without an in-place upgrade re-running it and
    /// overwriting existing state with defaults. Only re-asserts the `MERCHANT_ROLE`
    /// administrator; it does not revoke any existing merchants or merchants managers.
    function stateUpgradeAssetCxVaultImpl() public {
        ACL_OZ_5_2_0_Lib._setRoleAdmin(AssetCxRolesLib.MERCHANT_ROLE, ConcreteV2RolesLib.ROLE_ADMIN);
    }
}
