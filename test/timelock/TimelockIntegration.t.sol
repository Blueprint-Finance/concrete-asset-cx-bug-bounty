// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626} from "@openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {IERC1967} from "@openzeppelin-contracts/interfaces/IERC1967.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {Timelock} from "@concrete-xyz/earn-v2-core/src/periphery/timelock/Timelock.sol";
import {ITimelock} from "@concrete-xyz/earn-v2-core/src/periphery/interface/ITimelock.sol";
import {
    IAssetCxInheritedSelectors,
    IConcreteMerchantInheritedSelectors
} from "@concrete-xyz/earn-v2-core/src/periphery/interface/ITimelockGatedSelectors.sol";
import {ITimelockProtected} from "@concrete-xyz/earn-v2-core/src/interface/ITimelockProtected.sol";
import {
    TimelockContractTypesLib as CT
} from "@concrete-xyz/earn-v2-core/src/periphery/lib/TimelockContractTypesLib.sol";
import {
    TimelockConfigurationLib as Config
} from "@concrete-xyz/earn-v2-core/src/periphery/lib/TimelockConfigurationLib.sol";
import {TimelockRolesLib} from "@concrete-xyz/earn-v2-core/src/periphery/lib/TimelockRolesLib.sol";
import {TimelockIntegrationLib} from "@concrete-xyz/earn-v2-core/src/lib/TimelockIntegrationLib.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";

import {AssetCX} from "../../src/AssetCX.sol";
import {ConcreteMerchant} from "../../src/merchant/ConcreteMerchant.sol";
import {IConcreteMerchant} from "../../src/interface/IConcreteMerchant.sol";
import {AssetCxRolesLib} from "../../src/lib/AssetCxRolesLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mock contracts (mirrors the helpers in test/merchant/ConcreteMerchant.t.sol,
// duplicated here so the timelock suite is self-contained).
// ─────────────────────────────────────────────────────────────────────────────

contract MockYieldToken is ERC20 {
    constructor() ERC20("Yield Token", "YLD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWhitelistHook {
    mapping(address => bool) public userWhitelisted;

    function setUserWhitelisted(address _user) external {
        userWhitelisted[_user] = true;
    }

    function removeUserFromWhitelist(address _user) external {
        userWhitelisted[_user] = false;
    }
}

contract MockAssetCXVault is ERC4626 {
    using SafeERC20 for IERC20;

    address public hook;

    constructor(IERC20 asset_) ERC20("AssetCX Vault", "aACX") ERC4626(asset_) {}

    function setHook(address _hook) external {
        hook = _hook;
    }

    function getHook() external view returns (address) {
        return hook;
    }
}

contract MockMultisigStrategy {
    address public multiSig;
    address public vault;

    constructor(address multiSig_, address vault_) {
        multiSig = multiSig_;
        vault = vault_;
    }

    function getVault() external view returns (address) {
        return vault;
    }

    function getMultiSig() external view returns (address) {
        return multiSig;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Base harness — deploys Timelock + AssetCX + ConcreteMerchant + fixtures,
// pre-binds both protected contracts under their respective contract types,
// and leaves the timelock INACTIVE so subclasses can build any further
// fixture state without going through `propose`. Each test calls
// `_activateAll` to flip enforcement on before exercising the gated surface.
// ─────────────────────────────────────────────────────────────────────────────

abstract contract TimelockTestBase is Test {
    Timelock public timelock;
    AssetCX public assetCX;
    ConcreteMerchant public merchant;
    MockAssetCXVault public assetCXVault;
    MockYieldToken public yieldToken;
    MockWhitelistHook public whitelistHook;
    MockMultisigStrategy public strategy;

    address public admin;
    address public proposer;
    address public stranger;
    address public yieldMultisig;

    // Tier codes, contract-type tags, and role identifiers live on
    // `TimelockConfigurationLib` / `TimelockContractTypesLib` /
    // `TimelockRolesLib` as `internal constant` values and are inlined at
    // compile time — no external calls needed, so the read-before-prank
    // caching pattern from earn-v2-core's TimelockTest is unnecessary here.

    /// @dev ERC-1967 implementation slot: `keccak256("eip1967.proxy.implementation") - 1`.
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    function setUp() public virtual {
        admin = makeAddr("admin");
        proposer = makeAddr("proposer");
        stranger = makeAddr("stranger");
        yieldMultisig = makeAddr("yieldMultisig");

        vm.label(admin, "admin");
        vm.label(proposer, "proposer");
        vm.label(stranger, "stranger");

        // ── Timelock proxy ────────────────────────────────────────────────
        Timelock timelockImpl = new Timelock();
        ERC1967Proxy timelockProxy =
            new ERC1967Proxy(address(timelockImpl), abi.encodeCall(Timelock.initialize, (admin)));
        timelock = Timelock(address(timelockProxy));
        vm.label(address(timelock), "timelock");

        // Dedicated proposer so the auth path is exercised distinctly from `admin`.
        vm.prank(admin);
        timelock.grantRole(TimelockRolesLib.PROPOSER_ROLE, proposer);

        // ── AssetCX proxy (timelock wired at init) ────────────────────────
        AssetCX assetCxImpl = new AssetCX();
        ERC1967Proxy assetCxProxy = new ERC1967Proxy(
            address(assetCxImpl), abi.encodeCall(AssetCX.initialize, ("Asset CX", "ACX", admin, address(timelock)))
        );
        assetCX = AssetCX(address(assetCxProxy));
        vm.label(address(assetCX), "assetCX");

        // ── Vault / merchant prerequisites ────────────────────────────────
        assetCXVault = new MockAssetCXVault(IERC20(address(assetCX)));
        yieldToken = new MockYieldToken();
        whitelistHook = new MockWhitelistHook();
        assetCXVault.setHook(address(whitelistHook));
        strategy = new MockMultisigStrategy(yieldMultisig, address(assetCXVault));

        // ── ConcreteMerchant proxy (timelock wired at init) ───────────────
        ConcreteMerchant merchantImpl = new ConcreteMerchant();
        ERC1967Proxy merchantProxy = new ERC1967Proxy(
            address(merchantImpl),
            abi.encodeCall(
                ConcreteMerchant.initialize, (admin, assetCX, IERC4626(address(assetCXVault)), address(timelock))
            )
        );
        merchant = ConcreteMerchant(address(merchantProxy));
        vm.label(address(merchant), "merchant");

        // ── Bind protected targets in the central registry ────────────────
        // `bindContract` is not self-timelocked, so it can be invoked
        // directly by the `CONFIG_ROLE` holder (admin) at any time.
        vm.startPrank(admin);
        timelock.bindContract(address(assetCX), CT.CT_ASSETCX);
        timelock.bindContract(address(merchant), CT.CT_MERCHANT);
        vm.stopPrank();

        // ── Pre-activation wiring ────────────────────────────────────────
        // The merchant needs `MERCHANT_ROLE` on AssetCX to mint/burn. AssetCX
        // `grantRole` is `afterDelay`-gated, but the modifier no-ops while
        // AssetCX's local `active` flag is still false (set by
        // `assetCX.activateTimelock`).
        vm.prank(admin);
        assetCX.grantRole(AssetCxRolesLib.MERCHANT_ROLE, address(merchant));
    }

    /// @dev Flips all three enforcement flags. After this call, every
    ///      `afterDelay`-gated call on `timelock` / `assetCX` / `merchant`
    ///      requires a matured `propose` to succeed.
    function _activateAll() internal {
        vm.prank(admin);
        timelock.activateTimelock();
        vm.prank(admin);
        assetCX.activateTimelock();
        vm.prank(admin);
        merchant.activateTimelock();
    }

    /// @dev Schedules `(target, selector, args)` via {propose} as `proposer`,
    ///      then warps `block.timestamp` to the resulting `readyAt`.
    function _proposeAndWarp(address target, bytes4 selector, bytes memory args) internal returns (bytes32 actionId) {
        vm.prank(proposer);
        actionId = timelock.propose(target, selector, args);
        vm.warp(timelock.readyAt(actionId));
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// AssetCX — timelock-gated surface
// ═════════════════════════════════════════════════════════════════════════════
//
// Gated artifacts seeded under `CT_ASSETCX` in `Timelock.initialize`:
//   • `upgradeToAndCall(address,bytes)` — TIER_1
//   • `setTimelock(address)`            — TIER_1
//   • `unpause()`                       — TIER_2
//   • `grantRole(MERCHANT_ROLE, *)`     — TIER_1 (per-role artifact)
// Intentionally NOT gated (instant, no artifact):
//   • `pause()`                         — circuit breaker
//   • `grantRole(PAUSER_ROLE, *)`       — fast pauser onboarding
//
// Each artifact has two tests: one proving the call reverts without a prior
// matured `propose`, and one proving the call succeeds (or, for `setTimelock`,
// surfaces the post-activation body invariant) once the schedule entry has
// matured.

contract AssetCxTimelockTest is TimelockTestBase {
    // ── upgradeToAndCall (TIER_1) ─────────────────────────────────────────

    function test_assetCx_upgradeToAndCall_revertsWithoutPropose() public {
        _activateAll();

        AssetCX newImpl = new AssetCX();
        bytes4 selector = UUPSUpgradeable.upgradeToAndCall.selector;
        bytes memory args = abi.encode(address(newImpl), bytes(""));
        bytes32 expectedActionId = timelock.computeActionId(address(assetCX), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        assetCX.upgradeToAndCall(address(newImpl), "");
    }

    function test_assetCx_upgradeToAndCall_succeedsWithProposeAndDelay() public {
        _activateAll();

        AssetCX newImpl = new AssetCX();
        bytes4 selector = UUPSUpgradeable.upgradeToAndCall.selector;
        bytes memory args = abi.encode(address(newImpl), bytes(""));
        bytes32 actionId = _proposeAndWarp(address(assetCX), selector, args);

        // Schedule should have been queued at the TIER_1 delay.
        assertEq(timelock.readyAt(actionId), block.timestamp, "matured readyAt should equal current block after warp");

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(assetCX));
        emit IERC1967.Upgraded(address(newImpl));

        vm.prank(admin);
        assetCX.upgradeToAndCall(address(newImpl), "");

        bytes32 storedImpl = vm.load(address(assetCX), IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(storedImpl))), address(newImpl), "impl pointer not updated");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── setTimelock (TIER_1) ──────────────────────────────────────────────
    //

    function test_assetCx_setTimelock_revertsWithoutPropose() public {
        _activateAll();

        address newTimelock = makeAddr("newTimelock");
        bytes4 selector = ITimelockProtected.setTimelock.selector;
        bytes memory args = abi.encode(newTimelock);
        bytes32 expectedActionId = timelock.computeActionId(address(assetCX), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        assetCX.setTimelock(newTimelock);
    }

    function test_assetCx_setTimelock_succeedsWithProposeAndDelay() public {
        _activateAll();

        address newTimelock = makeAddr("newTimelock");
        bytes4 selector = ITimelockProtected.setTimelock.selector;
        bytes memory args = abi.encode(newTimelock);
        bytes32 actionId = _proposeAndWarp(address(assetCX), selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(assetCX));
        emit ITimelockProtected.TimelockSet(newTimelock);

        vm.prank(admin);
        assetCX.setTimelock(newTimelock);

        (address storedTimelock, bool active) = assetCX.getTimelock();
        assertEq(storedTimelock, newTimelock, "timelock address not updated");
        assertTrue(active, "enforcement flag should remain active after migration");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── grantRole(MERCHANT_ROLE) (TIER_1) ────────────────────────────────

    function test_assetCx_grantRole_merchantRole_revertsWithoutPropose() public {
        _activateAll();

        address newMerchant = makeAddr("newMerchant");
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(AssetCxRolesLib.MERCHANT_ROLE, newMerchant);
        bytes32 expectedActionId = timelock.computeActionId(address(assetCX), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        assetCX.grantRole(AssetCxRolesLib.MERCHANT_ROLE, newMerchant);
    }

    function test_assetCx_grantRole_merchantRole_succeedsWithProposeAndDelay() public {
        _activateAll();

        address newMerchant = makeAddr("newMerchant");
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(AssetCxRolesLib.MERCHANT_ROLE, newMerchant);
        bytes32 actionId = _proposeAndWarp(address(assetCX), selector, args);

        // MERCHANT_ROLE artifact should resolve to TIER_1 (highest risk: unbounded mint surface).
        assertEq(
            timelock.artifactDelayTier(CT.CT_ASSETCX, AssetCxRolesLib.MERCHANT_ROLE),
            Config.TIER_1,
            "MERCHANT_ROLE artifact tier mismatch"
        );

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);

        vm.prank(admin);
        assetCX.grantRole(AssetCxRolesLib.MERCHANT_ROLE, newMerchant);

        assertTrue(
            assetCX.hasRole(AssetCxRolesLib.MERCHANT_ROLE, newMerchant), "MERCHANT_ROLE not granted to recipient"
        );
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── pause (instant, no timelock) ─────────────────────────────────────

    function test_assetCx_pause_isInstantEvenWhenTimelockActive() public {
        _activateAll();

        // No propose, no warp — just call. Pause is intentionally NOT
        // routed through `afterDelay`; that's the whole point of the role.
        vm.expectEmit(true, true, true, true, address(assetCX));
        emit PausableUpgradeable.Paused(admin);

        vm.prank(admin);
        assetCX.pause();

        assertTrue(assetCX.paused(), "expected paused state after pause()");
    }

    // ── unpause (TIER_2) ─────────────────────────────────────────────────

    function test_assetCx_unpause_revertsWithoutPropose() public {
        // Pause first so `_unpause`'s own `whenPaused` precondition holds —
        // otherwise we couldn't distinguish a timelock-revert from a
        // state-revert. We pause BEFORE activating so the propose-less path
        // is exercised purely against the active timelock.
        vm.prank(admin);
        assetCX.pause();

        _activateAll();

        bytes4 selector = IAssetCxInheritedSelectors.unpause.selector;
        bytes memory args = bytes("");
        bytes32 expectedActionId = timelock.computeActionId(address(assetCX), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        assetCX.unpause();
    }

    function test_assetCx_unpause_succeedsWithProposeAndDelay() public {
        vm.prank(admin);
        assetCX.pause();
        assertTrue(assetCX.paused(), "fixture: contract should be paused");

        _activateAll();

        bytes4 selector = IAssetCxInheritedSelectors.unpause.selector;
        bytes memory args = bytes("");
        bytes32 actionId = _proposeAndWarp(address(assetCX), selector, args);

        assertEq(
            timelock.artifactDelayTier(CT.CT_ASSETCX, bytes32(selector)),
            Config.TIER_3,
            "unpause artifact tier mismatch"
        );

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(assetCX));
        emit PausableUpgradeable.Unpaused(admin);

        vm.prank(admin);
        assetCX.unpause();

        assertFalse(assetCX.paused(), "expected unpaused state after unpause()");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── grantRole(PAUSER_ROLE) (instant, no timelock) ────────────────────

    function test_assetCx_grantRole_pauserRole_bypassesTimelock() public {
        // With the timelock fully active, granting PAUSER_ROLE must NOT
        // require a propose — `grantRole` short-circuits the role check.
        _activateAll();

        address newPauser = makeAddr("newPauser");

        vm.prank(admin);
        assetCX.grantRole(AssetCxRolesLib.PAUSER_ROLE, newPauser);

        assertTrue(assetCX.hasRole(AssetCxRolesLib.PAUSER_ROLE, newPauser), "PAUSER_ROLE not granted to fresh pauser");

        // And the freshly-onboarded pauser can immediately pause.
        vm.prank(newPauser);
        assetCX.pause();
        assertTrue(assetCX.paused(), "fresh pauser unable to pause");
    }

    // ── grantRole(DEFAULT_ADMIN_ROLE) (TIER_1) ───────────────────────────
    //
    // NOTE: requires `seedAssetCxArtifacts` in earn-v2-core's
    // `TimelockConfigurationLib` to register the artifact under
    // `DEFAULT_ADMIN_ROLE` (== `bytes32(0)`), NOT under
    // `keccak256("DEFAULT_ADMIN_ROLE")`. The two are different values and
    // `Timelock._artifactFor` keys the lookup on the decoded `role` arg,
    // which is `bytes32(0)` for `DEFAULT_ADMIN_ROLE`.

    function test_assetCx_grantRole_defaultAdminRole_tierIsTier1() public view {
        assertEq(
            timelock.artifactDelayTier(CT.CT_ASSETCX, assetCX.DEFAULT_ADMIN_ROLE()),
            Config.TIER_1,
            "DEFAULT_ADMIN_ROLE artifact tier mismatch (seeding must use DEFAULT_ADMIN_ROLE, not keccak256(\"DEFAULT_ADMIN_ROLE\"))"
        );
    }

    function test_assetCx_grantRole_defaultAdminRole_revertsWithoutPropose() public {
        _activateAll();

        address newAdmin = makeAddr("newAdmin");
        // Cache the role BEFORE the prank — reading it via `assetCX.DEFAULT_ADMIN_ROLE()`
        // is an external call that consumes the one-shot `vm.prank(admin)`, leaving the
        // actual `grantRole` call with `msg.sender == address(this)` (the test contract).
        bytes32 role = assetCX.DEFAULT_ADMIN_ROLE();
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(role, newAdmin);
        bytes32 expectedActionId = timelock.computeActionId(address(assetCX), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        assetCX.grantRole(role, newAdmin);
    }

    function test_assetCx_grantRole_defaultAdminRole_succeedsWithProposeAndDelay() public {
        _activateAll();

        address newAdmin = makeAddr("newAdmin");
        // Cache before the prank — see {test_assetCx_grantRole_defaultAdminRole_revertsWithoutPropose}.
        bytes32 role = assetCX.DEFAULT_ADMIN_ROLE();
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(role, newAdmin);
        bytes32 actionId = _proposeAndWarp(address(assetCX), selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);

        vm.prank(admin);
        assetCX.grantRole(role, newAdmin);

        assertTrue(assetCX.hasRole(role, newAdmin), "DEFAULT_ADMIN_ROLE not granted to recipient");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// ConcreteMerchant — timelock-gated surface
// ═════════════════════════════════════════════════════════════════════════════
//
// Gated artifacts seeded under `CT_MERCHANT` in `Timelock.initialize`:
//   • `upgradeToAndCall(address,bytes)`                  — TIER_1
//   • `setTimelock(address)`                             — TIER_1
//   • `emergencyMigrateUserAccount(bytes32,address)`     — TIER_1
//   • `setUserAccount(bytes32,address)`                  — TIER_3
//   • `setUserVault(bytes32,address)`                    — TIER_3
//   • `removeUserVault(bytes32)`                         — TIER_3
//   • `setUserData(bytes32,bytes)`                       — TIER_3
//   • `setVaultYieldConfig(address,address,address)`     — TIER_2
//   • `setYieldTokenWhitelisted(address,bool)`           — TIER_2
//   • `unpause()`                                        — TIER_3
//   • `grantRole(MERCHANT_MANAGER_ROLE, *)`              — TIER_1 (per-role)
//   • `grantRole(OPERATOR_ROLE, *)`                      — TIER_2 (per-role)
// Intentionally NOT gated (instant, no artifact):
//   • `pause()`                                          — circuit breaker
//   • `grantRole(PAUSER_ROLE, *)`                        — fast pauser onboarding

contract ConcreteMerchantTimelockTest is TimelockTestBase {
    // Fixture state pre-loaded before activation so the `afterDelay`-gated
    // happy-path tests have non-trivial bodies to execute. While the merchant's
    // local active flag is still false, the `afterDelay` modifier no-ops and
    // these admin calls go straight through.

    /// @dev User with active vault shares (used by emergencyMigrate happy path).
    bytes32 internal constant DEPOSITED_USER_ID = keccak256("user-deposited");
    /// @dev User account set but no active deposits (used by setUserVault / removeUserVault).
    bytes32 internal constant NO_DEPOSIT_USER_ID = keccak256("user-no-deposit");
    /// @dev Brand-new userId with no account set (used by setUserAccount happy path).
    bytes32 internal constant FRESH_USER_ID = keccak256("user-fresh");

    address internal depositedUser;
    address internal noDepositUser;
    address internal newAccount;

    uint256 internal constant SEED_DEPOSIT = 500e18;

    function setUp() public override {
        super.setUp();

        depositedUser = makeAddr("depositedUser");
        noDepositUser = makeAddr("noDepositUser");
        newAccount = makeAddr("newAccount");

        // Grant the admin OPERATOR_ROLE so they can drive `mintAndDeposit` in
        // the fixture. `grantRole` is `afterDelay`-gated on the merchant but
        // the modifier no-ops pre-activation.
        vm.startPrank(admin);
        merchant.grantRole(merchant.OPERATOR_ROLE(), admin);

        // User accounts: one with shares, one without.
        merchant.setUserAccount(DEPOSITED_USER_ID, depositedUser);
        merchant.setUserAccount(NO_DEPOSIT_USER_ID, noDepositUser);

        // Yield config so the body of `setVaultYieldConfig` has a no-op path
        // (re-registering the same config) — not strictly required, but it
        // mirrors the production deploy ordering.
        merchant.setVaultYieldConfig(address(assetCXVault), address(strategy), yieldMultisig);

        // Deposit shares for DEPOSITED_USER so `emergencyMigrateUserAccount`
        // has a non-zero `mintedVaultShares` to migrate.
        merchant.mintAndDeposit(DEPOSITED_USER_ID, SEED_DEPOSIT, keccak256("seed-deposit"));
        vm.stopPrank();

        // User pre-approves the merchant for share transfers (required by
        // `emergencyMigrateUserAccount.safeTransferFrom`).
        vm.prank(depositedUser);
        IERC20(address(assetCXVault)).approve(address(merchant), type(uint256).max);

        assertEq(merchant.mintedVaultShares(DEPOSITED_USER_ID), SEED_DEPOSIT, "fixture: shares not minted");
        assertEq(assetCXVault.balanceOf(depositedUser), SEED_DEPOSIT, "fixture: shares not delivered to user");
    }

    // ── upgradeToAndCall (TIER_1) ─────────────────────────────────────────

    function test_merchant_upgradeToAndCall_revertsWithoutPropose() public {
        _activateAll();

        ConcreteMerchant newImpl = new ConcreteMerchant();
        bytes4 selector = UUPSUpgradeable.upgradeToAndCall.selector;
        bytes memory args = abi.encode(address(newImpl), bytes(""));
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.upgradeToAndCall(address(newImpl), "");
    }

    function test_merchant_upgradeToAndCall_succeedsWithProposeAndDelay() public {
        _activateAll();

        ConcreteMerchant newImpl = new ConcreteMerchant();
        bytes4 selector = UUPSUpgradeable.upgradeToAndCall.selector;
        bytes memory args = abi.encode(address(newImpl), bytes(""));
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(merchant));
        emit IERC1967.Upgraded(address(newImpl));

        vm.prank(admin);
        merchant.upgradeToAndCall(address(newImpl), "");

        bytes32 storedImpl = vm.load(address(merchant), IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(storedImpl))), address(newImpl), "impl pointer not updated");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── setTimelock (TIER_1) ──────────────────────────────────────────────

    function test_merchant_setTimelock_revertsWithoutPropose() public {
        _activateAll();

        address newTimelock = makeAddr("newTimelock");
        bytes4 selector = ITimelockProtected.setTimelock.selector;
        bytes memory args = abi.encode(newTimelock);
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.setTimelock(newTimelock);
    }

    function test_merchant_setTimelock_succeedsWithProposeAndDelay() public {
        _activateAll();

        address newTimelock = makeAddr("newTimelock");
        bytes4 selector = ITimelockProtected.setTimelock.selector;
        bytes memory args = abi.encode(newTimelock);
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(merchant));
        emit ITimelockProtected.TimelockSet(newTimelock);

        vm.prank(admin);
        merchant.setTimelock(newTimelock);

        (address storedTimelock, bool active) = merchant.getTimelock();
        assertEq(storedTimelock, newTimelock, "timelock address not updated");
        assertTrue(active, "enforcement flag should remain active after migration");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── emergencyMigrateUserAccount (TIER_1) ─────────────────────────────

    function test_merchant_emergencyMigrateUserAccount_revertsWithoutPropose() public {
        _activateAll();

        bytes4 selector = ConcreteMerchant.emergencyMigrateUserAccount.selector;
        bytes memory args = abi.encode(DEPOSITED_USER_ID, newAccount);
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.emergencyMigrateUserAccount(DEPOSITED_USER_ID, newAccount);
    }

    function test_merchant_emergencyMigrateUserAccount_succeedsWithProposeAndDelay() public {
        _activateAll();

        bytes4 selector = ConcreteMerchant.emergencyMigrateUserAccount.selector;
        bytes memory args = abi.encode(DEPOSITED_USER_ID, newAccount);
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.EmergencyUserAccountMigrated(DEPOSITED_USER_ID, depositedUser, newAccount, SEED_DEPOSIT);

        vm.prank(admin);
        merchant.emergencyMigrateUserAccount(DEPOSITED_USER_ID, newAccount);

        assertEq(assetCXVault.balanceOf(depositedUser), 0, "old account still holds shares");
        assertEq(assetCXVault.balanceOf(newAccount), SEED_DEPOSIT, "new account did not receive shares");
        assertEq(merchant.getUserAccount(DEPOSITED_USER_ID), newAccount, "user account not migrated");
        assertTrue(whitelistHook.userWhitelisted(newAccount), "new account not whitelisted");
        assertFalse(whitelistHook.userWhitelisted(depositedUser), "old account not removed from whitelist");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── setUserAccount (TIER_3) ──────────────────────────────────────────

    function test_merchant_setUserAccount_revertsWithoutPropose() public {
        _activateAll();

        address freshAccount = makeAddr("freshAccount");
        bytes4 selector = ConcreteMerchant.setUserAccount.selector;
        bytes memory args = abi.encode(FRESH_USER_ID, freshAccount);
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.setUserAccount(FRESH_USER_ID, freshAccount);
    }

    function test_merchant_setUserAccount_succeedsWithProposeAndDelay() public {
        _activateAll();

        address freshAccount = makeAddr("freshAccount");
        bytes4 selector = ConcreteMerchant.setUserAccount.selector;
        bytes memory args = abi.encode(FRESH_USER_ID, freshAccount);
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        // Pin the seeded tier so accidental re-tiering in the upstream
        // config fails this test loudly (mirrors the OPERATOR_ROLE /
        // setUserData assertions).
        assertEq(
            timelock.artifactDelayTier(CT.CT_MERCHANT, bytes32(selector)),
            Config.TIER_3,
            "setUserAccount artifact tier mismatch"
        );

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.UserAccountSet(FRESH_USER_ID, freshAccount);

        vm.prank(admin);
        merchant.setUserAccount(FRESH_USER_ID, freshAccount);

        assertEq(merchant.getUserAccount(FRESH_USER_ID), freshAccount, "user account not set");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── setUserVault (TIER_3) ────────────────────────────────────────────

    function test_merchant_setUserVault_revertsWithoutPropose() public {
        _activateAll();

        MockAssetCXVault altVault = new MockAssetCXVault(IERC20(address(assetCX)));
        bytes4 selector = ConcreteMerchant.setUserVault.selector;
        bytes memory args = abi.encode(NO_DEPOSIT_USER_ID, address(altVault));
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.setUserVault(NO_DEPOSIT_USER_ID, IERC4626(address(altVault)));
    }

    function test_merchant_setUserVault_succeedsWithProposeAndDelay() public {
        _activateAll();

        MockAssetCXVault altVault = new MockAssetCXVault(IERC20(address(assetCX)));
        bytes4 selector = ConcreteMerchant.setUserVault.selector;
        bytes memory args = abi.encode(NO_DEPOSIT_USER_ID, address(altVault));
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.UserVaultSet(NO_DEPOSIT_USER_ID, address(altVault));

        vm.prank(admin);
        merchant.setUserVault(NO_DEPOSIT_USER_ID, IERC4626(address(altVault)));

        assertEq(address(merchant.userVault(NO_DEPOSIT_USER_ID)), address(altVault), "user vault override not set");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── removeUserVault (TIER_3) ─────────────────────────────────────────

    function test_merchant_removeUserVault_revertsWithoutPropose() public {
        _activateAll();

        bytes4 selector = ConcreteMerchant.removeUserVault.selector;
        bytes memory args = abi.encode(NO_DEPOSIT_USER_ID);
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.removeUserVault(NO_DEPOSIT_USER_ID);
    }

    function test_merchant_removeUserVault_succeedsWithProposeAndDelay() public {
        _activateAll();

        bytes4 selector = ConcreteMerchant.removeUserVault.selector;
        bytes memory args = abi.encode(NO_DEPOSIT_USER_ID);
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.UserVaultRemoved(NO_DEPOSIT_USER_ID);

        vm.prank(admin);
        merchant.removeUserVault(NO_DEPOSIT_USER_ID);

        assertEq(address(merchant.userVault(NO_DEPOSIT_USER_ID)), address(0), "user vault override not cleared");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── setUserData (TIER_3) ─────────────────────────────────────────────

    function test_merchant_setUserData_revertsWithoutPropose() public {
        _activateAll();

        bytes memory payload = abi.encode(makeAddr("custodianKey"), makeAddr("custodianBeneficiary"));
        bytes4 selector = ConcreteMerchant.setUserData.selector;
        bytes memory args = abi.encode(NO_DEPOSIT_USER_ID, payload);
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.setUserData(NO_DEPOSIT_USER_ID, payload);
    }

    function test_merchant_setUserData_succeedsWithProposeAndDelay() public {
        _activateAll();

        address custodianKey = makeAddr("custodianKey");
        address custodianBeneficiary = makeAddr("custodianBeneficiary");
        bytes memory payload = abi.encode(custodianKey, custodianBeneficiary);
        bytes4 selector = ConcreteMerchant.setUserData.selector;
        bytes memory args = abi.encode(NO_DEPOSIT_USER_ID, payload);
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        // Confirm the artifact resolves at TIER_3 (mirrors the OPERATOR_ROLE
        // assertion below — pins the seeded tier so accidental re-tiering in
        // the upstream config fails this test loudly).
        assertEq(
            timelock.artifactDelayTier(CT.CT_MERCHANT, bytes32(selector)),
            Config.TIER_3,
            "setUserData artifact tier mismatch"
        );

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, false, false, true, address(merchant));
        emit IConcreteMerchant.UserDataSet(NO_DEPOSIT_USER_ID, payload);

        vm.prank(admin);
        merchant.setUserData(NO_DEPOSIT_USER_ID, payload);

        bytes memory stored = merchant.userData(NO_DEPOSIT_USER_ID);
        assertEq(stored, payload, "stored payload mismatch");
        (address decodedKey, address decodedBeneficiary) = abi.decode(stored, (address, address));
        assertEq(decodedKey, custodianKey, "custodian key not preserved");
        assertEq(decodedBeneficiary, custodianBeneficiary, "custodian beneficiary not preserved");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── setVaultYieldConfig (TIER_2) ─────────────────────────────────────

    function test_merchant_setVaultYieldConfig_revertsWithoutPropose() public {
        _activateAll();

        // Different multisig so the artifact key (selector + args) is distinct
        // from the seed config written pre-activation.
        address freshYieldMultisig = makeAddr("freshYieldMultisig");
        bytes4 selector = ConcreteMerchant.setVaultYieldConfig.selector;
        bytes memory args = abi.encode(address(assetCXVault), address(strategy), freshYieldMultisig);
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.setVaultYieldConfig(address(assetCXVault), address(strategy), freshYieldMultisig);
    }

    function test_merchant_setVaultYieldConfig_succeedsWithProposeAndDelay() public {
        _activateAll();

        address freshYieldMultisig = makeAddr("freshYieldMultisig");
        bytes4 selector = ConcreteMerchant.setVaultYieldConfig.selector;
        bytes memory args = abi.encode(address(assetCXVault), address(strategy), freshYieldMultisig);
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.VaultYieldConfigSet(address(assetCXVault), address(strategy), freshYieldMultisig);

        vm.prank(admin);
        merchant.setVaultYieldConfig(address(assetCXVault), address(strategy), freshYieldMultisig);

        assertEq(merchant.vaultYieldMultisig(address(assetCXVault)), freshYieldMultisig, "yield multisig not updated");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── setYieldTokenWhitelisted (TIER_2) ────────────────────────────────

    function test_merchant_setYieldTokenWhitelisted_revertsWithoutPropose() public {
        _activateAll();

        bytes4 selector = ConcreteMerchant.setYieldTokenWhitelisted.selector;
        bytes memory args = abi.encode(address(yieldToken), true);
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.setYieldTokenWhitelisted(address(yieldToken), true);
    }

    function test_merchant_setYieldTokenWhitelisted_succeedsWithProposeAndDelay() public {
        _activateAll();

        bytes4 selector = ConcreteMerchant.setYieldTokenWhitelisted.selector;
        bytes memory args = abi.encode(address(yieldToken), true);
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        // Pin the seeded tier so accidental re-tiering in the upstream
        // config fails this test loudly (earn-v2-core seeds this selector at TIER_2).
        assertEq(
            timelock.artifactDelayTier(CT.CT_MERCHANT, bytes32(selector)),
            Config.TIER_2,
            "setYieldTokenWhitelisted artifact tier mismatch"
        );

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.YieldTokenWhitelisted(address(yieldToken), true);

        vm.prank(admin);
        merchant.setYieldTokenWhitelisted(address(yieldToken), true);

        assertTrue(merchant.isYieldTokenWhitelisted(address(yieldToken)), "token not whitelisted post-execute");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── grantRole(MERCHANT_MANAGER_ROLE) (TIER_1, per-role artifact) ─────

    function test_merchant_grantRole_managerRole_revertsWithoutPropose() public {
        _activateAll();

        address newManager = makeAddr("newManager");
        bytes32 role = merchant.MERCHANT_MANAGER_ROLE();
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(role, newManager);
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.grantRole(role, newManager);
    }

    function test_merchant_grantRole_managerRole_succeedsWithProposeAndDelay() public {
        _activateAll();

        address newManager = makeAddr("newManager");
        bytes32 role = merchant.MERCHANT_MANAGER_ROLE();
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(role, newManager);
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        assertEq(
            timelock.artifactDelayTier(CT.CT_MERCHANT, role),
            Config.TIER_1,
            "MERCHANT_MANAGER_ROLE artifact tier mismatch"
        );

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);

        vm.prank(admin);
        merchant.grantRole(role, newManager);

        assertTrue(merchant.hasRole(role, newManager), "MERCHANT_MANAGER_ROLE not granted");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── grantRole(OPERATOR_ROLE) (TIER_2, per-role artifact) ─────────────

    function test_merchant_grantRole_operatorRole_revertsWithoutPropose() public {
        _activateAll();

        address newOperator = makeAddr("newOperator");
        bytes32 role = merchant.OPERATOR_ROLE();
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(role, newOperator);
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.grantRole(role, newOperator);
    }

    function test_merchant_grantRole_operatorRole_succeedsWithProposeAndDelay() public {
        _activateAll();

        address newOperator = makeAddr("newOperator");
        bytes32 role = merchant.OPERATOR_ROLE();
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(role, newOperator);
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        // Schedule should have been queued at TIER_2 — distinct from
        // MERCHANT_MANAGER_ROLE's TIER_1 tier.
        assertEq(
            timelock.artifactDelayTier(CT.CT_MERCHANT, role), Config.TIER_2, "OPERATOR_ROLE artifact tier mismatch"
        );

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);

        vm.prank(admin);
        merchant.grantRole(role, newOperator);

        assertTrue(merchant.hasRole(role, newOperator), "OPERATOR_ROLE not granted");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── grantRole(DEFAULT_ADMIN_ROLE) (TIER_1) ───────────────────────────
    //
    // NOTE: requires `seedConcreteMerchantArtifacts` in earn-v2-core's
    // `TimelockConfigurationLib` to register the artifact under
    // `DEFAULT_ADMIN_ROLE` (== `bytes32(0)`), NOT under
    // `keccak256("DEFAULT_ADMIN_ROLE")`. The two are different values and
    // `Timelock._artifactFor` keys the lookup on the decoded `role` arg,
    // which is `bytes32(0)` for `DEFAULT_ADMIN_ROLE`.

    function test_merchant_grantRole_defaultAdminRole_tierIsTier1() public view {
        assertEq(
            timelock.artifactDelayTier(CT.CT_MERCHANT, merchant.DEFAULT_ADMIN_ROLE()),
            Config.TIER_1,
            "DEFAULT_ADMIN_ROLE artifact tier mismatch (seeding must use DEFAULT_ADMIN_ROLE, not keccak256(\"DEFAULT_ADMIN_ROLE\"))"
        );
    }

    function test_merchant_grantRole_defaultAdminRole_revertsWithoutPropose() public {
        _activateAll();

        address newAdmin = makeAddr("newAdmin");
        // Cache the role BEFORE the prank — reading it via `merchant.DEFAULT_ADMIN_ROLE()`
        // is an external call that consumes the one-shot `vm.prank(admin)`, leaving the
        // actual `grantRole` call with `msg.sender == address(this)` (the test contract).
        bytes32 role = merchant.DEFAULT_ADMIN_ROLE();
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(role, newAdmin);
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.grantRole(role, newAdmin);
    }

    function test_merchant_grantRole_defaultAdminRole_succeedsWithProposeAndDelay() public {
        _activateAll();

        address newAdmin = makeAddr("newAdmin");
        // Cache before the prank — see {test_merchant_grantRole_defaultAdminRole_revertsWithoutPropose}.
        bytes32 role = merchant.DEFAULT_ADMIN_ROLE();
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(role, newAdmin);
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);

        vm.prank(admin);
        merchant.grantRole(role, newAdmin);

        assertTrue(merchant.hasRole(role, newAdmin), "DEFAULT_ADMIN_ROLE not granted to recipient");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── pause (instant, no timelock) ─────────────────────────────────────

    function test_merchant_pause_isInstantEvenWhenTimelockActive() public {
        _activateAll();

        vm.expectEmit(true, true, true, true, address(merchant));
        emit PausableUpgradeable.Paused(admin);

        vm.prank(admin);
        merchant.pause();

        assertTrue(merchant.paused(), "expected paused state after pause()");
    }

    function test_merchant_pause_blocksOperationalFlow() public {
        // Sanity: confirm `whenNotPaused` is actually wired to the user-facing
        // operational surface. We use `mintAndDeposit` as the canonical case
        // since the fixture already has DEPOSITED_USER set up.
        vm.prank(admin);
        merchant.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(admin);
        merchant.mintAndDeposit(DEPOSITED_USER_ID, 1e18, keccak256("blocked-mint"));
    }

    // ── unpause (TIER_2) ─────────────────────────────────────────────────

    function test_merchant_unpause_revertsWithoutPropose() public {
        vm.prank(admin);
        merchant.pause();

        _activateAll();

        bytes4 selector = IConcreteMerchantInheritedSelectors.unpause.selector;
        bytes memory args = bytes("");
        bytes32 expectedActionId = timelock.computeActionId(address(merchant), selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        merchant.unpause();
    }

    function test_merchant_unpause_succeedsWithProposeAndDelay() public {
        vm.prank(admin);
        merchant.pause();
        assertTrue(merchant.paused(), "fixture: merchant should be paused");

        _activateAll();

        bytes4 selector = IConcreteMerchantInheritedSelectors.unpause.selector;
        bytes memory args = bytes("");
        bytes32 actionId = _proposeAndWarp(address(merchant), selector, args);

        assertEq(
            timelock.artifactDelayTier(CT.CT_MERCHANT, bytes32(selector)),
            Config.TIER_3,
            "unpause artifact tier mismatch"
        );

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(merchant));
        emit PausableUpgradeable.Unpaused(admin);

        vm.prank(admin);
        merchant.unpause();

        assertFalse(merchant.paused(), "expected unpaused state after unpause()");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ── grantRole(PAUSER_ROLE) (instant, no timelock) ────────────────────

    function test_merchant_grantRole_pauserRole_bypassesTimelock() public {
        _activateAll();

        address newPauser = makeAddr("newMerchantPauser");
        // Cache PAUSER_ROLE() to a local — calling it inline as an argument
        // would consume the next `vm.prank` on the staticcall and leave the
        // grantRole running as the test contract (not admin).
        bytes32 pauserRole = merchant.PAUSER_ROLE();

        vm.prank(admin);
        merchant.grantRole(pauserRole, newPauser);

        assertTrue(merchant.hasRole(pauserRole, newPauser), "PAUSER_ROLE not granted to fresh pauser");

        vm.prank(newPauser);
        merchant.pause();
        assertTrue(merchant.paused(), "fresh pauser unable to pause");
    }
}
