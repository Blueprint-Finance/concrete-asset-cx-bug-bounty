// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ConcreteAssetCxVaultImplBaseSetup} from "../common/ConcreteAssetCxVaultImplBaseSetup.sol";
import {Hooks} from "@concrete-xyz/earn-v2-core/src/interface/IHook.sol";
import {HooksLibV2} from "@concrete-xyz/earn-v2-core/src/lib/Hooks.sol";
import {AssetCxRolesLib} from "../../src/lib/AssetCxRolesLib.sol";
import {WhitelistHook} from "../../src/hooks/WhitelistHook.sol";
import {TransferAllowlistHook} from "../../src/hooks/TransferAllowlistHook.sol";
import {BaseHook} from "@concrete-xyz/earn-v2-core/src/periphery/hooks/BaseHook.sol";
import {HookContainer} from "@concrete-xyz/earn-v2-core/src/periphery/hooks/HookContainer.sol";
import {PeripheryRolesLib} from "@concrete-xyz/earn-v2-core/src/periphery/lib/PeripheryRolesLib.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title TransferAllowlistHookTest
 * @notice Exercises the TransferAllowlistHook alongside the WhitelistHook, both wired into a
 *         single HookContainer that is registered as the vault's hook target.
 */
contract TransferAllowlistHookTest is ConcreteAssetCxVaultImplBaseSetup {
    HookContainer public container;
    WhitelistHook public whitelistHook;
    TransferAllowlistHook public transferHook;

    address public merchant;
    address public alice;
    address public bob;
    address public charlie;
    address public hookAdmin;
    address public whitelistManager;
    address public containerAdmin;
    address public transferHookOwner;

    uint256 internal constant INITIAL_DEPOSIT = 1_000e18;

    function setUp() public override {
        ConcreteAssetCxVaultImplBaseSetup.setUp();

        merchant = makeAddr("merchant");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        hookAdmin = makeAddr("hookAdmin");
        whitelistManager = makeAddr("whitelistManager");
        containerAdmin = makeAddr("containerAdmin");
        transferHookOwner = makeAddr("transferHookOwner");

        whitelistHook = _deployWhitelistHook(hookAdmin);
        vm.prank(hookAdmin);
        whitelistHook.grantRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, whitelistManager);

        transferHook = _deployTransferHook(transferHookOwner);

        container = _deployContainer(containerAdmin);

        vm.prank(containerAdmin);
        container.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, containerAdmin);

        vm.startPrank(containerAdmin);
        container.addHook(address(whitelistHook));
        container.addHook(address(transferHook));
        vm.stopPrank();

        // Register the container on the vault for deposit/mint (whitelist) and transfer (allowlist).
        uint96 flags = uint96(1 << HooksLibV2.PRE_DEPOSIT) | uint96(1 << HooksLibV2.PRE_MINT)
            | uint96(1 << HooksLibV2.PRE_TRANSFER) | uint96(1 << HooksLibV2.POST_TRANSFER);
        Hooks memory hooks = Hooks({target: address(container), flags: flags});
        vm.prank(hookManager);
        concreteAssetCxVault.setHooks(hooks);

        // Seed the merchant so it can deposit on behalf of users.
        asset.mint(merchant, 5_000_000e18);
        vm.prank(vaultManager);
        concreteAssetCxVault.grantRole(AssetCxRolesLib.MERCHANT_ROLE, merchant);

        // Whitelist alice & bob, then give alice some shares to move around.
        vm.startPrank(whitelistManager);
        whitelistHook.setUserWhitelisted(alice);
        whitelistHook.setUserWhitelisted(bob);
        vm.stopPrank();

        vm.startPrank(merchant);
        asset.approve(address(concreteAssetCxVault), type(uint256).max);
        concreteAssetCxVault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();
    }

    function _cloneArgs() internal view returns (bytes memory) {
        return abi.encodePacked(address(factory), address(concreteAssetCxVault));
    }

    function _deployWhitelistHook(address admin_) internal returns (WhitelistHook h) {
        WhitelistHook impl = new WhitelistHook();
        h = WhitelistHook(payable(ClonesWithImmutableArgs.clone(address(impl), _cloneArgs())));
        vm.prank(address(factory));
        h.initialize(admin_, new address[](0));
    }

    /// @dev Deploys a locked implementation, clones it (`[factory][vault]`) and initializes from the factory.
    function _deployTransferHook(address owner_) internal returns (TransferAllowlistHook h) {
        TransferAllowlistHook impl = new TransferAllowlistHook();
        h = TransferAllowlistHook(payable(ClonesWithImmutableArgs.clone(address(impl), _cloneArgs())));
        vm.prank(address(factory));
        h.initialize(owner_);
    }

    /// @dev Deploys a locked implementation, clones it (`[factory][vault]`) and initializes from the factory.
    function _deployContainer(address admin_) internal returns (HookContainer c) {
        HookContainer impl = new HookContainer();
        c = HookContainer(payable(ClonesWithImmutableArgs.clone(address(impl), _cloneArgs())));
        vm.prank(address(factory));
        c.initialize(admin_);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setup / wiring
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setup_bothHooksRegistered() public view {
        assertEq(container.getHooksCount(), 2);
        assertTrue(container.isHookRegistered(address(whitelistHook)));
        assertTrue(container.isHookRegistered(address(transferHook)));
    }

    function test_setup_vaultsMatch() public view {
        assertEq(transferHook.VAULT(), address(concreteAssetCxVault));
        assertEq(whitelistHook.VAULT(), address(concreteAssetCxVault));
        assertEq(container.VAULT(), address(concreteAssetCxVault));
        assertEq(transferHook.FACTORY(), address(factory));
        assertEq(whitelistHook.FACTORY(), address(factory));
        assertEq(container.FACTORY(), address(factory));
    }

    function test_id() public view {
        assertEq(transferHook.ID(), uint64(500810700));
        assertEq(transferHook.FLAVOUR(), 8);
    }

    function test_initialize_revertsWhenCalledTwice() public {
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        transferHook.initialize(transferHookOwner);
    }

    function test_initialize_revertsWhenCallerIsNotFactory() public {
        TransferAllowlistHook impl = new TransferAllowlistHook();
        TransferAllowlistHook clone =
            TransferAllowlistHook(payable(ClonesWithImmutableArgs.clone(address(impl), _cloneArgs())));

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BaseHook.NotFactory.selector));
        clone.initialize(attacker);
    }

    function test_initialize_onlyEncodedFactoryCanInitialize() public {
        address customFactory = makeAddr("customFactory");
        TransferAllowlistHook impl = new TransferAllowlistHook();
        TransferAllowlistHook clone = TransferAllowlistHook(
            payable(ClonesWithImmutableArgs.clone(
                    address(impl), abi.encodePacked(customFactory, address(concreteAssetCxVault))
                ))
        );

        assertEq(clone.FACTORY(), customFactory);

        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(BaseHook.NotFactory.selector));
        clone.initialize(transferHookOwner);

        vm.prank(customFactory);
        clone.initialize(transferHookOwner);

        assertEq(clone.owner(), transferHookOwner);
    }

    function test_owner_isSet() public view {
        assertEq(transferHook.owner(), transferHookOwner);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // setAllowed
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setAllowed_succeedsForOwner() public {
        vm.prank(transferHookOwner);
        transferHook.setAllowed(alice, bob, true);
        assertTrue(transferHook.allowed(alice, bob));
    }

    function test_setAllowed_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        transferHook.setAllowed(alice, bob, true);
    }

    function test_setAllowed_revertsWhenFromIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(BaseHook.ZeroAddress.selector));
        vm.prank(transferHookOwner);
        transferHook.setAllowed(address(0), bob, true);
    }

    function test_setAllowed_revertsWhenToIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(BaseHook.ZeroAddress.selector));
        vm.prank(transferHookOwner);
        transferHook.setAllowed(alice, address(0), true);
    }

    function test_setAllowed_canDisallow() public {
        vm.startPrank(transferHookOwner);
        transferHook.setAllowed(alice, bob, true);
        assertTrue(transferHook.allowed(alice, bob));
        transferHook.setAllowed(alice, bob, false);
        assertFalse(transferHook.allowed(alice, bob));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // preTransfer via the vault + container (integration)
    // ─────────────────────────────────────────────────────────────────────────────

    function test_transfer_revertsWhenNotAllowed() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TransferAllowlistHook.TransferNotAllowed.selector, alice, bob));
        concreteAssetCxVault.transfer(bob, 100e18);
    }

    function test_transfer_succeedsWhenAllowed() public {
        vm.prank(transferHookOwner);
        transferHook.setAllowed(alice, bob, true);

        vm.prank(alice);
        concreteAssetCxVault.transfer(bob, 100e18);

        assertEq(concreteAssetCxVault.balanceOf(alice), INITIAL_DEPOSIT - 100e18);
        assertEq(concreteAssetCxVault.balanceOf(bob), 100e18);
    }

    function test_transfer_toVaultRevertsWithoutAllowance() public {
        // Direct ERC20 transfers to the vault are not exempt; only vault-internal
        // flows (which skip the hook) bypass the allowlist.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                TransferAllowlistHook.TransferNotAllowed.selector, alice, address(concreteAssetCxVault)
            )
        );
        concreteAssetCxVault.transfer(address(concreteAssetCxVault), 100e18);
    }

    function test_transfer_directionalAllowanceIsOneWay() public {
        // Allow alice -> bob, but bob -> alice must still be blocked.
        vm.prank(transferHookOwner);
        transferHook.setAllowed(alice, bob, true);

        vm.prank(alice);
        concreteAssetCxVault.transfer(bob, 100e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TransferAllowlistHook.TransferNotAllowed.selector, bob, alice));
        concreteAssetCxVault.transfer(alice, 50e18);
    }

    function test_transfer_revertsAfterAllowanceRevoked() public {
        vm.prank(transferHookOwner);
        transferHook.setAllowed(alice, bob, true);

        vm.prank(alice);
        concreteAssetCxVault.transfer(bob, 100e18);

        vm.prank(transferHookOwner);
        transferHook.setAllowed(alice, bob, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TransferAllowlistHook.TransferNotAllowed.selector, alice, bob));
        concreteAssetCxVault.transfer(bob, 100e18);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Whitelist hook still enforced through the same container
    // ─────────────────────────────────────────────────────────────────────────────

    function test_deposit_revertsWhenReceiverNotWhitelisted() public {
        vm.startPrank(merchant);
        vm.expectRevert(abi.encodeWithSelector(WhitelistHook.UserNotWhitelisted.selector, charlie));
        concreteAssetCxVault.deposit(100e18, charlie);
        vm.stopPrank();
    }

    function test_deposit_succeedsWhenReceiverWhitelisted() public {
        vm.startPrank(merchant);
        uint256 minted = concreteAssetCxVault.deposit(150e18, bob);
        vm.stopPrank();

        assertEq(minted, 150e18);
        assertEq(concreteAssetCxVault.balanceOf(bob), 150e18);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Vault-internal flows bypass the hook (no allowances configured)
    // ─────────────────────────────────────────────────────────────────────────────

    function test_vaultFlow_depositWorksWithoutAllowance() public {
        // Mint path (`from == address(0)`) never reaches the transfer hook.
        vm.prank(merchant);
        uint256 minted = concreteAssetCxVault.deposit(200e18, alice);

        assertEq(minted, 200e18);
        assertEq(concreteAssetCxVault.balanceOf(alice), INITIAL_DEPOSIT + 200e18);
    }

    function test_vaultFlow_mintWorksWithoutAllowance() public {
        vm.prank(merchant);
        uint256 assetsSpent = concreteAssetCxVault.mint(200e18, alice);

        assertEq(assetsSpent, 200e18);
        assertEq(concreteAssetCxVault.balanceOf(alice), INITIAL_DEPOSIT + 200e18);
    }

    function test_vaultFlow_withdrawRequestWorksWithoutAllowance() public {
        // Queued withdrawals escrow shares to the vault via an internal transfer
        // that bypasses the hook, so no `allowed[alice][vault]` entry is needed.
        uint256 epochID = concreteAssetCxVault.latestEpochID();

        vm.prank(alice);
        uint256 sharesBurned = concreteAssetCxVault.withdraw(100e18, alice, alice);

        assertEq(sharesBurned, 100e18);
        assertEq(concreteAssetCxVault.balanceOf(alice), INITIAL_DEPOSIT - 100e18);
        assertEq(concreteAssetCxVault.getUserEpochRequest(alice, epochID), 100e18);
    }

    function test_vaultFlow_redeemRequestWorksWithoutAllowance() public {
        uint256 epochID = concreteAssetCxVault.latestEpochID();

        vm.prank(alice);
        concreteAssetCxVault.redeem(100e18, alice, alice);

        assertEq(concreteAssetCxVault.balanceOf(alice), INITIAL_DEPOSIT - 100e18);
        assertEq(concreteAssetCxVault.getUserEpochRequest(alice, epochID), 100e18);
    }

    function test_vaultFlow_cancelRequestWorksWithoutAllowance() public {
        // Cancelling returns escrowed shares vault -> user, again bypassing the hook.
        uint256 epochID = concreteAssetCxVault.latestEpochID();

        vm.startPrank(alice);
        concreteAssetCxVault.withdraw(100e18, alice, alice);
        concreteAssetCxVault.cancelRequest(epochID);
        vm.stopPrank();

        assertEq(concreteAssetCxVault.balanceOf(alice), INITIAL_DEPOSIT);
        assertEq(concreteAssetCxVault.getUserEpochRequest(alice, epochID), 0);
    }

    function test_vaultFlow_fullWithdrawalLifecycleWorksWithoutAllowance() public {
        uint256 withdrawAmount = 100e18;
        uint256 epochID = concreteAssetCxVault.latestEpochID();

        vm.prank(alice);
        concreteAssetCxVault.withdraw(withdrawAmount, alice, alice);

        vm.startPrank(withdrawalManager);
        concreteAssetCxVault.closeEpoch();
        concreteAssetCxVault.processEpoch();
        vm.stopPrank();

        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = epochID;

        uint256 merchantAssetsBefore = asset.balanceOf(merchant);
        vm.prank(merchant);
        concreteAssetCxVault.claimWithdrawal(alice, epochIDs);

        assertEq(asset.balanceOf(merchant) - merchantAssetsBefore, withdrawAmount);
        assertEq(concreteAssetCxVault.getUserEpochRequest(alice, epochID), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // preTransfer branch coverage (calling the hook directly)
    // ─────────────────────────────────────────────────────────────────────────────

    function test_preTransfer_revertsWhenFromIsVault() public {
        // The vault gets no special treatment; vault-internal flows never call this hook.
        vm.expectRevert(
            abi.encodeWithSelector(
                TransferAllowlistHook.TransferNotAllowed.selector, address(concreteAssetCxVault), charlie
            )
        );
        transferHook.preTransfer(address(0xBEEF), address(concreteAssetCxVault), charlie, 1e18);
    }

    function test_preTransfer_revertsWhenToIsVault() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                TransferAllowlistHook.TransferNotAllowed.selector, charlie, address(concreteAssetCxVault)
            )
        );
        transferHook.preTransfer(address(0xBEEF), charlie, address(concreteAssetCxVault), 1e18);
    }

    function test_preTransfer_revertsForArbitraryPair() public {
        vm.expectRevert(abi.encodeWithSelector(TransferAllowlistHook.TransferNotAllowed.selector, alice, charlie));
        transferHook.preTransfer(address(0xBEEF), alice, charlie, 1e18);
    }

    function test_preTransfer_allowsExplicitPair() public {
        vm.prank(transferHookOwner);
        transferHook.setAllowed(alice, charlie, true);

        transferHook.preTransfer(address(0xBEEF), alice, charlie, 1e18);
    }
}
