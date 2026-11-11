# AssetCX

Smart contracts for AssetCX: a 1:1-backed ERC-20 minted against assets in qualified custody and
deployed into yield strategies through Concrete Earn V2 vaults, while the underlying never leaves
custody.

- [Protocol documentation](./docs/main-docs.md): architecture, flows, access control, invariants
- [Collateralised liquidation](./docs/liquidation.md): RedemptionClaimToken and the liquidation module
- [Security considerations](./docs/security-considerations.md): operating model, scope boundaries, known open items
- [Changelog](./CHANGELOG.md)

## Build and test

Requires [Foundry](https://book.getfoundry.sh/) and Yarn.

```sh
yarn install
forge build
FOUNDRY_PROFILE=test forge test
```
