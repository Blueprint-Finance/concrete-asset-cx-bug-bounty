// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetCX} from "../src/AssetCX.sol";
import {IAssetCX} from "../src/interface/IAssetCX.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC1967} from "@openzeppelin-contracts/interfaces/IERC1967.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";

contract AssetCXTest is Test {
    AssetCX public token;

    address public admin = address(0x1);
    address public merchant = address(0x2);
    address public user = address(0x3);

    bytes32 public constant MERCHANT_ROLE = keccak256("MERCHANT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        // Deploy AssetCX implementation and proxy
        AssetCX implementation = new AssetCX();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(AssetCX.initialize, ("Asset CX", "ACX", admin, address(0)))
        );
        token = AssetCX(address(proxy));

        // Grant MERCHANT_ROLE to merchant address
        vm.prank(admin);
        token.grantRole(MERCHANT_ROLE, merchant);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor() public view {
        assertEq(token.name(), "Asset CX");
        assertEq(token.symbol(), "ACX");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_constructor_revertsWhenAdminIsZeroAddress() public {
        AssetCX implementation = new AssetCX();
        vm.expectRevert(IAssetCX.AdminCannotBeZeroAddress.selector);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(AssetCX.initialize, ("Asset CX", "ACX", address(0), address(0)))
        );
    }

    /*//////////////////////////////////////////////////////////////
                        MINT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_mint_success() public {
        uint256 amount = 1000e18;

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), merchant, amount);

        vm.prank(merchant);
        token.mint(amount);

        assertEq(token.balanceOf(merchant), amount);
        assertEq(token.totalSupply(), amount);
    }

    function test_mint_revertsWhenNotMerchant() public {
        vm.prank(user);
        vm.expectRevert();
        token.mint(1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                        BURN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_burn_success() public {
        uint256 mintAmount = 1000e18;
        uint256 burnAmount = 400e18;

        // First mint tokens
        vm.prank(merchant);
        token.mint(mintAmount);

        // Then burn
        vm.expectEmit(true, true, true, true);
        emit Transfer(merchant, address(0), burnAmount);

        vm.prank(merchant);
        token.burn(burnAmount);

        assertEq(token.balanceOf(merchant), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function test_burn_revertsWhenNotMerchant() public {
        // Mint tokens first
        vm.prank(merchant);
        token.mint(1000e18);

        // Try to burn without role
        vm.prank(user);
        vm.expectRevert();
        token.burn(500e18);
    }

    function test_burn_revertsWhenInsufficientBalance() public {
        vm.prank(merchant);
        token.mint(100e18);

        vm.prank(merchant);
        vm.expectRevert();
        token.burn(200e18);
    }

    /*//////////////////////////////////////////////////////////////
                        ROLE MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_grantRole_success() public {
        address newMerchant = address(0x4);

        assertFalse(token.hasRole(MERCHANT_ROLE, newMerchant));

        vm.prank(admin);
        token.grantRole(MERCHANT_ROLE, newMerchant);

        assertTrue(token.hasRole(MERCHANT_ROLE, newMerchant));
    }

    function test_revokeRole_success() public {
        assertTrue(token.hasRole(MERCHANT_ROLE, merchant));

        vm.prank(admin);
        token.revokeRole(MERCHANT_ROLE, merchant);

        assertFalse(token.hasRole(MERCHANT_ROLE, merchant));

        // Merchant can no longer mint
        vm.prank(merchant);
        vm.expectRevert();
        token.mint(1000e18);
    }

    function test_grantRole_revertsWhenNotAdmin() public {
        address newMerchant = address(0x4);

        vm.prank(user);
        vm.expectRevert();
        token.grantRole(MERCHANT_ROLE, newMerchant);
    }

    /*//////////////////////////////////////////////////////////////
                        UPGRADE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_upgradeToNewImplementation_preservesState() public {
        // Set up some state before upgrade
        uint256 mintAmount = 5000e18;
        address newMerchant = address(0x4);

        // Mint some tokens
        vm.prank(merchant);
        token.mint(mintAmount);

        // Grant a role
        vm.prank(admin);
        token.grantRole(MERCHANT_ROLE, newMerchant);

        // Verify initial state
        assertEq(token.balanceOf(merchant), mintAmount);
        assertEq(token.totalSupply(), mintAmount);
        assertTrue(token.hasRole(MERCHANT_ROLE, merchant));
        assertTrue(token.hasRole(MERCHANT_ROLE, newMerchant));
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertEq(token.name(), "Asset CX");
        assertEq(token.symbol(), "ACX");

        // Deploy new implementation (V2 - identical for this test)
        AssetCX v2Implementation = new AssetCX();

        // Upgrade the proxy to the new implementation
        vm.prank(admin);
        token.upgradeToAndCall(address(v2Implementation), "");

        // Verify state is preserved after upgrade
        assertEq(token.balanceOf(merchant), mintAmount);
        assertEq(token.totalSupply(), mintAmount);
        assertTrue(token.hasRole(MERCHANT_ROLE, merchant));
        assertTrue(token.hasRole(MERCHANT_ROLE, newMerchant));
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertEq(token.name(), "Asset CX");
        assertEq(token.symbol(), "ACX");

        // Verify functionality still works after upgrade
        uint256 additionalMint = 1000e18;
        vm.prank(merchant);
        token.mint(additionalMint);

        assertEq(token.balanceOf(merchant), mintAmount + additionalMint);
        assertEq(token.totalSupply(), mintAmount + additionalMint);

        // Verify new merchant can also mint
        vm.prank(newMerchant);
        token.mint(additionalMint);

        assertEq(token.balanceOf(newMerchant), additionalMint);
        assertEq(token.totalSupply(), mintAmount + additionalMint * 2);
    }

    function test_upgrade_revertsWhenNotAdmin() public {
        AssetCX v2Implementation = new AssetCX();

        // Non-admin cannot upgrade
        vm.prank(user);
        vm.expectRevert();
        token.upgradeToAndCall(address(v2Implementation), "");

        // Merchant cannot upgrade
        vm.prank(merchant);
        vm.expectRevert();
        token.upgradeToAndCall(address(v2Implementation), "");
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_initialize_grantsPauserRoleToAdmin() public view {
        assertTrue(token.hasRole(PAUSER_ROLE, admin), "admin should hold PAUSER_ROLE at init");
        assertFalse(token.paused(), "token should start unpaused");
    }

    function test_pause_emitsEventAndSetsState() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit PausableUpgradeable.Paused(admin);

        vm.prank(admin);
        token.pause();

        assertTrue(token.paused(), "token not paused");
    }

    function test_pause_blocksMint() public {
        vm.prank(admin);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(merchant);
        token.mint(1000e18);
    }

    function test_pause_blocksBurn() public {
        // Mint while unpaused, then pause and try to burn.
        vm.prank(merchant);
        token.mint(1000e18);

        vm.prank(admin);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(merchant);
        token.burn(500e18);
    }

    function test_pause_blocksTransfer() public {
        vm.prank(merchant);
        token.mint(1000e18);

        vm.prank(admin);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(merchant);
        token.transfer(user, 100e18);
    }

    function test_pause_revertsWhenNotPauser() public {
        vm.prank(user);
        vm.expectRevert();
        token.pause();
    }

    function test_unpause_restoresFlow() public {
        // No timelock is wired in this fixture (`address(0)` at init), so
        // `afterDelay` on `unpause()` no-ops — exactly what we want for a
        // unit-level round-trip test. Timelock-gated unpause behaviour is
        // covered in test/timelock/TimelockIntegration.t.sol.
        vm.prank(admin);
        token.pause();
        assertTrue(token.paused(), "fixture: should be paused");

        vm.expectEmit(true, true, true, true, address(token));
        emit PausableUpgradeable.Unpaused(admin);

        vm.prank(admin);
        token.unpause();

        assertFalse(token.paused(), "token should be unpaused");

        // Mint, burn and transfer all functional again.
        vm.prank(merchant);
        token.mint(1000e18);
        assertEq(token.balanceOf(merchant), 1000e18);

        vm.prank(merchant);
        token.burn(400e18);
        assertEq(token.balanceOf(merchant), 600e18);

        vm.prank(merchant);
        token.transfer(user, 100e18);
        assertEq(token.balanceOf(user), 100e18);
        assertEq(token.balanceOf(merchant), 500e18);
    }

    function test_unpause_revertsWhenNotPauser() public {
        vm.prank(admin);
        token.pause();

        vm.prank(user);
        vm.expectRevert();
        token.unpause();
    }

    function test_unpause_revertsWhenNotPaused() public {
        // `_unpause()` is itself `whenPaused` — calling on an unpaused
        // contract surfaces OZ's `ExpectedPause` error.
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        vm.prank(admin);
        token.unpause();
    }

    function test_grantPauserRole_byAdmin() public {
        address freshPauser = address(0xAA);

        vm.prank(admin);
        token.grantRole(PAUSER_ROLE, freshPauser);

        assertTrue(token.hasRole(PAUSER_ROLE, freshPauser), "PAUSER_ROLE not granted");

        // Newly-onboarded pauser can pause immediately — no extra ceremony.
        vm.prank(freshPauser);
        token.pause();
        assertTrue(token.paused(), "fresh pauser unable to pause");
    }

    /*//////////////////////////////////////////////////////////////
                    V2 ROLE ENUMERABILITY MIGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC-7201 root of OZ's `AccessControlEnumerable` storage, whose `_roleMembers`
    ///      mapping sits at offset 0. Mirrored here because the extension keeps the slot private.
    bytes32 private constant _AC_ENUMERABLE_STORAGE_LOCATION =
        0xc1f6fe24621ce81ec5827caf0253cadb74709b061630e6b55e82371705932000;

    /// @dev Throw-away addresses that hold `DEFAULT_ADMIN_ROLE` only for the few internal calls it
    ///      takes to drop and re-enter the calling admin.
    address private constant TEMP_ADMIN_A = address(0x7E5701);
    address private constant TEMP_ADMIN_B = address(0x7E5702);

    function _roleMembersSetSlot(bytes32 role) internal pure returns (bytes32) {
        return keccak256(abi.encode(role, _AC_ENUMERABLE_STORAGE_LOCATION));
    }

    /// @dev Reproduces a proxy upgraded from a non-enumerable implementation: `hasRole` keeps
    ///      reporting every pre-upgrade holder while the enumerable membership set reads empty.
    ///      Wipes the `EnumerableSet.AddressSet` behind `_roleMembers[role]` — the `_values`
    ///      length slot and its elements, plus the `_positions` entry of each listed member.
    ///      Self-verifying: a wrong layout assumption fails here instead of silently passing.
    function _clearEnumerableRoleMembers(bytes32 role, address[] memory members) internal {
        bytes32 setSlot = _roleMembersSetSlot(role);
        uint256 length = uint256(vm.load(address(token), setSlot));
        bytes32 elementsSlot = keccak256(abi.encode(setSlot));
        for (uint256 i = 0; i < length; ++i) {
            vm.store(address(token), bytes32(uint256(elementsSlot) + i), bytes32(0));
        }
        vm.store(address(token), setSlot, bytes32(0));

        bytes32 positionsSlot = bytes32(uint256(setSlot) + 1);
        for (uint256 i = 0; i < members.length; ++i) {
            vm.store(
                address(token), keccak256(abi.encode(bytes32(uint256(uint160(members[i]))), positionsSlot)), bytes32(0)
            );
            assertTrue(token.hasRole(role, members[i]), "helper: member must still hold the role");
        }

        assertEq(token.getRoleMemberCount(role), 0, "helper: membership set not cleared");
    }

    /// @dev Strips enumerable membership for every role the fixture granted, leaving the proxy in
    ///      the exact shape the live non-enumerable deployment has right after the implementation
    ///      swap but before {reinitializeV3} runs.
    function _simulateNonEnumerableProxy() internal {
        _clearEnumerableRoleMembers(DEFAULT_ADMIN_ROLE, _members(admin));
        _clearEnumerableRoleMembers(PAUSER_ROLE, _members(admin));
        _clearEnumerableRoleMembers(MERCHANT_ROLE, _members(merchant));
    }

    function _members(address account) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = account;
    }

    function _members(address first, address second) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = first;
        list[1] = second;
    }

    function _noMembers() internal pure returns (address[] memory) {
        return new address[](0);
    }

    /// @dev Runs the migration with the holder lists the fixture's proxy would produce when
    ///      reconstructed from its `RoleGranted`/`RoleRevoked` event history.
    function _reinitializeV3AsAdmin() internal {
        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(merchant), _members(admin));
    }

    function test_initialize_populatesEnumerableMembership() public view {
        // Fresh deployments need no migration at all: `initialize` and `grantRole` both route
        // through the enumerable `_grantRole` override.
        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "admin not enumerated");
        assertEq(token.getRoleMemberCount(PAUSER_ROLE), 1, "pauser not enumerated");
        assertEq(token.getRoleMemberCount(MERCHANT_ROLE), 1, "merchant not enumerated");
        assertEq(token.getRoleMember(DEFAULT_ADMIN_ROLE, 0), admin, "wrong admin enumerated");
        assertEq(token.getRoleMember(MERCHANT_ROLE, 0), merchant, "wrong merchant enumerated");
    }

    // ── reinitializeV2: 1.3.0 pauser backfill (pre-enumerable proxies) ──────────

    function test_reinitializeV2_backfillsPausers() public {
        address pauserA = address(0xF00D1);
        address pauserB = address(0xF00D2);

        assertFalse(token.hasRole(PAUSER_ROLE, pauserA), "precondition: pauser A must not hold role");
        assertFalse(token.hasRole(PAUSER_ROLE, pauserB), "precondition: pauser B must not hold role");

        address[] memory pausers = new address[](4);
        pausers[0] = pauserA;
        pausers[1] = pauserB;
        pausers[2] = pauserA; // duplicate — must be tolerated
        pausers[3] = address(0); // zero-address — must be skipped

        vm.prank(admin);
        token.reinitializeV2(pausers);

        assertTrue(token.hasRole(PAUSER_ROLE, pauserA), "pauser A not granted");
        assertTrue(token.hasRole(PAUSER_ROLE, pauserB), "pauser B not granted");
        assertFalse(token.hasRole(PAUSER_ROLE, address(0)), "zero address must never be granted");

        // PAUSER_ROLE must remain administered by DEFAULT_ADMIN_ROLE so grants/revokes
        // stay under the admin key.
        assertEq(token.getRoleAdmin(PAUSER_ROLE), DEFAULT_ADMIN_ROLE, "PAUSER_ROLE admin must be DEFAULT_ADMIN_ROLE");

        // A back-filled pauser can pause immediately.
        vm.prank(pauserA);
        token.pause();
        assertTrue(token.paused(), "back-filled pauser unable to pause");
    }

    function test_reinitializeV2_revertsOnSecondCall() public {
        address[] memory pausers = new address[](0);

        vm.prank(admin);
        token.reinitializeV2(pausers);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(admin);
        token.reinitializeV2(pausers);
    }

    function test_reinitializeV2_revertsWhenNotAdmin() public {
        address[] memory pausers = new address[](0);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(user);
        token.reinitializeV2(pausers);
    }

    /// @dev A proxy that already ran the 1.3.0 {reinitializeV2} is at initializable version 2,
    ///      so the enumerable backfill must still be reachable afterwards. This is exactly the
    ///      path that a colliding `reinitializer(2)` would have made impossible.
    function test_reinitializeV3_runsAfterReinitializeV2() public {
        address[] memory pausers = new address[](1);
        pausers[0] = admin;

        vm.prank(admin);
        token.reinitializeV2(pausers);

        _reinitializeV3AsAdmin();

        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "admin membership not seeded after V2");
        assertEq(token.getRoleMember(DEFAULT_ADMIN_ROLE, 0), admin, "wrong admin enumerated");
    }

    function test_reinitializeV3_backfillsRoleMembers() public {
        _simulateNonEnumerableProxy();

        // One event per role, in the order the migration seeds them: the two operational roles
        // inside the re-entry loop, then the admin role once its exit assertion has held.
        vm.expectEmit(true, false, false, true, address(token));
        emit IAssetCX.RoleMembershipBackfilled(MERCHANT_ROLE, 1);
        vm.expectEmit(true, false, false, true, address(token));
        emit IAssetCX.RoleMembershipBackfilled(PAUSER_ROLE, 1);
        vm.expectEmit(true, false, false, true, address(token));
        emit IAssetCX.RoleMembershipBackfilled(DEFAULT_ADMIN_ROLE, 1);

        _reinitializeV3AsAdmin();

        // Neither stand-in may outlive the call that created it.
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, TEMP_ADMIN_A), "temp admin A survived the migration");
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, TEMP_ADMIN_B), "temp admin B survived the migration");

        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "admin not back-filled");
        assertEq(token.getRoleMemberCount(PAUSER_ROLE), 1, "pauser not back-filled");
        assertEq(token.getRoleMemberCount(MERCHANT_ROLE), 1, "merchant not back-filled");

        assertEq(token.getRoleMembers(DEFAULT_ADMIN_ROLE)[0], admin, "wrong admin enumerated");
        assertEq(token.getRoleMembers(MERCHANT_ROLE)[0], merchant, "wrong merchant enumerated");

        // Authorization is unchanged — the migration only repaired bookkeeping.
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin lost DEFAULT_ADMIN_ROLE");
        assertTrue(token.hasRole(MERCHANT_ROLE, merchant), "merchant lost MERCHANT_ROLE");

        // And the merchant hot path still works, so nothing was left half-revoked.
        vm.prank(merchant);
        token.mint(1000e18);
        assertEq(token.balanceOf(merchant), 1000e18, "merchant mint path broken");
    }

    function test_reinitializeV3_backfillsMultipleMembersPerRole() public {
        // The realistic shape: a role with several holders, all granted before the proxy became
        // enumerable.
        address secondMerchant = address(0xB0B2);
        address thirdMerchant = address(0xB0B3);

        vm.startPrank(admin);
        token.grantRole(MERCHANT_ROLE, secondMerchant);
        token.grantRole(MERCHANT_ROLE, thirdMerchant);
        vm.stopPrank();

        address[] memory merchants = new address[](3);
        merchants[0] = merchant;
        merchants[1] = secondMerchant;
        merchants[2] = thirdMerchant;

        _clearEnumerableRoleMembers(DEFAULT_ADMIN_ROLE, _members(admin));
        _clearEnumerableRoleMembers(PAUSER_ROLE, _members(admin));
        _clearEnumerableRoleMembers(MERCHANT_ROLE, merchants);

        vm.expectEmit(true, false, false, true, address(token));
        emit IAssetCX.RoleMembershipBackfilled(MERCHANT_ROLE, 3);

        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, merchants, _members(admin));

        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "admin not back-filled");
        assertEq(token.getRoleMemberCount(MERCHANT_ROLE), 3, "all merchants not back-filled");

        address[] memory enumeratedMerchants = token.getRoleMembers(MERCHANT_ROLE);
        assertEq(enumeratedMerchants[0], merchant, "merchant 1 missing");
        assertEq(enumeratedMerchants[1], secondMerchant, "merchant 2 missing");
        assertEq(enumeratedMerchants[2], thirdMerchant, "merchant 3 missing");
    }

    function test_reinitializeV3_isUnaffectedByLastAdminGuard() public {
        // The last-admin guard in `_revokeRole` is unconditional, so the migration satisfies it
        // with two stand-in admins rather than being exempted from it. Same storage state, two
        // outcomes: the operational path fails closed while the backfill still succeeds.
        _simulateNonEnumerableProxy();

        vm.expectRevert(IAssetCX.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        _reinitializeV3AsAdmin();

        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "sole admin not re-entered");
        assertEq(token.getRoleMember(DEFAULT_ADMIN_ROLE, 0), admin, "enumerated admin is not the original");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "sole admin lost the role");
    }

    function test_reinitializeV3_leavesLastAdminGuardIntact() public {
        // The migration must not loosen the guard on its way through: once it has run, the sole
        // admin is still protected on the operational path.
        _simulateNonEnumerableProxy();
        _reinitializeV3AsAdmin();

        vm.expectRevert(IAssetCX.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        vm.expectRevert(IAssetCX.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin must survive both attempts");
    }

    function test_reinitializeV3_revertsOnZeroTempAdmin() public {
        _simulateNonEnumerableProxy();

        vm.expectRevert(IAssetCX.ZeroAddress.selector);
        vm.prank(admin);
        token.reinitializeV3(address(0), TEMP_ADMIN_B, _members(merchant), _members(admin));

        vm.expectRevert(IAssetCX.ZeroAddress.selector);
        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, address(0), _members(merchant), _members(admin));
    }

    function test_reinitializeV3_revertsOnDegenerateTempAdmins() public {
        // A stand-in that already holds the role, the caller naming itself, or a repeated stand-in
        // is rejected up front, before any grant or revoke runs.
        address secondAdmin = address(0xA11CE2);
        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, secondAdmin);
        _simulateNonEnumerableProxy();
        _clearEnumerableRoleMembers(DEFAULT_ADMIN_ROLE, _members(secondAdmin));

        address[] memory merchants = _members(merchant);
        address[] memory pausers = _members(admin);

        vm.expectRevert(abi.encodeWithSelector(IAssetCX.InvalidTempAdmin.selector, TEMP_ADMIN_A));
        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_A, merchants, pausers);

        vm.expectRevert(abi.encodeWithSelector(IAssetCX.InvalidTempAdmin.selector, admin));
        vm.prank(admin);
        token.reinitializeV3(admin, TEMP_ADMIN_B, merchants, pausers);

        vm.expectRevert(abi.encodeWithSelector(IAssetCX.InvalidTempAdmin.selector, admin));
        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, admin, merchants, pausers);

        vm.expectRevert(abi.encodeWithSelector(IAssetCX.InvalidTempAdmin.selector, secondAdmin));
        vm.prank(admin);
        token.reinitializeV3(secondAdmin, TEMP_ADMIN_B, merchants, pausers);

        vm.expectRevert(abi.encodeWithSelector(IAssetCX.InvalidTempAdmin.selector, secondAdmin));
        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, secondAdmin, merchants, pausers);

        // A rejected attempt must leave the migration still runnable.
        _reinitializeV3AsAdmin();
        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "admin not back-filled");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, secondAdmin), "co-admin must keep its role");
    }

    function test_reinitializeV3_cannotRevokeEnumeratedCoAdmin() public {
        // Upgrade without the bundled call, then grant a co-admin through the enumerable
        // implementation: the co-admin is enumerated while the original admin is not. Passing the
        // co-admin as a stand-in used to make its grant a no-op and its revoke real, letting the
        // migration pass its exit assertion with the co-admin removed.
        _simulateNonEnumerableProxy();
        address coAdmin = address(0xA11CE2);
        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, coAdmin);
        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "co-admin should be enumerated");

        vm.expectRevert(abi.encodeWithSelector(IAssetCX.InvalidTempAdmin.selector, coAdmin));
        vm.prank(admin);
        token.reinitializeV3(coAdmin, TEMP_ADMIN_B, _members(merchant), _members(admin));

        vm.expectRevert(abi.encodeWithSelector(IAssetCX.InvalidTempAdmin.selector, coAdmin));
        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, coAdmin, _members(merchant), _members(admin));

        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, coAdmin), "co-admin must keep its role");
    }

    function test_reinitializeV3_cannotDetectOmittedCoAdmin() public {
        // Documents the residual limitation: the caller is the only admin the migration enumerates,
        // so a co-admin keeps its role while staying unenumerated and the exit assertion cannot see
        // the difference. `reinitializer(2)` is one-shot, so there is no second chance to repair it.
        address secondAdmin = address(0xA11CE2);
        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, secondAdmin);
        _simulateNonEnumerableProxy();
        _clearEnumerableRoleMembers(DEFAULT_ADMIN_ROLE, _members(secondAdmin));

        _reinitializeV3AsAdmin();

        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "only the caller should be enumerated");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, secondAdmin), "omitted admin must keep its role");
    }

    function test_reinitializeV3_toleratesDuplicateEntries() public {
        _simulateNonEnumerableProxy();

        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(merchant, merchant), _members(admin));

        assertEq(token.getRoleMemberCount(MERCHANT_ROLE), 1, "duplicate entry double-counted");
    }

    function test_reinitializeV3_allowsEmptyListForUnusedRole() public {
        _simulateNonEnumerableProxy();

        // Pausers deliberately omitted: the role keeps its holder, it just stays unenumerated.
        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(merchant), _noMembers());

        assertEq(token.getRoleMemberCount(PAUSER_ROLE), 0, "omitted role must stay unenumerated");
        assertTrue(token.hasRole(PAUSER_ROLE, admin), "omitted role must keep its holder");
    }

    function test_reinitializeV3_revertsOnNonHolder() public {
        _simulateNonEnumerableProxy();

        // A single typo'd address must abort the whole upgrade: re-entering a non-holder would be
        // a real privilege grant rather than a bookkeeping repair.
        address stranger = address(0xBAD);

        vm.expectRevert(abi.encodeWithSelector(IAssetCX.NotACurrentRoleHolder.selector, MERCHANT_ROLE, stranger));
        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(merchant, stranger), _members(admin));

        assertFalse(token.hasRole(MERCHANT_ROLE, stranger), "typo must never grant a live role");
    }

    function test_reinitializeV3_revertsOnZeroAddressEntry() public {
        _simulateNonEnumerableProxy();

        vm.expectRevert(abi.encodeWithSelector(IAssetCX.NotACurrentRoleHolder.selector, PAUSER_ROLE, address(0)));
        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(merchant), _members(address(0)));
    }

    function test_reinitializeV3_revertsWhenNotAdmin() public {
        address stranger = address(0xDEAD);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        vm.prank(stranger);
        token.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(merchant), _members(admin));

        // The failed call must not bump the initializable version — admin can still migrate.
        _reinitializeV3AsAdmin();
    }

    function test_reinitializeV3_revertsOnSecondCall() public {
        _reinitializeV3AsAdmin();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(admin);
        token.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(merchant), _members(admin));
    }

    function test_upgradeToAndCall_runsReinitializeV3Atomically() public {
        // ── Arrange: shape the proxy like the live non-enumerable deployment.
        _simulateNonEnumerableProxy();

        // ── Act: the implementation swap and the whole backfill land in one transaction, so the
        // admin is never unprivileged and the stand-in admins are never reachable from outside.
        AssetCX newImpl = new AssetCX();
        bytes memory migrateCalldata =
            abi.encodeCall(AssetCX.reinitializeV3, (TEMP_ADMIN_A, TEMP_ADMIN_B, _members(merchant), _members(admin)));

        vm.expectEmit(true, true, false, true, address(token));
        emit IAssetCX.AssetCxUpgradeAuthorized(address(newImpl), admin);
        vm.expectEmit(true, false, false, false, address(token));
        emit IERC1967.Upgraded(address(newImpl));
        vm.expectEmit(true, false, false, true, address(token));
        emit IAssetCX.RoleMembershipBackfilled(DEFAULT_ADMIN_ROLE, 1);
        vm.expectEmit(false, false, false, true, address(token));
        emit Initializable.Initialized(3);

        vm.prank(admin);
        token.upgradeToAndCall(address(newImpl), migrateCalldata);

        // ── Assert: implementation swapped, membership seeded, admin intact.
        address implAfter = address(uint160(uint256(vm.load(address(token), ERC1967Utils.IMPLEMENTATION_SLOT))));
        assertEq(implAfter, address(newImpl), "implementation slot not switched");

        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "admin not back-filled");
        assertEq(token.getRoleMemberCount(MERCHANT_ROLE), 1, "merchant not back-filled");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin lost DEFAULT_ADMIN_ROLE");

        // The admin can still authorize a further upgrade — i.e. the proxy was never orphaned.
        AssetCX followUpImpl = new AssetCX();
        vm.prank(admin);
        token.upgradeToAndCall(address(followUpImpl), "");
    }

    /*//////////////////////////////////////////////////////////////
                        LAST-ADMIN GUARD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_revokeRole_failsClosedWhenMembershipUnknown() public {
        // The dangerous case. On a proxy upgraded from a non-enumerable implementation the
        // tracked count is 0 while `hasRole` still reports the admin, so a naive `count == 1`
        // check would wave through removal of the genuinely last admin and brick upgrades.
        _simulateNonEnumerableProxy();

        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0, "precondition: membership must be unknown");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "precondition: admin must still hold the role");

        vm.expectRevert(IAssetCX.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin must survive a fail-closed revoke");
    }

    function test_revokeRole_revertsOnLastAdmin() public {
        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "precondition: fixture has one admin");

        vm.expectRevert(IAssetCX.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function test_renounceRole_revertsOnLastAdmin() public {
        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "precondition: fixture has one admin");

        vm.expectRevert(IAssetCX.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function test_revokeRole_succeedsOnceASecondAdminExists() public {
        address secondAdmin = address(0xA2);

        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, secondAdmin);
        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 2, "second admin not enumerated");

        // Rotation is now safe in either direction: the outgoing admin can be removed by the
        // incoming one without ever passing through a zero-admin state.
        vm.prank(secondAdmin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "outgoing admin not removed");
        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "membership set not updated on revoke");
        assertEq(token.getRoleMember(DEFAULT_ADMIN_ROLE, 0), secondAdmin, "wrong surviving admin");
    }

    function test_revokeRole_leavesNonAdminRolesUnguarded() public {
        // The guard is scoped to `DEFAULT_ADMIN_ROLE`; operational roles can still be emptied.
        vm.prank(admin);
        token.revokeRole(MERCHANT_ROLE, merchant);

        assertFalse(token.hasRole(MERCHANT_ROLE, merchant), "merchant not revoked");
        assertEq(token.getRoleMemberCount(MERCHANT_ROLE), 0, "membership set not updated on revoke");
    }

    function test_renounceRole_leavesNonAdminRolesUnguarded() public {
        vm.prank(admin);
        token.renounceRole(PAUSER_ROLE, admin);

        assertFalse(token.hasRole(PAUSER_ROLE, admin), "pauser not renounced");
        assertEq(token.getRoleMemberCount(PAUSER_ROLE), 0, "membership set not updated on renounce");
    }

    function test_revokeRole_revertsWhenNotRoleAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(user);
        token.revokeRole(MERCHANT_ROLE, merchant);
    }
}
