# Docs

## Overview

[Asset]cx is an institutional-grade tokenized asset system that enables qualified custody (QC) assets to access DeFi yield while maintaining custody compliance. The system implements a 1:1 backed ERC-20 token with vault-based yield distribution, multi-signature operational controls, and epoch-based withdrawal queues. All backing assets remain in a single Concrete-managed qualified custody account with full reconciliation across custody, on-chain contracts (including detailed Merchant accounting), and off-chain tracking ledgers.

Tokens:
- **AssetCX (`[asset]cx`)** - one ERC-20 per deployment, minted 1:1 against the QC balance. It is the underlying asset of every vault the merchant serves. In normal operation clients never hold it directly.
- **Vault shares (`ct[asset]cx`)** - each vault is its own ERC-4626 share token. A deployment can have several vaults over the same AssetCX (the default vault plus per-user vaults set with `setUserVault`), so there is one share token per vault. Shares are issued to the client's EVM address; yield accrues to the share price, not the share count.

Versions: repository release 1.4.1, built on `@concrete-xyz/earn-v2-core` 1.7.1. Solidity `^0.8.24`.

The collateralised-liquidation feature (RedemptionClaimToken and liquidation module) is documented in [`liquidation.md`](./liquidation.md).

## Source Files

### Core Contracts
- `src/AssetCX.sol` - ERC20 token with role-based minting/burning, pausable, UUPS upgradeable
- `src/merchant/ConcreteMerchant.sol` - Main merchant contract managing AssetCX supply and vault operations
- `src/implementation/ConcreteAssetCxVault.sol` - ERC4626 async vault implementation for AssetCX
- `src/strategies/AssetCxMultisigStrategy.sol` - Multisig strategy for yield accrual coordination
- `src/hooks/WhitelistHook.sol` - Access control hook for vault operations
- `src/hooks/TransferAllowlistHook.sol` - Transfer hook restricting vault share transfers to allowed pairs
- `src/AssetCXOFTAdapter.sol` - LayerZero OFT adapter for AssetCX on the home chain (lock / unlock)
- `src/AssetCXOFT.sol` - LayerZero OFT token for AssetCX on remote chains (mint / burn)
- `src/liquidations/RedemptionClaimToken.sol`, `src/liquidations/DolomiteLiquidationModule.sol` - Collateralised liquidation, see [`liquidation.md`](./liquidation.md)

### Library Files
- `src/lib/AssetCxRolesLib.sol` - Role definitions (MERCHANT_ROLE, WHITELIST_MANAGER_ROLE, PAUSER_ROLE, LIQUIDATION_MODULE_ROLE, LIQUIDATOR_ROLE)
- `src/lib/ConcreteMerchantStorageLib.sol` - Storage layout for ConcreteMerchant (EIP-7201)
- `src/lib/AssetCxMultisigStrategyStorageLib.sol` - Storage layout for AssetCxMultisigStrategy (EIP-7201)
- `src/lib/AssetCxVaultHelperLib.sol` - Helper functions for vault operations
- `src/lib/AssetCxStateInitLib.sol` - State initialization functions
- `src/lib/RedemptionClaimTokenStorageLib.sol`, `src/lib/DolomiteLiquidationModuleStorageLib.sol`, `src/lib/DolomiteLiquidationLib.sol` - Liquidation, see [`liquidation.md`](./liquidation.md)

### Interfaces
- `src/interface/` - `IAssetCX`, `IConcreteMerchant`, `IAssetCXVault`, `IMultisigStrategy`, `IWhitelistHook`, `IRedemptionClaimToken`, `IDolomiteLiquidationModule`. Errors, events and NatSpec live in the interfaces; the contracts inherit them.

### Inherited from Earn V2
The vault (`ConcreteAsyncVaultImpl`), the strategy (`MultisigStrategy`), the hook base (`BaseHook`), `HookContainer` and the `Timelock` come from `@concrete-xyz/earn-v2-core`, so standard Earn V2 mechanics apply unchanged: cached `totalAssets` and accounting bounds, management and performance fees, allocation, the epoch withdrawal queue and the vault's own timelock surface.

## Main Contracts

### AssetCX (`src/AssetCX.sol`)
UUPS upgradeable, pausable ERC20 token with enumerable access control.

**Functions:**
- `initialize(name, symbol, admin, timelock)` - Initializes token with admin and optional timelock
- `mint(amount)` - Mints tokens to the caller (MERCHANT_ROLE only)
- `burn(amount)` - Burns tokens from the caller (MERCHANT_ROLE only)
- `pause()` / `unpause()` - Pauses / unpauses transfers, mint and burn (PAUSER_ROLE; `unpause` is timelock-gated)
- `grantRole(role, account)` - Timelock-gated for every role except PAUSER_ROLE
- `upgradeToAndCall(newImplementation, data)` - Upgrades implementation (DEFAULT_ADMIN_ROLE, timelock-gated)
- `reinitializeV2(pausers)`, `reinitializeV3(...)` - One-shot upgrade migrations (see [Upgradeability & Storage](#upgradeability--storage))

The last DEFAULT_ADMIN_ROLE holder cannot be revoked or renounce (`CannotRemoveLastRoleAdmin`).

### ConcreteMerchant (`src/merchant/ConcreteMerchant.sol`)
Manages AssetCX supply on behalf of the QC reserve, coordinates with vaults, and handles yield accrual. Mints tokens, deposits into a default or per-user ERC-4626 vault, and burns when QC redemptions are issued.

**Key Functions:**
- `initialize(admin, assetCX, assetCXVault, timelock)` - Sets up core references. The yield-token whitelist starts empty
- `mintAndDeposit(userId, amount, txHash)` - Mints AssetCX and deposits to vault on user behalf based on Qualified Custodian deposit
- `claimVaultWithdrawal(userId, epochID)` - Claims withdrawal on user behalf from vault and burns AssetCX
- `finalizeQCRedemption(userId, amount, txHash)` - Finalizes redemption based on QC transaction
- `redeem(amount, receiver)` - Direct user redemption: transfers AssetCX, burns, records pending to be finalized in QC
- `finalizeAssetCxRedemption(receiver, amount, txHash)` - Finalizes AssetCX redemption based on QC (OPERATOR_ROLE)
- `initiateYieldAccrual(vault, yieldToken, amountInYieldToken, nonce)` - Initiates yield accrual for a whitelisted yield token; transfers it from the strategy to the vault's yield multisig (yield token swapped to ASSET in QC) (called by the vault's configured strategy)
- `finalizeYieldAccrual(vault, nonce, amountInAsset, txHash)` - Finalizes yield accrual - mints AssetCX, which the strategy forwards to its multisig (OPERATOR_ROLE)
- `setUserAccount(userId, user)` - Maps userId to EVM address (MERCHANT_MANAGER_ROLE)
- `setUserVault(userId, vault)` / `removeUserVault(userId)` - Sets / removes per-user private vault override (MERCHANT_MANAGER_ROLE)
- `setUserData(userId, data)` - Stores an opaque per-user blob, not validated (MERCHANT_MANAGER_ROLE)
- `setVaultYieldConfig(vault, strategy, yieldMultisig)` - Configures yield routing for a vault (MERCHANT_MANAGER_ROLE)
- `setYieldTokenWhitelisted(token, whitelisted)` - Adds or removes a yield token from the whitelist (MERCHANT_MANAGER_ROLE)
- `emergencyMigrateUserAccount(userId, newAccount)` - Moves a user to a new address (DEFAULT_ADMIN_ROLE), see [Emergency Account Migration](#emergency-account-migration)
- `pause()` / `unpause()` - Halts / resumes every operational function above (PAUSER_ROLE; `unpause` is timelock-gated)

**Roles:**
- `DEFAULT_ADMIN_ROLE` - Upgrades contract, manages role hierarchy, emergency migration
- `MERCHANT_MANAGER_ROLE` - Manages configuration (users, vaults, yield config)
- `OPERATOR_ROLE` - Executes operations (mint, claim, finalize)
- `PAUSER_ROLE` - Emergency stop

All configuration setters are timelock-gated; the operational functions are not (see [Access Control & Timelock](#access-control--timelock)).

**Configuration rules:**
- User mappings (`setUserAccount`, `setUserVault`, `removeUserVault`) cannot change while the user holds Merchant-minted shares (`UserHasActiveDeposits`). An EVM address can be bound to at most one userId (`UserAccountAlreadyUsed`); rebinding a userId frees its previous address.
- `setUserVault` requires the vault's asset to be AssetCX; without an override the default vault is used.
- Per-vault yield routing (`setVaultYieldConfig`) must be set before any accrual: strategy address and yield multisig per vault. The strategy must report `getVault() == vault`. The yield multisig receives yield tokens in `initiateYieldAccrual` for the off-chain swap. It is stored separately from the strategy's own multisig (`IMultisigStrategy.getMultiSig()`, which supplies the yield tokens and receives the minted `AssetCX` on finalize); the merchant does not require the two to match and never compares them. The function rejects reconfiguration while any whitelisted yield token has non-zero pending for the vault.
- Yield-token whitelist (`setYieldTokenWhitelisted`): up to `MAX_WHITELISTED_YIELD_TOKENS` (= 20) ERC-20s can be authorised concurrently. The merchant rejects accruals against unwhitelisted tokens. Removal requires the token's cross-vault pending to be zero, which keeps the whitelist a complete index of every token with outstanding pending accrual.

**Views:** per user `getUserAccount`, `userVault`, `userData`, `totalMinted`, `totalBurned`, `mintedVaultShares`, `pendingQCRedemption`; global `totalPendingQCRedemption`, `isUserAccountUsed`; yield `isYieldTokenWhitelisted`, `getWhitelistedYieldTokens`, `yieldTokenForPendingYieldNonce`, `pendingYield(nonce)`, `totalPendingYieldByToken(token)`, `pendingYieldForVaultByToken(vault, token)`, `vaultYieldStrategy`, `vaultYieldMultisig`, `getNextYieldNonce`; direct redemption `pendingAssetCxRedemption(receiver)`. There is no cross-token pending-yield aggregate: iterate `getWhitelistedYieldTokens()` and sum per token (tokens may have different decimals).

**Error & Safety Considerations:**
- Guards for zero addresses, zero amounts, invalid vault assets, unknown users, reused tx hashes, duplicate yield nonces, and non-whitelisted yield tokens.
- Vault interactions use `SafeERC20.forceApprove` and reset approvals to zero afterwards.
- Whitelist revocation governs only the *initiation* side: already in-flight accrual nonces continue to finalize against their recorded token regardless of any subsequent whitelist flip, since the off-chain swap may have already executed.
- Strategy ⇄ merchant trust: the strategy's `finalizeMerchantYieldAccrual` accepts the `yieldToken` as a parameter rather than mirroring the per-nonce mapping. It is authenticated by `msg.sender == merchant`, and the merchant resolves the token from its own canonical mapping immediately before the call, so the pair is consistent by construction.

### ConcreteAssetCxVault (`src/implementation/ConcreteAssetCxVault.sol`)
ERC4626 async vault implementation (`ConcreteAssetCxVaultImpl`) extending ConcreteAsyncVaultImpl. Limits vault interactions to Concrete Merchant except shares redemption which is triggered by EOA holding the share token.

**Functions:**
- `deposit(assets, receiver)` - Deposits assets (MERCHANT_ROLE only)
- `mint(shares, receiver)` - Mints shares (MERCHANT_ROLE only)
- `claimWithdrawal(user, epochIDs)` - Claims withdrawal for user (MERCHANT_ROLE only); the assets are always paid to the caller (the merchant)
- `claimWithdrawal(epochIDs)`, `claimUsersBatch`, `toggleQueueActive` - Disabled, revert `NotImplemented`
- `getHook()` - Returns the configured hook target
- `withdraw` / `redeem` - Inherited: queue a request in the current epoch

On initialize and upgrade, `ROLE_ADMIN` is set as the admin of MERCHANT_ROLE, so the vault's role admin manages it like every other vault role.

### AssetCxMultisigStrategy (`src/strategies/AssetCxMultisigStrategy.sol`)
Multisig strategy that coordinates yield swapping via ConcreteMerchant.

**Key Functions:**
- `initialize(...)` - Initializes strategy with vault, multisig, accounting bounds, timelock and merchant (the merchant can only be set here)
- `initiateMerchantYieldAccrual(yieldToken, amountInYieldToken, nonce)` - Pulls yield token from the strategy multisig and starts accrual on the merchant (admin or operator)
- `finalizeMerchantYieldAccrual(nonce, amountInAsset, yieldToken)` - Called by merchant to finalize yield; moves the minted AssetCX to the strategy multisig
- `getMerchant()`, `getPendingMerchantYield(nonce)`, `totalPendingYield(token)` - Views; `totalPendingYield(token)` mirrors the merchant's `pendingYieldForVaultByToken(strategyVault, token)`

### WhitelistHook (`src/hooks/WhitelistHook.sol`)
Access control hook enforcing whitelist for vault operations. Only users depositing via QC or the merchant should interact with the vault.

Inherits `BaseHook` (from `@concrete-xyz/earn-v2-core`), like the other hooks. Deployed as a clone via `ClonesWithImmutableArgs`; the immutable args encode `[factory (20)][vault (20)]`, read back through `FACTORY()` and `VAULT()`. `initialize(admin, initialWhitelisted)` is restricted to the encoded factory (via `BaseHook.__BaseHook_init`, which reverts with `NotFactory`), so an uninitialized clone cannot be front-run to seize `DEFAULT_ADMIN`.

**Functions:**
- `initialize(admin, initialWhitelisted)` - One-time setup; callable only by the encoded factory
- `setUserWhitelisted(user)` - Adds user to whitelist (WHITELIST_MANAGER_ROLE)
- `removeUserFromWhitelist(user)` - Removes user from whitelist (WHITELIST_MANAGER_ROLE)
- Pre-hooks: `preDeposit`, `preMint` - `receiver` must be whitelisted
- Pre-hooks: `preWithdraw`, `preRedeem` - `receiver` must equal `owner`, and `owner` must be whitelisted

The merchant holds WHITELIST_MANAGER_ROLE so that `emergencyMigrateUserAccount` can update the whitelist. Not timelocked.

### TransferAllowlistHook (`src/hooks/TransferAllowlistHook.sol`)
Transfer hook restricting vault share transfers to explicitly allowed `(from, to)` pairs. Inherits `BaseHook` and is deployed and initialized like the WhitelistHook; combined with it through an Earn V2 `HookContainer`.

**Functions:**
- `initialize(owner)` - One-time setup; callable only by the encoded factory
- `setAllowed(from, to, allowed)` - Allows or disallows a transfer pair (owner)
- Pre-hook: `preTransfer` - Reverts `TransferNotAllowed` unless `allowed[from][to]`. Deposit, mint, withdraw and redeem do not invoke the transfer hook

Not timelocked.

### AssetCXOFTAdapter / AssetCXOFT (`src/AssetCXOFTAdapter.sol`, `src/AssetCXOFT.sol`)
Cross-chain transfers of AssetCX via LayerZero OFT. Both are UUPS upgradeable and `Ownable`.

- `AssetCXOFTAdapter` (home chain) - Locks AssetCX when bridging out, unlocks when bridging back
- `AssetCXOFT` (remote chains) - ERC20 with Permit; minted when AssetCX arrives, burned when sent back

Bridging does not change AssetCX supply: tokens on remote chains are backed by AssetCX locked in the adapter. Minting, burning and redemption only happen on the home chain. The owner configures LayerZero peers and authorises upgrades; these contracts are not behind the timelock. Pausing AssetCX also stops the adapter.

### Contract Identities
Factory-deployed contracts expose `ID()`, a packed `(contract type, flavour, version)`. AssetCX uses flavour 7, and flavour 8 for the transfer-allowlist hook (both are hooks, so they need distinct flavours).

| Contract | `ID()` | Decoded |
|---|---|---|
| ConcreteAssetCxVaultImpl | `710700` | vault (0), flavour 7, v1.7.0 |
| AssetCxMultisigStrategy | `200710700` | strategy (2), flavour 7, v1.7.0 |
| WhitelistHook | `500710700` | hook (5), flavour 7, v1.7.0 |
| TransferAllowlistHook | `500810700` | hook (5), flavour 8, v1.7.0 |

## Main Flows

### User Registration
1. Merchant manager calls `setUserAccount(userId, user)`; optionally `setUserVault(userId, vault)` and `setUserData(userId, data)`
2. User address is whitelisted on the resolved vault's WhitelistHook

Registration setters are timelock-gated once the timelock is active, so register users before activation where possible.

### Mint & Deposit Flow
1. QC receives deposit → Operator calls `mintAndDeposit(userId, amount, txHash)`
2. Merchant mints AssetCX backed by the QC deposit, deposits to vault on user's behalf
3. Vault allocates assets to strategy (external)

**Replay protection — one-to-one txHash invariant:** every transaction that mints AssetCX
must correspond to a **single, unique** qualified-custody (QC) `txHash`. The merchant
records each consumed hash and reverts on reuse, so a QC `txHash` can back **at most one**
EVM mint transaction and can never serve as proof for more than one on-chain minting event.
This enforces a strict, auditable one-to-one mapping between each custody deposit and the
AssetCX minted against it. The same record is shared by `finalizeQCRedemption`,
`finalizeYieldAccrual` and `finalizeAssetCxRedemption`, so a hash can be consumed only once
across all four flows.

### Yield Accrual Flow
1. Strategy accumulates a whitelisted yield token in its multisig
2. Strategy admin/operator calls `initiateMerchantYieldAccrual(yieldToken, amountInYieldToken, nonce)` → strategy pulls the token from its multisig and calls merchant `initiateYieldAccrual(vault, yieldToken, amountInYieldToken, nonce)` → merchant transfers the token to the vault's yield multisig
3. QC swaps yield token to ASSET off-chain
4. Operator calls `finalizeYieldAccrual(vault, nonce, amountInAsset, txHash)` → merchant mints AssetCX and calls `finalizeMerchantYieldAccrual(nonce, amountInAsset, yieldToken)`, which moves it to the strategy multisig
5. Strategy adjusts accounting via `adjustTotalAssets`

**Nonces:** `initiateYieldAccrual` requires `nonce == getNextYieldNonce()`. The nonce is a single
monotonically increasing counter that is **continuous across all yield tokens**. The merchant records
which token each nonce was paid in (`yieldTokenForPendingYieldNonce`) and resolves it on finalize, so
the merchant is the sole authority for the nonce → token attribution. Pending amounts are tracked per
nonce, per token and per `(vault, token)`.

**Slippage & off-chain validation:** the realized `amountInAsset` can differ from the
amount pending at initiation because the off-chain swap of the yield token into ASSET
incurs slippage. This slippage is **not verified on-chain** — the contract trusts the
operator-supplied `amountInAsset`, and its correctness is enforced by the backend system:
- The proposed accrual amount is checked by the backend against a trusted oracle source
  before signature.
- Monitoring, alerting, and operational stop controls are in place to detect or prevent
  anomalous accruals.
- During the bespoke phase, execution requires a final human signature in addition to the
  automated validation process.
- Each yield-finalization transaction is tied to a unique qualified-custody transaction
  hash. The contract prevents reuse of that hash, providing a replay-resistant and clearly
  traceable audit trail between the custody transaction and the corresponding amount of
  `AssetCX` minted.

### Loss
1. In case of a strategy loss, `adjustTotalAssets` is called.
2. Vault share value reflects the loss.
3. Users are redeemed for less AssetCX

Accounting adjustments are bounded by the strategy's `maxAccountingChangeThreshold`, accounting validity period and cooldown period (Earn V2).

### Withdrawal & Redemption Flow
1. User calls `vault.withdraw()` → creates withdrawal request
2. Vault allocates withdrawal from strategy (external)
3. Vault manager closes and processes epoch
4. Operator calls `claimVaultWithdrawal(userId, epochID)` → burns AssetCX, records pending QC redemption. Reverts `ClaimAmountMismatch` unless the AssetCX received equals the epoch's expected assets
5. QC redemption is fulfilled off-chain
6. Operator calls `finalizeQCRedemption(userId, amount, txHash)` → finalizes off-chain QC settlement

### Direct Redemption Flow - used in case strategy liquidation leaves AssetCX tokens in hands of the protocol or a 3rd party partner.
1. User calls `redeem(amount, receiver)` → transfers AssetCX to merchant, burns, records pending
2. QC Redemption is fulfilled off-chain
3. Operator calls `finalizeAssetCxRedemption(receiver, amount, txHash)` → finalizes QC settlement

`redeem` is permissionless (but pausable). The liquidation module uses it to redeem extracted collateral, see [`liquidation.md`](./liquidation.md).

### Emergency Account Migration
1. Old account approves the merchant to transfer its vault shares
2. Admin calls `emergencyMigrateUserAccount(userId, newAccount)` (timelock Tier 1) → whitelists the new account and removes the old one on the vault's hook, rebinds the userId and transfers the shares
3. `newAccount` must not be bound to another userId; the old address stays marked as used, so it can never be bound again

The immediate incident response is `pause()`; the migration follows under the timelock delay.

## Access Control & Timelock

Privileged functions carry an `afterDelay` modifier. Once the timelock is active, such a call only succeeds if exactly that call (target, selector and arguments) was first proposed on the shared Earn V2 `Timelock` and its delay tier has elapsed. Each proposal executes once; `GUARDIAN_ROLE` can cancel and `OVERRIDE_ROLE` can fast-track. Delays are only enforced when both the Timelock and the protected contract have called their one-way `activateTimelock()`; before that, `afterDelay` functions execute directly.

Default delays: Tier 1 48 h, Tier 2 24 h, Tier 3 12 h.

| Contract | Tier 1 (48 h) | Tier 2 (24 h) | Tier 3 (12 h) | Not timelocked |
|---|---|---|---|---|
| AssetCX | upgrade, `setTimelock`, grant DEFAULT_ADMIN_ROLE / MERCHANT_ROLE | — | `unpause` | `pause`, grant PAUSER_ROLE, `mint` / `burn` |
| ConcreteMerchant | upgrade, `setTimelock`, `emergencyMigrateUserAccount`, grant DEFAULT_ADMIN_ROLE / MERCHANT_MANAGER_ROLE | `setVaultYieldConfig`, `setYieldTokenWhitelisted`, grant OPERATOR_ROLE | `setUserAccount`, `setUserVault`, `removeUserVault`, `setUserData`, `unpause` | `pause`, grant PAUSER_ROLE, all operational functions |
| Vault (Earn V2) | `transferOwnership`, `setTimelock`, grant `ROLE_ADMIN` / `VAULT_MANAGER` | `configure`, `addStrategy`, `setHooks`, fee recipients, other manager-role grants | `unpause` | `pause`, epoch processing, allocation |
| Strategy (Earn V2) | `setMultiSig`, `setTimelock`, grant `ROLE_ADMIN` | `setMaxAccountingChangeThreshold`, grant `STRATEGY_ADMIN` / `STRATEGY_UPGRADER` | `setCooldownPeriod`, `unpause` | `pause`, accounting adjustments, yield initiation |
| HookContainer (Earn V2) | `setTimelock` | `addHook`, `replaceHook`, `removeHook` | — | — |
| WhitelistHook, TransferAllowlistHook, AssetCXOFTAdapter, AssetCXOFT | — | — | — | everything |

Liquidation contracts: see [`liquidation.md`](./liquidation.md).

**Required wiring:**
- The merchant holds MERCHANT_ROLE on AssetCX and on every vault it serves
- The merchant holds WHITELIST_MANAGER_ROLE on each vault's WhitelistHook (otherwise `emergencyMigrateUserAccount` reverts)
- `setVaultYieldConfig` is set for each vault before any yield accrual
- Each protected contract is bound on the Timelock and the timelock is activated on both sides

## Invariants & Trust Assumptions

**Invariants:**
- 1:1 backing: AssetCX is minted only against a consumed QC `txHash` (`mintAndDeposit`, `finalizeYieldAccrual`); every burn (`claimVaultWithdrawal`, `redeem`) creates a pending redemption settled by a QC release
- A QC `txHash` is consumed at most once across all merchant flows
- Vault shares are only minted through `mintAndDeposit`; vault withdrawals are only claimable by the merchant, which burns what it receives
- One address per userId; an address rotated out by emergency migration can never be bound again
- The yield nonce is strictly sequential; the yield-token whitelist always contains every token with pending accruals; vault yield routing cannot change while a conversion for that vault is pending
- The last DEFAULT_ADMIN_ROLE on AssetCX and the merchant cannot be removed

**Trust assumptions and known limitations:**
- Operator inputs are trusted: `mintAndDeposit` amounts, `amountInAsset` on yield finalization and redemption finalizations are not verified on-chain against custody. The contracts enforce `txHash` uniqueness, registration and pending-amount bounds; correctness is enforced by the backend, multisig confirmation and `pause()`
- OPERATOR_ROLE is not timelocked and has no per-transaction mint cap
- Strategy valuation is trusted within the Earn V2 accounting bounds
- The hooks and the cross-chain contracts are not timelocked
- Before the timelock is activated on both sides, every `afterDelay` function executes immediately
- `claimVaultWithdrawal` floors `mintedVaultShares[userId]` at zero rather than reverting

## Upgradeability & Storage
- AssetCX and the merchant are UUPS proxies; upgrades require DEFAULT_ADMIN_ROLE and a Tier 1 timelock action. The cross-chain contracts are UUPS proxies upgraded by their owner. Storage uses EIP-7201 namespaces.
- The vault is upgraded through the Earn V2 `ConcreteFactory` (`approveImplementation`, `setMigratable`, `upgrade`); the AssetCX upgrade step re-asserts `ROLE_ADMIN` as admin of MERCHANT_ROLE without revoking existing holders. The strategy follows the Earn V2 strategy upgrade path (`STRATEGY_UPGRADER`).
- `ConcreteMerchantStorageLib` keeps three `deprecated*` fields from the single-token yield design so the storage layout of live proxies is preserved; they are no longer read or written.
- `reinitializeV3` on AssetCX and the merchant rebuilds the enumerable role-membership sets for proxies whose roles were granted by the earlier non-enumerable implementation, and reverts (`NotACurrentRoleHolder`, `AdminBackfillMismatch`) if a supplied holder list doesn't match. `reinitializeV2(pausers)` on AssetCX is the earlier migration that introduced PAUSER_ROLE.
