// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

library AssetCxRolesLib {
    /// Role granted to the ConcreteMerchant contract; gates mint/burn on AssetCX
    /// and deposit/mint/claimWithdrawal on the AssetCx vault.
    /// Administered by `ConcreteV2RolesLib.ROLE_ADMIN` on the vault and by
    /// `DEFAULT_ADMIN_ROLE` on the AssetCX token.
    bytes32 public constant MERCHANT_ROLE = keccak256("MERCHANT_ROLE");

    /// Whitelist management role - can add/remove users from whitelist
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");

    /// Role granted to the DolomiteLiquidationModule on the RedemptionClaimToken;
    /// gates mint/burn. Administered by `DEFAULT_ADMIN_ROLE`.
    bytes32 public constant LIQUIDATION_MODULE_ROLE = keccak256("LIQUIDATION_MODULE_ROLE");

    /// Role gating the liquidation entrypoints on the DolomiteLiquidationModule
    /// (`initiateLiquidationCollateralSwap` / `finalizeLiquidationAndRepay`).
    /// Administered by `DEFAULT_ADMIN_ROLE`.
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    /// Emergency-stop role. Holders can `pause()` immediately and queue an
    /// `unpause()` proposal through the Timelock (TIER_2). Grants of this
    /// role are intentionally exempted from the timelock so a fresh pauser
    /// can be onboarded without delay during an incident.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
}
