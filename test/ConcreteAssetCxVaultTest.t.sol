// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {
    IConcreteFactory,
    ConcreteFactoryBaseSetup,
    VaultProxy,
    IConcreteAsyncVaultImpl,
    ConcreteAssetCxVaultImplBaseSetup
} from "./common/ConcreteAssetCxVaultImplBaseSetup.sol";
import {ConcreteAsyncVaultImpl} from "@concrete-xyz/earn-v2-core/src/implementation/ConcreteAsyncVaultImpl.sol";
import {IConcreteAsyncVaultImpl} from "@concrete-xyz/earn-v2-core/src/interface/IConcreteAsyncVaultImpl.sol";
import {
    AddStrategyWithDeallocationOrder
} from "@concrete-xyz/earn-v2-core/test/common/AddStrategyWithDeallocationOrder.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {ConcreteAssetCxVaultImplBaseSetup} from "./common/ConcreteAssetCxVaultImplBaseSetup.sol";
import {ConcreteAssetCxVaultImpl} from "../src/implementation/ConcreteAssetCxVault.sol";
import {AssetCxRolesLib} from "../src/lib/AssetCxRolesLib.sol";
import {ConcreteV2RolesLib} from "@concrete-xyz/earn-v2-core/src/lib/Roles.sol";

contract ConcreteAssetCxVaultTest is ConcreteAssetCxVaultImplBaseSetup, AddStrategyWithDeallocationOrder {
    bytes32 internal constant MERCHANT_ROLE = keccak256("MERCHANT_ROLE");

    address public merchant;
    address public user1;
    address public user2;
    address public user3;
    uint256 public totalAmount = 2000000e18;
    uint256 public initialDepositAmount = 1000000e18;
    uint256 public merchantInitialBalance = 5000000e18;

    function setUp() public override {
        super.setUp();

        merchant = makeAddr("merchant");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        vm.label(address(merchant), "merchant");
        vm.label(address(user1), "user1");
        vm.label(address(user2), "user2");
        vm.label(address(user3), "user3");

        // Fund accounts
        asset.mint(merchant, merchantInitialBalance);
        asset.mint(user1, totalAmount);
        asset.mint(user2, totalAmount);
        asset.mint(user3, totalAmount);

        vm.prank(vaultManager);
        concreteAssetCxVault.grantRole(AssetCxRolesLib.MERCHANT_ROLE, merchant);

        // Setup approvals
        vm.startPrank(merchant);
        asset.approve(address(concreteAssetCxVault), type(uint256).max);
        concreteAssetCxVault.deposit(initialDepositAmount, user1);
        concreteAssetCxVault.deposit(initialDepositAmount, user2);
        concreteAssetCxVault.deposit(initialDepositAmount, user3);
        vm.stopPrank();
    }

    // ============ Asset Ct Vault Specific Tests ============

    function test_initialize_setsMerchantRoles() public view {
        assertEq(concreteAssetCxVault.getRoleAdmin(AssetCxRolesLib.MERCHANT_ROLE), ConcreteV2RolesLib.ROLE_ADMIN);
        assertTrue(concreteAssetCxVault.hasRole(ConcreteV2RolesLib.ROLE_ADMIN, vaultManager));
    }

    function test_deposit_revertsWhenCallerIsNotMerchant() public {
        uint256 depositAmount = 100e18;

        vm.startPrank(user1);
        asset.approve(address(concreteAssetCxVault), depositAmount);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, MERCHANT_ROLE)
        );
        concreteAssetCxVault.deposit(depositAmount, user1);
        vm.stopPrank();
    }

    function test_deposit_successWhenCallerIsMerchant() public {
        uint256 depositAmount = 100e18;
        uint256 userBalanceBefore = concreteAssetCxVault.balanceOf(user1);

        vm.prank(merchant);
        uint256 mintedShares = concreteAssetCxVault.deposit(depositAmount, user1);

        assertEq(mintedShares, depositAmount);
        assertEq(concreteAssetCxVault.balanceOf(user1), userBalanceBefore + depositAmount);
    }

    function test_mint_revertsWhenCallerIsNotMerchant() public {
        uint256 sharesToMint = 100e18;

        vm.startPrank(user2);
        asset.approve(address(concreteAssetCxVault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user2, MERCHANT_ROLE)
        );
        concreteAssetCxVault.mint(sharesToMint, user2);
        vm.stopPrank();
    }

    function test_mint_successWhenCallerIsMerchant() public {
        uint256 sharesToMint = 250e18;
        uint256 userBalanceBefore = concreteAssetCxVault.balanceOf(user3);

        vm.startPrank(merchant);
        uint256 assetsSpent = concreteAssetCxVault.mint(sharesToMint, user3);
        vm.stopPrank();

        assertEq(assetsSpent, sharesToMint);
        assertEq(concreteAssetCxVault.balanceOf(user3), userBalanceBefore + sharesToMint);
    }

    function test_cancelRequest_returnsSharesAndClearsRequest() public {
        uint256 withdrawAmount = 100e18;
        uint256 initialUserShares = concreteAssetCxVault.balanceOf(user1);
        uint256 currentEpoch = concreteAssetCxVault.latestEpochID();

        vm.prank(user1);
        uint256 sharesBurned = concreteAssetCxVault.withdraw(withdrawAmount, user1, user1);
        assertEq(sharesBurned, withdrawAmount);
        assertEq(concreteAssetCxVault.balanceOf(user1), initialUserShares - withdrawAmount);
        assertEq(concreteAssetCxVault.getUserEpochRequest(user1, currentEpoch), withdrawAmount);

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.RequestCancelled(user1, withdrawAmount, currentEpoch);

        vm.prank(user1);
        concreteAssetCxVault.cancelRequest(currentEpoch);

        assertEq(concreteAssetCxVault.balanceOf(user1), initialUserShares);
        assertEq(concreteAssetCxVault.getUserEpochRequest(user1, currentEpoch), 0);
        assertEq(concreteAssetCxVault.totalRequestedSharesPerEpoch(currentEpoch), 0);
    }

    function test_claimWithdrawalSelf_notImplemented() public {
        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 1;

        vm.expectRevert(ConcreteAssetCxVaultImpl.NotImplemented.selector);
        concreteAssetCxVault.claimWithdrawal(epochIds);
    }

    function test_claimUsersBatch_notImplemented() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256 epochId = 1;

        vm.expectRevert(ConcreteAssetCxVaultImpl.NotImplemented.selector);
        concreteAssetCxVault.claimUsersBatch(users, epochId);
    }

    function test_toggleQueueActive_notImplemented() public {
        vm.expectRevert(ConcreteAssetCxVaultImpl.NotImplemented.selector);
        concreteAssetCxVault.toggleQueueActive();
    }

    function test_claimWithdrawal_revertsWhenCallerIsNotMerchant() public {
        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 1;

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, AssetCxRolesLib.MERCHANT_ROLE
            )
        );
        concreteAssetCxVault.claimWithdrawal(user1, epochIds);
        vm.stopPrank();
    }

    function test_claimWithdrawal_transfersAssetsToMerchant() public {
        uint256 withdrawAmount = 100_000e18;
        uint256 currentEpoch = concreteAssetCxVault.latestEpochID();

        vm.prank(user1);
        concreteAssetCxVault.withdraw(withdrawAmount, user1, user1);

        vm.startPrank(withdrawalManager);
        concreteAssetCxVault.closeEpoch();
        concreteAssetCxVault.processEpoch();
        vm.stopPrank();

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = currentEpoch;

        uint256 initialMerchantBalance = asset.balanceOf(merchant);
        uint256 initialRedeemableAssets = concreteAssetCxVault.pastEpochsUnclaimedAssets();

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.RequestClaimed(user1, withdrawAmount, epochIds);

        vm.prank(merchant);
        concreteAssetCxVault.claimWithdrawal(user1, epochIds);

        uint256 finalMerchantBalance = asset.balanceOf(merchant);
        assertEq(finalMerchantBalance - initialMerchantBalance, withdrawAmount);
        assertLt(concreteAssetCxVault.pastEpochsUnclaimedAssets(), initialRedeemableAssets);
        assertEq(concreteAssetCxVault.getUserEpochRequest(user1, currentEpoch), 0);
    }
}
