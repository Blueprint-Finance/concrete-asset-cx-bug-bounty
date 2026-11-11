// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {
    IConcreteFactory,
    ConcreteFactoryBaseSetup,
    VaultProxy,
    IConcreteAsyncVaultImpl,
    ConcreteAssetCxVaultImplBaseSetup
} from "../common/ConcreteAssetCxVaultImplBaseSetup.sol";
import {Hooks} from "@concrete-xyz/earn-v2-core/src/interface/IHook.sol";
import {HooksLibV2} from "@concrete-xyz/earn-v2-core/src/lib/Hooks.sol";
import {AssetCxRolesLib} from "../../src/lib/AssetCxRolesLib.sol";
import {WhitelistHook} from "../../src/hooks/WhitelistHook.sol";
import {BaseHook} from "@concrete-xyz/earn-v2-core/src/periphery/hooks/BaseHook.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";

contract WhitelistHookTest is ConcreteAssetCxVaultImplBaseSetup {
    WhitelistHook public hook;
    WhitelistHook public hookImpl;

    address public merchant;
    address public user;
    address public hookAdmin;
    address public whitelistManager;

    uint256 internal constant INITIAL_DEPOSIT = 1_000e18;

    function setUp() public override {
        ConcreteAssetCxVaultImplBaseSetup.setUp();

        merchant = makeAddr("merchant");
        user = makeAddr("user");
        hookAdmin = makeAddr("hookAdmin");
        whitelistManager = makeAddr("whitelistManager");

        hookImpl = new WhitelistHook();
        hook = WhitelistHook(
            payable(ClonesWithImmutableArgs.clone(
                    address(hookImpl), abi.encodePacked(address(factory), address(concreteAssetCxVault))
                ))
        );
        vm.prank(address(factory));
        hook.initialize(hookAdmin, new address[](0));

        // Grant WHITELIST_MANAGER_ROLE to whitelistManager
        vm.prank(hookAdmin);
        hook.grantRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, whitelistManager);

        uint96 flags = uint96(1 << HooksLibV2.PRE_DEPOSIT) | uint96(1 << HooksLibV2.PRE_MINT)
            | uint96(1 << HooksLibV2.PRE_WITHDRAW) | uint96(1 << HooksLibV2.PRE_REDEEM);
        Hooks memory hooks = Hooks({target: address(hook), flags: flags});

        vm.prank(hookManager);
        concreteAssetCxVault.setHooks(hooks);

        asset.mint(merchant, 5_000_000e18);

        vm.prank(vaultManager);
        concreteAssetCxVault.grantRole(AssetCxRolesLib.MERCHANT_ROLE, merchant);

        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user);

        vm.startPrank(merchant);
        asset.approve(address(concreteAssetCxVault), type(uint256).max);
        concreteAssetCxVault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        vm.prank(whitelistManager);
        hook.removeUserFromWhitelist(user);
    }

    function test_constructor_setsAdmin() public view {
        assertTrue(hook.hasRole(hook.DEFAULT_ADMIN_ROLE(), hookAdmin));
    }

    function test_initialize_revertsOnImplementation() public {
        // The BaseHook constructor calls _disableInitializers(), locking the implementation
        // so it can never be initialized directly — only clones can.
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        hookImpl.initialize(hookAdmin, new address[](0));
    }

    function test_initialize_revertsWhenAdminIsZero() public {
        WhitelistHook clone = WhitelistHook(
            payable(ClonesWithImmutableArgs.clone(
                    address(hookImpl), abi.encodePacked(address(factory), address(concreteAssetCxVault))
                ))
        );
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(BaseHook.ZeroAddress.selector));
        clone.initialize(address(0), new address[](0));
    }

    function test_initialize_revertsWhenCallerIsNotFactory() public {
        WhitelistHook clone = WhitelistHook(
            payable(ClonesWithImmutableArgs.clone(
                    address(hookImpl), abi.encodePacked(address(factory), address(concreteAssetCxVault))
                ))
        );

        // A mempool observer front-runs initialization of the uninitialized clone.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BaseHook.NotFactory.selector));
        clone.initialize(attacker, new address[](0));
    }

    function test_initialize_onlyEncodedFactoryCanInitialize() public {
        // Clone bound to a custom factory address (different from the setup factory).
        address customFactory = makeAddr("customFactory");
        WhitelistHook clone = WhitelistHook(
            payable(ClonesWithImmutableArgs.clone(
                    address(hookImpl), abi.encodePacked(customFactory, address(concreteAssetCxVault))
                ))
        );

        assertEq(clone.FACTORY(), customFactory);

        // Any caller other than the encoded factory (including the setup factory) reverts.
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(BaseHook.NotFactory.selector));
        clone.initialize(hookAdmin, new address[](0));

        // Only the encoded factory can initialize.
        vm.prank(customFactory);
        clone.initialize(hookAdmin, new address[](0));

        assertTrue(clone.hasRole(clone.DEFAULT_ADMIN_ROLE(), hookAdmin));
    }

    function test_setUserWhitelisted_succeedsForWhitelistManager() public {
        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user);

        assertTrue(hook.userWhitelisted(user));
    }

    function test_setUserWhitelisted_revertsForNonWhitelistManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, AssetCxRolesLib.WHITELIST_MANAGER_ROLE
            )
        );
        vm.prank(user);
        hook.setUserWhitelisted(user);
    }

    function test_setUserWhitelisted_revertsForAdmin() public {
        // Admin alone cannot call setUserWhitelisted without WHITELIST_MANAGER_ROLE
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                hookAdmin,
                AssetCxRolesLib.WHITELIST_MANAGER_ROLE
            )
        );
        vm.prank(hookAdmin);
        hook.setUserWhitelisted(user);
    }

    function test_removeUserFromWhitelist_succeedsForWhitelistManager() public {
        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user);

        vm.prank(whitelistManager);
        hook.removeUserFromWhitelist(user);

        assertFalse(hook.userWhitelisted(user));
    }

    function test_removeUserFromWhitelist_revertsForNonWhitelistManager() public {
        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, AssetCxRolesLib.WHITELIST_MANAGER_ROLE
            )
        );
        vm.prank(user);
        hook.removeUserFromWhitelist(user);
    }

    function test_grantWhitelistManagerRole_succeedsForAdmin() public {
        address newManager = makeAddr("newManager");

        vm.prank(hookAdmin);
        hook.grantRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, newManager);

        assertTrue(hook.hasRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, newManager));

        // New manager can now whitelist users
        vm.prank(newManager);
        hook.setUserWhitelisted(user);

        assertTrue(hook.userWhitelisted(user));
    }

    function test_revokeWhitelistManagerRole_succeedsForAdmin() public {
        vm.prank(hookAdmin);
        hook.revokeRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, whitelistManager);

        assertFalse(hook.hasRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, whitelistManager));

        // Revoked manager can no longer whitelist users
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                whitelistManager,
                AssetCxRolesLib.WHITELIST_MANAGER_ROLE
            )
        );
        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user);
    }

    function test_multipleManagersCanWhitelist() public {
        address secondManager = makeAddr("secondManager");

        vm.prank(hookAdmin);
        hook.grantRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, secondManager);

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user1);

        vm.prank(secondManager);
        hook.setUserWhitelisted(user2);

        assertTrue(hook.userWhitelisted(user1));
        assertTrue(hook.userWhitelisted(user2));
    }

    function test_deposit_revertsWhenReceiverNotWhitelisted() public {
        uint256 depositAmount = 100e18;

        vm.startPrank(merchant);
        vm.expectRevert(abi.encodeWithSelector(WhitelistHook.UserNotWhitelisted.selector, user));
        concreteAssetCxVault.deposit(depositAmount, user);
        vm.stopPrank();
    }

    function test_deposit_successWhenReceiverWhitelisted() public {
        uint256 depositAmount = 150e18;

        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user);

        uint256 userBalanceBefore = concreteAssetCxVault.balanceOf(user);

        vm.startPrank(merchant);
        uint256 mintedShares = concreteAssetCxVault.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(mintedShares, depositAmount);
        assertEq(concreteAssetCxVault.balanceOf(user), userBalanceBefore + depositAmount);
    }

    function test_mint_revertsWhenReceiverNotWhitelisted() public {
        uint256 sharesToMint = 75e18;

        vm.startPrank(merchant);
        vm.expectRevert(abi.encodeWithSelector(WhitelistHook.UserNotWhitelisted.selector, user));
        concreteAssetCxVault.mint(sharesToMint, user);
        vm.stopPrank();
    }

    function test_mint_successWhenReceiverWhitelisted() public {
        uint256 sharesToMint = 200e18;

        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user);

        uint256 userBalanceBefore = concreteAssetCxVault.balanceOf(user);

        vm.startPrank(merchant);
        uint256 assetsSpent = concreteAssetCxVault.mint(sharesToMint, user);
        vm.stopPrank();

        assertEq(assetsSpent, sharesToMint);
        assertEq(concreteAssetCxVault.balanceOf(user), userBalanceBefore + sharesToMint);
    }

    function test_withdraw_revertsWhenUserNotWhitelisted() public {
        uint256 withdrawAmount = 100e18;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(WhitelistHook.UserNotWhitelisted.selector, user));
        concreteAssetCxVault.withdraw(withdrawAmount, user, user);
    }

    function test_withdraw_successWhenUserWhitelisted() public {
        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user);

        uint256 withdrawAmount = 250e18;
        uint256 currentEpoch = concreteAssetCxVault.latestEpochID();

        vm.prank(user);
        uint256 sharesBurned = concreteAssetCxVault.withdraw(withdrawAmount, user, user);

        assertEq(sharesBurned, withdrawAmount);
        assertEq(concreteAssetCxVault.getUserEpochRequest(user, currentEpoch), withdrawAmount);
    }

    function test_redeem_revertsWhenUserNotWhitelisted() public {
        uint256 redeemAmount = 100e18;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(WhitelistHook.UserNotWhitelisted.selector, user));
        concreteAssetCxVault.redeem(redeemAmount, user, user);
    }

    function test_redeem_successWhenUserWhitelisted() public {
        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user);

        uint256 redeemAmount = 300e18;
        uint256 currentEpoch = concreteAssetCxVault.latestEpochID();

        vm.prank(user);
        uint256 assetsReturned = concreteAssetCxVault.redeem(redeemAmount, user, user);

        assertEq(assetsReturned, redeemAmount);
        assertEq(concreteAssetCxVault.getUserEpochRequest(user, currentEpoch), redeemAmount);
    }

    function test_removeWhitelistThenWithdrawReverts() public {
        vm.prank(whitelistManager);
        hook.setUserWhitelisted(user);

        vm.prank(whitelistManager);
        hook.removeUserFromWhitelist(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(WhitelistHook.UserNotWhitelisted.selector, user));
        concreteAssetCxVault.withdraw(50e18, user, user);
    }
}
