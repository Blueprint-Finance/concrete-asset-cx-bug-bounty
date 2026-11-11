# AssetCX — Security Considerations

This document records the operating model the contracts are designed around, and the classes of
behaviour that are deliberately **not** defended against on-chain. It complements
[`main-docs.md`](./main-docs.md) and [`liquidation.md`](./liquidation.md), which describe what the
system does; this one describes the boundary of what it is trying to protect.

---

## 1. Operating model

AssetCX is a closed, permissioned system serving a defined set of onboarded institutional clients.
Almost every security property below follows from that, so it is worth stating plainly:

- **Minting is custody-bound and operator-driven.** AssetCX is minted only by the Merchant, only
  against a qualified-custody deposit identified by a unique `txHash`, and only for a registered
  `userId`. The transaction is prepared by the backend against the custody record and, in the current
  phase, additionally requires human operator approval before signature. There is no permissionless
  mint.
- **Clients never hold AssetCX in normal operation.** It is the underlying asset of the vaults; the
  client holds vault shares. The AssetCX holder set is the Merchant, the vaults, the strategy
  multisig, the liquidation module and the cross-chain adapter.
- **Vault access is whitelisted.** `deposit` and `mint` on the vault are Merchant-only;
  `claimWithdrawal` is Merchant-only; the WhitelistHook additionally requires the receiver to be a
  whitelisted address and `receiver == owner` on withdraw and redeem.
- **Each client has a dedicated vault.** Every onboarded client is assigned a per-user vault via
  `setUserVault`. The default vault configured at `initialize` is a fallback that production
  deployments do not use; it is treated as deprecated.
- **Redemption and liquidation are privileged.** Custody settlement (`finalizeQCRedemption`,
  `finalizeAssetCxRedemption`) is `OPERATOR_ROLE`; liquidation entrypoints are `LIQUIDATOR_ROLE`.

## 2. Out of scope

### 2.1 Commingled vaults

Because each client has its own vault, scenarios that require two clients to share one vault are
outside the operating model. This includes cross-depositor interference through the shared share
price, donation or first-depositor share-price manipulation aimed at another client, and
epoch-queue interactions between unrelated depositors.

### 2.2 Misconfiguration

Deployments that contradict the documented wiring are out of scope. In particular: a vault deployed
without the WhitelistHook, a yield configuration pointing at a multisig outside operator control,
privileged roles granted to parties outside the documented holder set, whitelisting an address that
is not an onboarded client, or admitting an unsupported token to the yield whitelist. The deployment
and wiring checklists are the control here, not the contracts.

### 2.3 Privileged key compromise and incorrect privileged inputs

Scenarios that begin with a compromised admin, manager or operator key — or with the backend or an
operator supplying economically wrong parameters to an otherwise correctly formed privileged call —
are out of scope. The contracts bound what a privileged caller can express (`txHash` uniqueness,
registration checks, pending-amount ceilings, sequential yield nonces, timelock tiers on every
configuration setter, and the pause switches), but they do not attempt to detect that a well-formed
privileged call is wrong. That is addressed by key custody, backend validation against the custody
record, human approval, the timelock delay and `pause()`.

### 2.4 Interactions with third-party protocols

AssetCX is not in general circulation. It is not listed on AMMs and is not a money-market asset
outside the lending venues the protocol integrates with deliberately. Findings premised on arbitrary
external composability — flash-loanable AssetCX liquidity, AMM price manipulation of AssetCX, its
use as collateral on an unsupported venue, or integration with protocols that are not part of the
deployment — are out of scope. The supported lending-venue integration **is** in scope and is
described in [`liquidation.md`](./liquidation.md).

### 2.5 Non-standard ERC-20 behaviour

Fee-on-transfer and rebasing tokens are not supported anywhere in the system: not as a vault asset
(always AssetCX), not as yield tokens on the Merchant whitelist, and not as the debt token of a
liquidation market. All accounting assumes that the amount transferred equals the amount received
and that balances do not change without a transfer. Operators do not admit such tokens.

### 2.6 Share transfers and address changes

Vault shares are issued only to whitelisted client addresses and are not intended to move between
holders. In the current configuration non-transferability is an operational property of the closed
client set rather than a contract-enforced one (see §3.2). An address change for an existing client
is performed by Concrete through `emergencyMigrateUserAccount`, which re-whitelists the new address,
removes the old one and moves the shares under a Tier 1 timelock delay. Findings that treat the
share token as a freely tradable instrument, or that assume a client can rotate its own address
unilaterally, do not match the intended operation.

### 2.7 Unrecognised counterparties

Concrete does not service withdrawal requests, AssetCX redemptions or liquidations for addresses it
has no onboarding relationship with. Every path from vault shares back to the underlying runs
through an operator-driven custody settlement, so a party outside the onboarded set has no route to
redemption regardless of what it holds. Impact that depends on an unrecognised holder acquiring
shares or AssetCX and then expecting custody settlement is out of scope.

## 3. Known open items

These are recorded limitations rather than undiscovered issues.

### 3.1 Yield-accrual slippage is not enforced on-chain

`finalizeYieldAccrual` mints the `amountInAsset` the operator supplies. The contract does not verify
that figure against the yield token sent out at initiation, because the conversion happens off-chain
in custody and its proceeds are not observable to the contract. The controls are the backend check
against a trusted oracle source, monitoring and alerting, human approval before signature, and the
unique custody `txHash` that ties each finalization to exactly one settlement. On-chain enforcement
remains an open item.

### 3.2 The TransferAllowlistHook is a soft control

The hook only observes transfers routed through the share token's `_update`. The vault's own share
movements — escrowing shares when a withdrawal request is created, and returning them if the request
is cancelled — go through an internal library path that does not invoke the transfer hook. The hook
therefore expresses an intent rather than a guarantee, and any vault that relies on it must also
disable withdrawal-request cancellation (`cancellationEnabled = false`). The hook is not currently
deployed on any vault.

## 4. What this does not narrow

Everything outside the boundary above is treated normally: accounting correctness and the 1:1
backing invariant, replay protection across all four custody-settled flows, role and timelock
enforcement, upgrade and storage-layout safety, the vault epoch and claim logic, the liquidation
flow invariants, and supply conservation across chains.
