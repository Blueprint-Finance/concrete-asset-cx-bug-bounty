# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.1]

### Changed
- `@concrete-xyz/earn-v2-core` bumped from `1.6.0` to `1.7.1`. `ConcreteAsyncVaultImpl` now declares `ID()` / `FLAVOUR()` itself, so `ConcreteAssetCxVaultImpl.ID()` names it in the override list instead of `ConcreteStandardVaultImpl`.
- Contract identities bumped to version 1.7.0 — `ConcreteAssetCxVaultImpl.ID()` `710700`, `AssetCxMultisigStrategy.ID()` `200710700`, `WhitelistHook` `500710700` and `TransferAllowlistHook` `500810700`. The strategy moves ahead of upstream `MultisigStrategy`, which is still at `(1, 6, 0)`.
- `ConcreteAssetCxVaultImpl` and `AssetCxMultisigStrategy` derive `ID()` from `ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), ...)` instead of a hardcoded literal, and both now override `FLAVOUR()` to return 7. `AssetCxMultisigStrategy.FLAVOUR()` previously inherited `2` from `MultisigStrategy` while its hardcoded `ID()` claimed flavour 7.

## [1.4.0] - 2026-09-16

### Added
- **Dolomite liquidation module** — `DolomiteLiquidationModule` with `IDolomiteLiquidationModule`, `DolomiteLiquidationLib` and `DolomiteLiquidationModuleStorageLib`. Two-step liquidation (`initiateLiquidationCollateralSwap` / `finalizeLiquidationAndRepay`) with partial repays, plus unit and Dolomite fork tests. Depends on `@dolomite-exchange/modules-base`.
- **`RedemptionClaimToken`** — ERC20 claim token minted against a pending redemption, with `IRedemptionClaimToken`, `RedemptionClaimTokenStorageLib` and `docs/RedemptionClaimToken-docs.md`.
- **New roles** in `AssetCxRolesLib` — `LIQUIDATION_MODULE_ROLE` (gates mint/burn on `RedemptionClaimToken`) and `LIQUIDATOR_ROLE` (gates the liquidation entrypoints). Both administered by `DEFAULT_ADMIN_ROLE`.
- **`reinitializeV3` upgrade migrations** — one-shot `reinitializer(3)` hooks on `AssetCX` and `ConcreteMerchant` that seed the enumerable role-membership sets on proxies whose roles were granted by a non-enumerable implementation, via a temporary-admin sequence for `DEFAULT_ADMIN_ROLE` and drop-and-re-grant for the remaining roles. Emit `RoleMembershipBackfilled` per role; revert `NotACurrentRoleHolder` / `AdminBackfillMismatch`. Reachable from initializable version 1 or 2, so it runs whether or not the proxy took the 1.3.0 migration.
- **Explicit interfaces** — `IAssetCX`, `IAssetCXVault`, `IConcreteMerchant`, `IDolomiteLiquidationModule`, `IMultisigStrategy`, `IRedemptionClaimToken`, `IWhitelistHook`. Errors, events and natspec move out of the implementations; contracts inherit them so members stay addressable as `Contract.<Member>`.
- **LTV helpers** — extra views and parameters on the Dolomite integration for LTV consumers (CONC-4094).
- **Version tooling** — `.github/workflows/bump_version.yml` and `scripts/bump-version-diff.js`.
- `test_initialize_revertsWhenCallerIsNotFactory` and `test_initialize_onlyEncodedFactoryCanInitialize` test cases for `WhitelistHook`.

### Changed
- Package version bumped from `1.3.0` to `1.4.0`; `@concrete-xyz/earn-v2-core` bumped from `1.5.0` to `1.6.0`; added `@dolomite-exchange/modules-base` and `clones-with-immutable-args`, with matching `remappings.txt` entries.
- `AssetCX` and `ConcreteMerchant` moved from `AccessControlUpgradeable` to `AccessControlEnumerableUpgradeable`, so role membership is enumerable on-chain (`getRoleMemberCount` / `getRoleMember`).
- `WhitelistHook` and `TransferAllowlistHook` refactored to inherit `BaseHook` from `@concrete-xyz/earn-v2-core`: `[factory (20)][vault (20)]` immutable args (`FACTORY()` / `VAULT()`), the factory-only initializer guard (`__BaseHook_init`), contract identity via `FLAVOUR()` / `VERSION()` instead of a hardcoded `ID()`, and the no-op `IHook` defaults. The duplicated implementations, the local `NotFactory` / `ZeroAddress` errors, the `CONTRACT_TYPE` constant and the local constructors were removed.
- Contract identities bumped to version 1.6.0 — `ConcreteAssetCxVaultImpl.ID()` `710600`, `AssetCxMultisigStrategyImpl.ID()` `200710600`, `WhitelistHook` flavour 7 and `TransferAllowlistHook` flavour 8 both at `(1, 6, 0)`.
- Initializers now call the `_unchained` variants directly, so each base is initialized exactly once along the inheritance chain.

### Removed
- `ConcreteMerchant.reinitializeV2` — the 1.3.0 one-shot migration (existing-user-accounts backfill, pausers backfill, legacy pending-yield guard and deprecated-yield-asset promotion). Every live proxy has already been migrated, so the entrypoint is no longer needed; `reinitializeV3` is the only reinitializer on this contract. `AssetCX.reinitializeV2` is unaffected and still available for proxies upgrading from a pre-1.3.0 implementation.

### Security
- **HAL FIND-010 / CONC-4183** — enumerable access control plus a last-admin guard: `_revokeRole` reverts `CannotRemoveLastRoleAdmin` when the call would remove the final `DEFAULT_ADMIN_ROLE` holder, or while membership is still unknown because `reinitializeV3` has not run (`getRoleMemberCount(DEFAULT_ADMIN_ROLE) <= 1`, so an unseeded count of zero fails closed).
- **CONC-4176 / FIND-002** — initialization checks on `DolomiteLiquidationModule` to reject a misconfigured initializer.
- **HAL-018** — defence in depth: residual/dangling ERC20 approvals are reset after the liquidation collateral swap.
- **HAL-030** — configured-LTV health check enforced for non-admin liquidators.
- `WhitelistHook.initialize` is restricted to the factory encoded in the clone's immutable args (reverts `NotFactory` via `BaseHook.__BaseHook_init`), preventing a mempool observer from front-running initialization of an uninitialized clone to seize `DEFAULT_ADMIN`.

## [1.3.0] - 2026-08-11

### Added
- **Timelock integration** — `AssetCX` and `ConcreteMerchant` now implement `ITimelockProtected` (`setTimelock` / `activateTimelock` / `getTimelock`) and gate privileged functions behind an `afterDelay` modifier that requires a matured `Timelock.propose` before execution. Contracts are bound under `CT_ASSETCX` / `CT_MERCHANT`; enforcement starts inactive until `activateTimelock` is called.
- **Pause controls** — `PAUSER_ROLE` plus `pause()` / `unpause()` on both `AssetCX` (via `ERC20PausableUpgradeable`) and `ConcreteMerchant`. `pause()` and grants of `PAUSER_ROLE` are intentionally instant (not timelock-gated); `unpause()` is timelock-gated.
- **`TransferAllowlistHook`** — new clonable transfer hook (`ID = 500810500`, flavour 8) that restricts share transfers to an explicit `allowed[from][to]` allowlist, intended to be combined with `WhitelistHook` via a `HookContainer`. Vault is supplied as an immutable clone arg (HAL FIND-048).
- **Multi-token yield accrual** — yield-token whitelist on `ConcreteMerchant` (`setYieldTokenWhitelisted`, `isYieldTokenWhitelisted`, `getWhitelistedYieldTokens`, capped by `MAX_WHITELISTED_YIELD_TOKENS`) with per-token / per-vault pending accounting (`totalPendingYieldByToken`, `pendingYieldForVaultByToken`, `yieldTokenForPendingYieldNonce`). `initiateYieldAccrual` / `finalizeMerchantYieldAccrual` are now token-aware, letting each strategy convert yield to AssetCX for any whitelisted token.
- **`reinitializeV2` upgrade migrations** — one-shot `reinitializer(2)` hooks on `AssetCX` (pausers backfill) and `ConcreteMerchant` (existing-user-accounts + pausers backfill), for proxies upgrading from a prior implementation.
- **Custom QC user data** — `setUserData` / `userData` on `ConcreteMerchant` with `UserDataSet` event, to store custodian-specific bytes per user.
- **User-account uniqueness guard** — `usedUserAccounts` / `isUserAccountUsed` prevent binding the same on-chain address to more than one `userId` (`UserAccountAlreadyUsed`).
- New events: `YieldTokenWhitelisted`, `UserDataSet`, `AssetCxUpgradeAuthorized`, `MerchantUpgradeAuthorized` (plus `TimelockSet` / `TimelockActivated` from `ITimelockProtected`).
- `ConcreteAssetCxVaultImpl._upgrade` migration hook and `AssetCxStateInitLib.stateUpgradeAssetCxVaultImpl`.

### Changed
- Package version bumped from `1.2.0` to `1.3.0`; dependency `@concrete-xyz/earn-v2-core` pinned to `1.5.0`.
- Namespace migration `@blueprint-finance/earn-v2-core` → `@concrete-xyz/earn-v2-core` across imports and `remappings.txt`.
- `AssetCX` moved from `AccessControlDefaultAdminRules` to plain `AccessControl` with explicit `DEFAULT_ADMIN_ROLE` / `PAUSER_ROLE` wiring, and now extends `ERC20PausableUpgradeable`. `initialize` gains a `timelock_` parameter; `grantRole` routes non-`PAUSER_ROLE` grants through the timelock; `_authorizeUpgrade` is timelock-gated and emits `AssetCxUpgradeAuthorized`.
- `ConcreteMerchant.initialize` signature changed (dropped `yieldAsset_`, added `timelock_`); privileged setters (`setUserAccount`, `setUserVault`, `removeUserVault`, `setUserData`, `setVaultYieldConfig`, `setYieldTokenWhitelisted`, `emergencyMigrateUserAccount`) are now `afterDelay`-gated; `_authorizeUpgrade` timelock-gated and emits `MerchantUpgradeAuthorized`.
- `ConcreteAssetCxVaultImpl.ID()` version bumped and `_initialize` no longer takes an `initialVaultManager`.
- `AssetCxVaultHelperLib.claimWithdrawal` signature simplified (dropped the `asset` parameter).
- `AssetCxRolesLib` removed `MERCHANT_ADMIN_ROLE` and added `PAUSER_ROLE`.
- `WhitelistHook` removed the `vault()` external view (interface sync) and updated imports to the `@concrete-xyz` namespace.
- Storage layout extended: `ConcreteMerchantStorageLib` (per-token yield maps, `userData`, `usedUserAccounts`, whitelisted-token set) and `AssetCxMultisigStrategyStorageLib` (`totalPendingYieldByToken`). In `ConcreteMerchantStorageLib`, the 1.2.0 `pendingYieldPerVault` mapping is renamed in place to `deprecatedPendingYieldPerVault` (alongside `deprecatedYieldAsset` / `deprecatedTotalPendingYield`) to preserve the storage layout; it is no longer written.
- Docs updated for yield-accrual slippage / off-chain validation and the one-to-one `txHash` mint invariant (HAL-038 / HAL-023).

### Security
- **HAL FIND-048** — stricter share-transfer control via `TransferAllowlistHook`; removed from/to vault entries from the transfer allowlist.
- **HAL-038 / HAL-023** — documented off-chain validation for yield-accrual slippage and enforced a one-to-one `txHash → mint` invariant.
- `ConcreteMerchant.claimVaultWithdrawal` now debits `mintedVaultShares` with a saturating (clamp-to-zero) subtraction to avoid an underflow-based DoS.
- Added per-user-account repeat guard to prevent reusing an on-chain address across multiple `userId`s.

## [1.2.0] - 2026-05-21

### Changed
- `ConcreteAssetCxVaultImpl` version bumped
- `AssetCxMultisigStrategyImpl.ID()` — version set on the multisig strategy
- `WhitelistHook.ID()` — version set on the hook

## [1.2.0-beta.2] - 2026-05-19

### Added
- `audit/scope/README.md` — audit scope documentation for the v1.2.0-beta release
- `ConcreteAssetCxVaultImpl.ID()` — new `public pure virtual override` returning encoded implementation identifier `710000` (contractType=0, flavour=7, version=1.0.0)
- `WhitelistHook.VAULT` — immutable vault binding; `vault()` external view satisfying the `IHook` 1.4 interface
- `WhitelistHook.preTransfer` / `postTransfer` — no-op hooks required by `IHook` 1.4; whitelist is intentionally not enforced on transfers
- `test_constructor_revertsWhenVaultIsZero` test case for `WhitelistHook`

### Changed
- Package renamed from `@blueprint-finance/asset-cx` to `@concrete-xyz/asset-cx`
- Version bumped from `1.0.1` to `1.2.0-beta.2`
- Dependency `@blueprint-finance/earn-v2-core@1.0.2-beta.2` replaced by `@concrete-xyz/earn-v2-core@^1.4.0-beta.0`
- `.npmrc` registry scope updated from `@blueprint-finance` to `@concrete-xyz`
- `remappings.txt` updated to resolve `@blueprint-finance/earn-v2-core` from `node_modules/@concrete-xyz/earn-v2-core`
- `ConcreteAssetCxVaultImpl._initialize` extended with `IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration calldata defaultEnforcedVaultConfig` parameter, forwarded to `super._initialize`
- `WhitelistHook` constructor changed from `(address _admin)` to `(address _vault, address _admin)`; passing `address(0)` as `_vault` reverts with `ZeroAddress`
- `WhitelistHook.preDeposit` / `preMint` extended from 4-arg to 5-arg (`caller, assets, shares, receiver, someId`)
- `WhitelistHook.preWithdraw` / `preRedeem` extended from 5-arg to 6-arg (`caller, assets, shares, receiver, owner, someId`)
- Tests migrated from `factory.create(1, …)` / `getImplementationByVersion(1)` to `factory.create(710000, …)` / `getImplementationByVaultImpl(710000)`
- `HooksLibV1` replaced by `HooksLibV2` across all hook and merchant integration tests
- `WhitelistHook` instantiation in tests migrated to the new `(vault, admin)` 2-arg constructor

[1.3.0]: https://www.npmjs.com/package/@concrete-xyz/asset-cx/v/1.3.0
[1.2.0]: https://www.npmjs.com/package/@concrete-xyz/asset-cx/v/1.2.0
[1.2.0-beta.2]: https://www.npmjs.com/package/@concrete-xyz/asset-cx/v/1.2.0-beta.2