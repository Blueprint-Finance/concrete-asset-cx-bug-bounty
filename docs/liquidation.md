# AssetCX — Collateralised Liquidation and Redemption Claims

This document describes how loans collateralised with AssetCX on a lending venue are liquidated. It
assumes the core system in [`main-docs.md`](./main-docs.md), in particular the Merchant's direct-redemption
path (`redeem` / `finalizeAssetCxRedemption`, README §4.6) and the shared Timelock (README §5).

---

## 1. Overview

### 1.1 The problem

AssetCX can be used as collateral for a loan on a lending venue. If such a position has to be
liquidated, a conventional liquidator cannot help: AssetCX is only redeemable through the Merchant
against an off-chain custody release, which takes hours to a day, while a venue liquidation must
settle in one transaction. The collateral has real value, but realising it takes a redemption cycle,
and the position must not stay exposed to the underlying's price during that time.

### 1.2 The mechanism

A **RedemptionClaimToken** bridges the gap. It is an ERC-20 that temporarily stands in for the
redeemed collateral inside the venue and is burned once the debt is repaid. The liquidation is a
**collateral swap plus a debt transfer**, split into two role-gated calls around the off-chain
redemption:

1. **Initiate** (`initiateLiquidationCollateralSwap`). Mint RedemptionClaimToken sized to the debt
   being taken over, supply it as collateral of a fresh module-owned **temporary position (B)**, move
   that slice of debt from the client's **borrow position (A)** onto B, withdraw the freed AssetCX
   from A, and redeem it through the Merchant. All venue actions run in one atomic batch.
2. **Off-chain.** Custody delivers the underlying against the pending redemption; it is settled on
   the Merchant with `finalizeAssetCxRedemption`; the underlying is sold for the debt token and the
   proceeds are brought on-chain.
3. **Finalize** (`finalizeLiquidationAndRepay`). Pull the proceeds from the liquidator, repay B's
   debt, withdraw and burn the released RedemptionClaimToken, and apply any surplus to A's remaining
   debt. Can be done in several partial tranches.

Net effect: the debt is repaid from the position's own former collateral, the venue's lenders are
made whole, the custody reserve is debited by exactly the redeemed amount, and RedemptionClaimToken
supply returns to zero.

### 1.3 Why the temporary position carries no price risk

The venue prices the RedemptionClaimToken **as the debt token** and lists it at a high LTV. So:

- the minted amount stays close to the debt it backs (`debt / collateralRatio`; at a 98% ratio about
  `1.02×`);
- position B is **delta-neutral** for its whole lifetime. Moves in the underlying's price do not
  affect its health; only debt-token interest accrues.

Position A is strictly deleveraged: it loses `debt × (1 + buffer)` of collateral value and sheds
`debt` of liability.

---

## 2. Contracts

| Contract / library | File | Role |
|---|---|---|
| `RedemptionClaimToken` | `src/liquidations/RedemptionClaimToken.sol` | One token per collateral/debt market pair. Module-only mint/burn, closed transfer whitelist, pausable, UUPS, timelock-protected. |
| `DolomiteLiquidationModule` | `src/liquidations/DolomiteLiquidationModule.sol` | The two entry points, the liquidation ledger and the sizing configuration. Pausable, reentrancy-guarded, UUPS, timelock-protected. |
| `DolomiteLiquidationLib` | `src/lib/DolomiteLiquidationLib.sol` | Oracle-based sizing, position views and the two venue batches. **The only file with venue-specific logic.** |
| `RedemptionClaimTokenStorageLib` | `src/lib/RedemptionClaimTokenStorageLib.sol` | EIP-7201 storage of the token (decimals, whitelist). |
| `DolomiteLiquidationModuleStorageLib` | `src/lib/DolomiteLiquidationModuleStorageLib.sol` | EIP-7201 storage of the module (venue handles, ratios, ledger). |

Interfaces: `IRedemptionClaimToken`, `IDolomiteLiquidationModule`. Roles from `AssetCxRolesLib`:
`LIQUIDATION_MODULE_ROLE`, `LIQUIDATOR_ROLE`, `WHITELIST_MANAGER_ROLE`, `PAUSER_ROLE`.

One token and one module are deployed **per collateral/debt market pair**. Token decimals are set at
initialization to match the pair's debt token.

---

## 3. RedemptionClaimToken

`ERC20PausableUpgradeable` + `AccessControlEnumerableUpgradeable` + UUPS + `ITimelockProtected`;
structured like AssetCX.

| Function | Access | Timelocked | Notes |
|---|---|---|---|
| `initialize(name, symbol, admin, decimals, timelock)` | once | — | `admin` gets `DEFAULT_ADMIN_ROLE`, `WHITELIST_MANAGER_ROLE` and `PAUSER_ROLE`. Decimals must be non-zero. |
| `mint(amount)` / `burn(amount)` | `LIQUIDATION_MODULE_ROLE` | No | To / from `msg.sender` (the module). |
| `addToWhitelist(account)` | `WHITELIST_MANAGER_ROLE` | Tier 2 | Widens the holder set, so it is delayed. |
| `removeFromWhitelist(account)` | `WHITELIST_MANAGER_ROLE` | No | Restrictive, so instant. |
| `pause()` / `unpause()` | `PAUSER_ROLE` | No / Tier 3 | Pause freezes all movement, including mint and burn. |
| `grantRole` | role admin | Yes, except `PAUSER_ROLE` | `DEFAULT_ADMIN_ROLE`, `LIQUIDATION_MODULE_ROLE`: Tier 1; `WHITELIST_MANAGER_ROLE`: Tier 2. |
| `setTimelock`, upgrade | `DEFAULT_ADMIN_ROLE` | Tier 1 | |

The last `DEFAULT_ADMIN_ROLE` cannot be removed (`CannotRemoveLastRoleAdmin`).

**Closed holder set.** `_update` requires both non-zero endpoints of every transfer to be whitelisted
(mint and burn are allowed because `address(0)` is exempt). The intended whitelist is exactly **the
module and the venue's core contract**. The token therefore only ever moves between module and venue,
nobody else can hold it, and a withdrawn token can only go back to the module, where the only thing
that can happen to it is a burn.

---

## 4. DolomiteLiquidationModule

`PausableUpgradeable` + `AccessControlEnumerableUpgradeable` + `ReentrancyGuardTransient` + UUPS +
`ITimelockProtected`.

### 4.1 Configuration

`initialize(InitParams)`:

| Field | Meaning |
|---|---|
| `admin` | Gets `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE`. |
| `liquidator` | Gets `LIQUIDATOR_ROLE`; `address(0)` to grant later. |
| `dolomiteMargin` | The venue core contract. |
| `redemptionClaimToken` | The token this module mints and burns. |
| `merchant` | The Merchant used to redeem extracted collateral. |
| `debtToken` | The debt token of the market pair. |
| `collateralRatioWad` | RedemptionClaimToken collateral ratio, in `(0, 1e18)`. |
| `bufferWad` | Collateral over-withdrawal buffer, in `(0, 1e18]`. |
| `liquidatableLtvWad` | LTV from which a plain liquidator may act, in `(0, 1e18]`. |
| `timelock` | Timelock address, or `address(0)`. |

The collateral token is **not** a parameter: it is read from `merchant.assetCX()`, so the module
cannot be pointed at a token the Merchant does not mint.

| Function | Access | Timelocked |
|---|---|---|
| `setCollateralRatio`, `setBuffer` | `DEFAULT_ADMIN_ROLE` | Tier 3 |
| `setLiquidatableLtv` | `DEFAULT_ADMIN_ROLE` | Tier 2 (lowering it widens what a liquidator may act on) |
| `pause()` / `unpause()` | `PAUSER_ROLE` | No / Tier 3 |
| grant `DEFAULT_ADMIN_ROLE` / `LIQUIDATOR_ROLE` | admin | Tier 1 / Tier 2 |
| `setTimelock`, upgrade | `DEFAULT_ADMIN_ROLE` | Tier 1 |
| the two entry points | `LIQUIDATOR_ROLE` | No |

### 4.2 Sizing

Both amounts come from the venue's oracle prices at call time; the caller only chooses the debt
slice.

- **RedemptionClaimToken minted** = `debt × debtPrice / (rcPrice × collateralRatio)`, rounded up, so
  the claim always fully backs the debt.
- **Collateral withdrawn** = `debt × debtPrice × (1 + buffer) / collateralPrice`. The buffer
  over-sizes the redemption so the sale proceeds cover the debt plus fees, slippage and interest;
  any surplus goes to A's remaining debt at finalization.

### 4.3 `initiateLiquidationCollateralSwap(positionOwner, accountNumber, debtAmountToLiquidate, receiver)`

`nonReentrant`, `whenNotPaused`, `LIQUIDATOR_ROLE`. Returns `redemptionId`.

1. **Guards.** Non-zero inputs; the module is a venue operator for `positionOwner`
   (`NotDolomiteOperator`); `debtAmountToLiquidate ≤` the position's debt
   (`DebtAmountExceedsPositionDebt`).
2. **LTV band.** Unless the caller also holds `DEFAULT_ADMIN_ROLE`, the position's LTV must be at
   least `liquidatableLtvWad` (`PositionNotLiquidatable`). The admin path works at any LTV, which
   allows deliberate deleveraging.
3. **Allocate.** Next `redemptionId`; temporary account number
   `keccak256("concrete.liquidation.temp", module, redemptionId)`, so temporary positions never
   collide.
4. **Mint** the sized RedemptionClaimToken to the module and approve the venue.
5. **Atomic venue batch:** deposit the token into B; move `debtAmountToLiquidate` of debt from A to B
   by internal balance transfer (the debt token never leaves the venue); withdraw the sized
   collateral from A to the module.
6. **Check** the module holds no RedemptionClaimToken (`UnexpectedRedemptionClaimBalance`).
7. **Redeem:** `merchant.redeem(collateralAmount, receiver)` burns the AssetCX and records a pending
   redemption for `receiver`, who receives the redeemed value off-chain and funds the repayment.
8. **Record** the liquidation and emit `LiquidationInitiated`.

### 4.4 `finalizeLiquidationAndRepay(redemptionId, debtTokenAmount)`

`nonReentrant`, `whenNotPaused`, `LIQUIDATOR_ROLE`. Reads B's live debt (including interest) and
supports partial repayment:

| | Partial (`amount < tempDebt`) | Full close (`amount ≥ tempDebt`) |
|---|---|---|
| Debt repaid | `amount` | `tempDebt`, cleared to exactly zero |
| RedemptionClaimToken released | Only what B holds above what its remaining debt needs at the configured ratio | All of it |
| Surplus | — | `amount − tempDebt`, capped at A's remaining debt, deposited into A |
| Refund | — | Anything above that, returned to the caller |
| Record | Stays active; totals accumulate | Unwind invariant checked, record deleted |

Order: check zero RedemptionClaimToken balance on the module; pull `debtTokenAmount` from the caller;
one atomic venue batch (repay B, withdraw released token, full close: deposit surplus into A); burn
exactly the withdrawn balance; reset approvals; refund. On a full close it requires
`redemptionClaimTokenWithdrawn == redemptionClaimTokenSupplied` (`LiquidationInvariantViolated`) and
emits `LiquidationFinalized`; otherwise `LiquidationPartiallyFinalized`.

A partial repayment that leaves B below the venue's minimum borrow value reverts inside the venue;
the closing tranche must clear B in full.

### 4.5 Views

`getLiquidation(redemptionId)`, `getLiquidationIds(positionOwner, accountNumber)` (ids still in
flight), `positionLtvWad(positionOwner, accountNumber)` (`type(uint256).max` for a position with debt
but no collateral value), and the configuration getters.

### 4.6 Venue binding

All venue-specific code is in `DolomiteLiquidationLib`: market lookup, oracle prices, balances, the
operator check and the two batches. The flow always uses two positions (A and B), which also works on
venues that allow only one collateral asset per position.

---

## 5. Invariants

| | Invariant | Enforced by |
|---|---|---|
| I1 | No RedemptionClaimToken is minted without collateral being extracted and redeemed in the same transaction. | Both happen inside `initiateLiquidationCollateralSwap`; the token has no other mint path. |
| I2 | RedemptionClaimToken is only burned together with debt repayment. | Both happen inside `finalizeLiquidationAndRepay`. |
| I3 | The module holds no RedemptionClaimToken between calls, so one liquidation cannot consume another's collateral. | `_assertNoRedemptionClaimBalance` before each batch. |
| I4 | A full close withdraws and burns exactly what was supplied. | `LiquidationInvariantViolated`. |
| I5 | The token is only ever held by the module or the venue. | Whitelist check on both ends of every transfer. |
| I6 | The custody reserve is only debited by the collateral redemption; the RedemptionClaimToken is not redeemable and never counts as backing. | The token has no Merchant integration. |
| I7 | A plain liquidator can only act within the configured LTV band. | `PositionNotLiquidatable` (admin exempt). |
| I8 | The debt taken over never exceeds the position's debt. | `DebtAmountExceedsPositionDebt`. |
| I9 | Temporary positions cannot collide. | Account number derived from module address and `redemptionId`. |
| I10 | No residual approvals. | Venue and Merchant approvals reset after each batch. |
| I11 | No reentrancy into the entry points. | `nonReentrant` (transient storage). |

In steady state `RedemptionClaimToken.totalSupply()` is zero; a non-zero supply means a liquidation
is in flight, and every active `redemptionId` has a matching pending redemption on the Merchant until
it is finalized.

**I6 during the redemption window.** Initiation burns the extracted AssetCX, but custody is not
debited until `finalizeAssetCxRedemption` settles the claim. Between those two points supply has
already fallen while the reserve has not, so the reserve *exceeds* `AssetCX.totalSupply()` by the
pending redemption amount. `reserve == totalSupply` holds once the claim is settled. Reported
backing stays capped at 1:1 with supply and never counts the excess; the RedemptionClaimToken is an
off-reserve instrument throughout and is never part of the calculation.

## 6. Trust assumptions and pause behaviour

- **Liquidator.** `LIQUIDATOR_ROLE` chooses the debt slice and the `receiver`, and supplies the
  repayment proceeds. It cannot hold, mint or burn the RedemptionClaimToken, is limited to the LTV
  band, and repays from the position's own former collateral rather than protocol funds.
- **Admin override.** `DEFAULT_ADMIN_ROLE` can initiate at any LTV.
- **Oracle.** Sizing uses the venue's oracle prices.
- **Off-chain leg.** Close-out timing is not enforced on-chain. Because B is delta-neutral, timing
  affects settlement, not solvency; shortfalls are handled with partial repayments.

Three pause switches stop the flow independently: the **module** (both entry points), the
**RedemptionClaimToken** (mint and burn, so neither step can complete), and **AssetCX / the Merchant**
(`redeem`, so initiation cannot complete). In-flight liquidations stay recorded and resume on
unpause.

## 7. Deployment and wiring

1. RedemptionClaimToken proxy: `initialize(name, symbol, admin, decimals, timelock)`.
2. Module proxy: `initialize(InitParams)`.
3. Grant `LIQUIDATION_MODULE_ROLE` on the token to the module.
4. Whitelist the module and the venue core on the token.
5. Register the module as a venue operator for the owner of the borrow positions.
6. At the venue: list the collateral and the RedemptionClaimToken as collateral for the debt market,
   price the RedemptionClaimToken as the debt token at a high LTV.
7. Grant `LIQUIDATOR_ROLE` if not set at initialization.
8. Bind both contracts on the Timelock (`CT_REDEMPTION_CLAIM_TOKEN`,
   `CT_ASSETCX_LIQUIDATION_MODULE`) and activate the timelock on each.
9. Verify: the token whitelist is exactly the module and the venue core; the module holds
   `LIQUIDATION_MODULE_ROLE`; `getTimelock()` reports active on both; `collateralToken()` equals
   `merchant.assetCX()`.
