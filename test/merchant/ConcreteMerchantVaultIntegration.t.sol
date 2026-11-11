// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ConcreteFactoryBaseSetup} from "@concrete-xyz/earn-v2-core/test/common/ConcreteFactoryBaseSetup.t.sol";
import {ConcreteAssetCxVaultImpl} from "../../src/implementation/ConcreteAssetCxVault.sol";
import {IContractId} from "@concrete-xyz/earn-v2-core/src/interface/IContractId.sol";
import {ConcreteMerchant} from "../../src/merchant/ConcreteMerchant.sol";
import {IConcreteMerchant} from "../../src/interface/IConcreteMerchant.sol";
import {AssetCX} from "../../src/AssetCX.sol";
import {AssetCxRolesLib} from "../../src/lib/AssetCxRolesLib.sol";
import {AllocateModule} from "@concrete-xyz/earn-v2-core/src/module/AllocateModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "@concrete-xyz/earn-v2-core/src/lib/Roles.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {WhitelistHook} from "../../src/hooks/WhitelistHook.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {Hooks} from "@concrete-xyz/earn-v2-core/src/interface/IHook.sol";
import {HooksLibV2} from "@concrete-xyz/earn-v2-core/src/lib/Hooks.sol";

contract MockYieldToken is ERC20 {
    constructor() ERC20("Yield Token", "YLD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ConcreteMerchantVaultIntegrationTest is ConcreteFactoryBaseSetup {
    AssetCX private assetCX;
    ConcreteAssetCxVaultImpl private assetCxVault;
    ConcreteMerchant private merchant;
    AllocateModule private allocateModule;
    MockYieldToken private yieldToken;
    WhitelistHook private whitelistHook;
    WhitelistHook private hookImpl;

    address private admin;
    address private operator;
    address private user;
    address private vaultOwner;
    address private vaultManager;
    address private withdrawalManager;
    address private hookManager;
    uint64 private implId;

    function setUp() public override {
        ConcreteFactoryBaseSetup.setUp();

        admin = makeAddr("admin");
        operator = makeAddr("operator");
        user = makeAddr("user");
        vaultOwner = makeAddr("vaultOwner");
        vaultManager = makeAddr("vaultManager");
        withdrawalManager = makeAddr("withdrawalManager");
        hookManager = makeAddr("hookManager");

        // Deploy AssetCX implementation and proxy
        AssetCX assetCXImplementation = new AssetCX();
        ERC1967Proxy assetCXProxy = new ERC1967Proxy(
            address(assetCXImplementation), abi.encodeCall(AssetCX.initialize, ("Asset CX", "ACX", admin, address(0)))
        );
        assetCX = AssetCX(address(assetCXProxy));
        yieldToken = new MockYieldToken();

        ConcreteAssetCxVaultImpl implementation = new ConcreteAssetCxVaultImpl(address(factory));

        // get ID from the implementation
        implId = IContractId(implementation).ID();
        vm.prank(factoryOwner);
        factory.approveImplementation(address(implementation));

        allocateModule = new AllocateModule();

        assetCxVault = ConcreteAssetCxVaultImpl(
            factory.create(
                implId,
                vaultOwner,
                abi.encode(
                    address(allocateModule), address(assetCX), vaultManager, "Concrete Asset CX Vault", "CACXVault"
                )
            )
        );

        // Deploy WhitelistHook with hookManager as admin
        hookImpl = new WhitelistHook();
        whitelistHook = WhitelistHook(
            payable(ClonesWithImmutableArgs.clone(
                    address(hookImpl), abi.encodePacked(address(factory), address(assetCxVault))
                ))
        );
        vm.prank(address(factory));
        whitelistHook.initialize(hookManager, new address[](0));

        // Grant WHITELIST_MANAGER_ROLE to hookManager so it can manage whitelist
        vm.prank(hookManager);
        whitelistHook.grantRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, hookManager);

        // Set up hooks on the vault
        vm.prank(vaultManager);
        assetCxVault.grantRole(RolesLib.HOOK_MANAGER, hookManager);

        uint96 hookFlags = uint96(1 << HooksLibV2.PRE_DEPOSIT) | uint96(1 << HooksLibV2.PRE_MINT)
            | uint96(1 << HooksLibV2.PRE_WITHDRAW) | uint96(1 << HooksLibV2.PRE_REDEEM);

        vm.prank(hookManager);
        assetCxVault.setHooks(Hooks({target: address(whitelistHook), flags: hookFlags}));

        ConcreteMerchant merchantImpl = new ConcreteMerchant();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(merchantImpl),
            abi.encodeCall(ConcreteMerchant.initialize, (admin, assetCX, IERC4626(assetCxVault), address(0)))
        );
        merchant = ConcreteMerchant(address(proxy));

        vm.startPrank(admin);
        assetCX.grantRole(AssetCxRolesLib.MERCHANT_ROLE, address(merchant));
        merchant.grantRole(merchant.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        vm.prank(vaultManager);
        assetCxVault.grantRole(AssetCxRolesLib.MERCHANT_ROLE, address(merchant));

        vm.prank(vaultManager);
        assetCxVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, withdrawalManager);

        // Grant WHITELIST_MANAGER_ROLE to merchant so it can manage whitelist during emergencyMigrateUserAccount
        vm.prank(hookManager);
        whitelistHook.grantRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, address(merchant));
    }

    function test_mintAndDeposit_usesConcreteVault() public {
        bytes32 userId = keccak256("integration-user-1");
        uint256 amount = 1_000e18;
        bytes32 txHash = keccak256(bytes("integration-default-mint"));

        // Whitelist the user before deposit
        vm.prank(hookManager);
        whitelistHook.setUserWhitelisted(user);

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.MintAndDeposit(userId, amount, txHash);

        vm.prank(operator);
        uint256 shares = merchant.mintAndDeposit(userId, amount, txHash);

        assertEq(shares, amount);
        assertEq(assetCX.totalSupply(), amount);
        assertEq(assetCX.balanceOf(address(merchant)), 0);
        assertEq(assetCX.balanceOf(address(assetCxVault)), amount);
        assertEq(assetCxVault.balanceOf(user), amount);
        assertEq(merchant.totalMinted(userId), amount);
    }

    function test_mintAndDeposit_usesUserVaultOverride() public {
        bytes32 userId = keccak256("integration-user-override");
        uint256 amount = 900e18;
        bytes32 txHash = keccak256(bytes("integration-override-mint"));

        (ConcreteAssetCxVaultImpl overrideVault, WhitelistHook overrideHook) = _deployVaultWithHook();

        vm.startPrank(vaultManager);
        overrideVault.grantRole(AssetCxRolesLib.MERCHANT_ROLE, address(merchant));
        overrideVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, withdrawalManager);
        vm.stopPrank();

        // Whitelist the user on the override vault
        vm.prank(hookManager);
        overrideHook.setUserWhitelisted(user);

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(admin);
        merchant.setUserVault(userId, IERC4626(address(overrideVault)));

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.MintAndDeposit(userId, amount, txHash);

        vm.prank(operator);
        uint256 shares = merchant.mintAndDeposit(userId, amount, txHash);

        assertEq(shares, amount);
        assertEq(assetCX.totalSupply(), amount);
        assertEq(assetCX.balanceOf(address(merchant)), 0);
        assertEq(assetCxVault.balanceOf(user), 0);
        assertEq(overrideVault.balanceOf(user), amount);
        assertEq(address(merchant.userVault(userId)), address(overrideVault));
    }

    function test_claimVaultWithdrawal_processesThroughConcreteVault() public {
        bytes32 userId = keccak256("integration-user-claim");
        uint256 depositAmount = 1_200e18;
        uint256 withdrawAmount = 500e18;
        bytes32 depositTxHash = keccak256(bytes("integration-claim-deposit"));
        bytes32 finalizeTxHash = keccak256(bytes("integration-claim-finalize"));

        // Whitelist the user before deposit
        vm.prank(hookManager);
        whitelistHook.setUserWhitelisted(user);

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.MintAndDeposit(userId, depositAmount, depositTxHash);
        vm.prank(operator);
        merchant.mintAndDeposit(userId, depositAmount, depositTxHash);

        uint256 currentEpoch = assetCxVault.latestEpochID();

        vm.prank(user);
        uint256 sharesBurned = assetCxVault.withdraw(withdrawAmount, user, user);
        assertEq(sharesBurned, withdrawAmount);
        assertEq(assetCxVault.getUserEpochRequest(user, currentEpoch), withdrawAmount);

        vm.prank(withdrawalManager);
        assetCxVault.closeEpoch();

        vm.prank(withdrawalManager);
        assetCxVault.processEpoch();

        vm.prank(operator);
        uint256 claimed = merchant.claimVaultWithdrawal(userId, currentEpoch);

        assertEq(claimed, withdrawAmount);
        assertEq(merchant.pendingQCRedemption(userId), withdrawAmount);
        assertEq(merchant.totalPendingQCRedemption(), withdrawAmount);
        assertEq(assetCxVault.pastEpochsUnclaimedAssets(), 0);
        assertEq(assetCxVault.getUserEpochRequest(user, currentEpoch), 0);
        assertEq(assetCX.balanceOf(address(merchant)), 0);
        assertEq(assetCX.totalSupply(), depositAmount - withdrawAmount);
        assertEq(assetCxVault.balanceOf(user), depositAmount - withdrawAmount);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.QCRedemptionFinalized(userId, withdrawAmount, 0, 0, finalizeTxHash);

        vm.prank(operator);
        merchant.finalizeQCRedemption(userId, withdrawAmount, finalizeTxHash);

        assertEq(merchant.pendingQCRedemption(userId), 0);
        assertEq(merchant.totalPendingQCRedemption(), 0);
        assertEq(assetCX.balanceOf(address(merchant)), 0);
        assertEq(assetCX.totalSupply(), depositAmount - withdrawAmount);
        assertEq(assetCxVault.balanceOf(user), depositAmount - withdrawAmount);
    }

    function test_mintAndDeposit_revertsWhenUserNotWhitelisted() public {
        bytes32 userId = keccak256("integration-user-not-whitelisted");
        uint256 amount = 1_000e18;
        bytes32 txHash = keccak256(bytes("integration-not-whitelisted-mint"));

        // Set up user account but DO NOT whitelist the user
        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        // Expect revert with UserNotWhitelisted error
        vm.expectRevert(abi.encodeWithSelector(WhitelistHook.UserNotWhitelisted.selector, user));
        vm.prank(operator);
        merchant.mintAndDeposit(userId, amount, txHash);
    }

    function test_emergencyMigrateUserAccount_success() public {
        bytes32 userId = keccak256("integration-user-emergency");
        address newUser = makeAddr("newUser");
        uint256 depositAmount = 1_000e18;
        bytes32 depositTxHash = keccak256(bytes("integration-emergency-deposit"));

        // Whitelist the user before deposit
        vm.prank(hookManager);
        whitelistHook.setUserWhitelisted(user);

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        // Make a deposit
        vm.prank(operator);
        uint256 shares = merchant.mintAndDeposit(userId, depositAmount, depositTxHash);

        assertEq(shares, depositAmount);
        assertEq(assetCxVault.balanceOf(user), depositAmount);
        assertEq(merchant.mintedVaultShares(userId), depositAmount);

        // User approves merchant to transfer their vault shares
        vm.prank(user);
        IERC20(address(assetCxVault)).approve(address(merchant), depositAmount);

        // Admin performs emergency migration
        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.EmergencyUserAccountMigrated(userId, user, newUser, depositAmount);

        vm.prank(admin);
        merchant.emergencyMigrateUserAccount(userId, newUser);

        // Verify shares were transferred
        assertEq(assetCxVault.balanceOf(user), 0);
        assertEq(assetCxVault.balanceOf(newUser), depositAmount);

        // Verify user account was updated
        assertEq(merchant.getUserAccount(userId), newUser);

        // Verify whitelist status
        assertTrue(whitelistHook.userWhitelisted(newUser));
        assertFalse(whitelistHook.userWhitelisted(user));

        // Verify merchant accounting remains consistent
        assertEq(merchant.totalMinted(userId), depositAmount);
        assertEq(merchant.mintedVaultShares(userId), depositAmount);
        assertEq(merchant.totalBurned(userId), 0);
        assertEq(merchant.pendingQCRedemption(userId), 0);

        // =========================================
        // Verify operations work for new account
        // =========================================

        // New user can request withdrawal (they are whitelisted now)
        uint256 withdrawAmount = 400e18;
        uint256 currentEpoch = assetCxVault.latestEpochID();

        vm.prank(newUser);
        uint256 sharesBurned = assetCxVault.withdraw(withdrawAmount, newUser, newUser);

        assertEq(sharesBurned, withdrawAmount);
        assertEq(assetCxVault.getUserEpochRequest(newUser, currentEpoch), withdrawAmount);

        // Process the epoch
        vm.prank(withdrawalManager);
        assetCxVault.closeEpoch();

        vm.prank(withdrawalManager);
        assetCxVault.processEpoch();

        // Operator can claim withdrawal for the user
        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.PendingQCRedemption(userId, currentEpoch, withdrawAmount, withdrawAmount, withdrawAmount);

        vm.prank(operator);
        uint256 claimed = merchant.claimVaultWithdrawal(userId, currentEpoch);

        // Verify claim worked
        assertEq(claimed, withdrawAmount);
        assertEq(merchant.pendingQCRedemption(userId), withdrawAmount);
        assertEq(merchant.totalPendingQCRedemption(), withdrawAmount);
        assertEq(merchant.totalBurned(userId), withdrawAmount);
        assertEq(merchant.mintedVaultShares(userId), depositAmount - withdrawAmount);

        // Finalize QC redemption
        bytes32 finalizeTxHash = keccak256(bytes("integration-emergency-finalize"));

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.QCRedemptionFinalized(userId, withdrawAmount, 0, 0, finalizeTxHash);

        vm.prank(operator);
        merchant.finalizeQCRedemption(userId, withdrawAmount, finalizeTxHash);

        // Verify final state
        assertEq(merchant.pendingQCRedemption(userId), 0);
        assertEq(merchant.totalPendingQCRedemption(), 0);
        assertEq(merchant.totalMinted(userId), depositAmount);
        assertEq(merchant.totalBurned(userId), withdrawAmount);
        assertEq(merchant.mintedVaultShares(userId), depositAmount - withdrawAmount);
        assertEq(assetCxVault.balanceOf(newUser), depositAmount - withdrawAmount);
    }

    function _deployVaultWithHook() internal returns (ConcreteAssetCxVaultImpl, WhitelistHook) {
        AllocateModule module = new AllocateModule();
        ConcreteAssetCxVaultImpl vault = ConcreteAssetCxVaultImpl(
            factory.create(
                implId,
                vaultOwner,
                abi.encode(address(module), address(assetCX), vaultManager, "Concrete Asset CX Vault", "CACXVault")
            )
        );

        // Deploy a new whitelist hook for this vault
        WhitelistHook vaultHook = WhitelistHook(
            payable(ClonesWithImmutableArgs.clone(
                    address(hookImpl), abi.encodePacked(address(factory), address(vault))
                ))
        );
        vm.prank(address(factory));
        vaultHook.initialize(hookManager, new address[](0));

        // Grant WHITELIST_MANAGER_ROLE to hookManager so it can manage whitelist
        vm.prank(hookManager);
        vaultHook.grantRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, hookManager);

        // Set up hooks on the vault
        vm.prank(vaultManager);
        vault.grantRole(RolesLib.HOOK_MANAGER, hookManager);

        uint96 hookFlags = uint96(1 << HooksLibV2.PRE_DEPOSIT) | uint96(1 << HooksLibV2.PRE_MINT)
            | uint96(1 << HooksLibV2.PRE_WITHDRAW) | uint96(1 << HooksLibV2.PRE_REDEEM);

        vm.prank(hookManager);
        vault.setHooks(Hooks({target: address(vaultHook), flags: hookFlags}));

        return (vault, vaultHook);
    }
}

