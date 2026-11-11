// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ConcreteFactoryBaseSetup} from "@concrete-xyz/earn-v2-core/test/common/ConcreteFactoryBaseSetup.t.sol";
import {ConcreteAssetCxVaultImpl} from "../../src/implementation/ConcreteAssetCxVault.sol";
import {ConcreteMerchant} from "../../src/merchant/ConcreteMerchant.sol";
import {AssetCX} from "../../src/AssetCX.sol";
import {AssetCxRolesLib} from "../../src/lib/AssetCxRolesLib.sol";
import {AllocateModule} from "@concrete-xyz/earn-v2-core/src/module/AllocateModule.sol";
import {IContractId} from "@concrete-xyz/earn-v2-core/src/interface/IContractId.sol";
import {ConcreteV2RolesLib as RolesLib} from "@concrete-xyz/earn-v2-core/src/lib/Roles.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {AssetCxMultisigStrategy} from "../../src/strategies/AssetCxMultisigStrategy.sol";
import {IAllocateModule} from "@concrete-xyz/earn-v2-core/src/interface/IAllocateModule.sol";
import {PeripheryRolesLib} from "@concrete-xyz/earn-v2-core/src/periphery/lib/PeripheryRolesLib.sol";

contract MockYieldToken is ERC20 {
    constructor() ERC20("Yield Token", "YLD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ConcreteMerchantYieldE2ETest is ConcreteFactoryBaseSetup {
    AssetCX private assetCX;
    ConcreteAssetCxVaultImpl private assetCxVault;
    ConcreteMerchant private merchant;
    AssetCxMultisigStrategy private strategy;
    AllocateModule private allocateModule;
    MockYieldToken private yieldToken;

    address private admin;
    address private operator;
    address private user;
    address private vaultOwner;
    address private vaultManager;
    address private withdrawalManager;
    address private yieldMultisig;
    address private strategyMultisig;
    address private vaultAllocator;
    address private vaultStrategyManager;
    uint64 private implId;

    // Constants for multi-vault test
    bytes32 private constant USER_ID_1 = keccak256("multi-vault-user-1");
    bytes32 private constant USER_ID_2 = keccak256("multi-vault-user-2");
    address private constant USER_1 = address(0x1001);
    address private constant USER_2 = address(0x1002);
    address private constant USER_2_STRATEGY_MULTISIG = address(0x2001);
    address private constant USER_2_YIELD_MULTISIG = address(0x2002);

    // Storage for multi-vault test to avoid stack too deep
    ConcreteAssetCxVaultImpl private user2Vault;
    AssetCxMultisigStrategy private strategy2;

    function setUp() public override {
        ConcreteFactoryBaseSetup.setUp();

        admin = makeAddr("admin");
        operator = makeAddr("operator");
        user = makeAddr("user");
        vaultOwner = makeAddr("vaultOwner");
        vaultManager = makeAddr("vaultManager");
        withdrawalManager = makeAddr("withdrawalManager");
        yieldMultisig = makeAddr("yieldMultisig");
        strategyMultisig = makeAddr("strategyMultisig");

        // Deploy AssetCX implementation and proxy
        AssetCX assetCXImplementation = new AssetCX();
        ERC1967Proxy assetCXProxy = new ERC1967Proxy(
            address(assetCXImplementation), abi.encodeCall(AssetCX.initialize, ("Asset CX", "ACX", admin, address(0)))
        );
        assetCX = AssetCX(address(assetCXProxy));
        yieldToken = new MockYieldToken();

        ConcreteAssetCxVaultImpl implementation = new ConcreteAssetCxVaultImpl(address(factory));

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

        AssetCxMultisigStrategy strategyImpl = new AssetCxMultisigStrategy();
        ERC1967Proxy strategyProxy = new ERC1967Proxy(
            address(strategyImpl),
            abi.encodeCall(
                AssetCxMultisigStrategy.initialize,
                (admin, address(assetCxVault), strategyMultisig, 200, 3 days, 1 days, address(0), address(merchant))
            )
        );
        strategy = AssetCxMultisigStrategy(address(strategyProxy));

        vm.startPrank(admin);
        merchant.setYieldTokenWhitelisted(address(yieldToken), true);
        merchant.setVaultYieldConfig(address(assetCxVault), address(strategy), yieldMultisig);
        vm.stopPrank();

        vm.prank(strategyMultisig);
        yieldToken.approve(address(strategy), type(uint256).max);
        vm.prank(strategyMultisig);
        assetCX.approve(address(strategy), type(uint256).max);

        vm.startPrank(vaultManager);
        assetCxVault.grantRole(RolesLib.ALLOCATOR, vaultManager);
        assetCxVault.grantRole(RolesLib.STRATEGY_MANAGER, vaultManager);
        vm.stopPrank();

        vaultAllocator = vaultManager;
        vaultStrategyManager = vaultManager;

        vm.prank(vaultStrategyManager);
        assetCxVault.addStrategy(address(strategy));

        address[] memory order = new address[](1);
        order[0] = address(strategy);
        vm.prank(vaultAllocator);
        assetCxVault.setDeallocationOrder(order);
    }

    function test_e2e_yield_initiation_and_withdrawal_flow() public {
        bytes32 userId = keccak256("integration-e2e-user");
        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        uint256 depositAmount = 1_000e18;
        _mintDepositAndAllocate(userId, depositAmount, keccak256(bytes("integration-e2e-deposit")));

        (uint256 redeemedYield, int256 accountingDiff) = _initiateAndFinalizeYield(350e18, 330e18, depositAmount);

        _withdrawAndFinalize(
            userId, depositAmount, redeemedYield, accountingDiff, 400e18, keccak256(bytes("integration-e2e-finalize"))
        );
    }

    function _mintDepositAndAllocate(bytes32 userId, uint256 depositAmount, bytes32 txHash) internal {
        vm.prank(operator);
        merchant.mintAndDeposit(userId, depositAmount, txHash);

        assertEq(assetCxVault.totalAssets(), depositAmount);
        assertEq(assetCxVault.totalSupply(), depositAmount);

        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({
            isDeposit: true, strategy: address(strategy), extraData: abi.encode(depositAmount)
        });
        vm.prank(vaultAllocator);
        assetCxVault.allocate(abi.encode(params));

        assertEq(assetCX.balanceOf(strategyMultisig), depositAmount);
    }

    function _initiateAndFinalizeYield(uint256 pendingYield, uint256 redeemedYield, uint256 depositAmount)
        internal
        returns (uint256, int256)
    {
        vm.warp(block.timestamp + 3 days + 1);
        yieldToken.mint(strategyMultisig, pendingYield);

        assertEq(yieldToken.balanceOf(yieldMultisig), 0);
        uint256 nonce = merchant.getNextYieldNonce();
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), pendingYield, nonce);
        assertEq(strategy.getPendingMerchantYield(nonce), pendingYield);
        assertEq(strategy.totalPendingYield(address(yieldToken)), pendingYield);
        assertEq(yieldToken.balanceOf(yieldMultisig), pendingYield);

        vm.prank(operator);
        merchant.finalizeYieldAccrual(
            address(assetCxVault), nonce, redeemedYield, keccak256(bytes("e2e-yield-finalize"))
        );
        assertEq(strategy.getPendingMerchantYield(nonce), 0);
        assertEq(strategy.totalPendingYield(address(yieldToken)), 0);
        assertEq(assetCX.balanceOf(strategyMultisig), depositAmount + redeemedYield);

        int256 accountingDiff = int256(redeemedYield) - int256(pendingYield);
        uint256 accountingNonce = strategy.getNextAccountingNonce();

        vm.prank(admin);
        strategy.adjustTotalAssets(accountingDiff, accountingNonce);

        return (redeemedYield, accountingDiff);
    }

    function _withdrawAndFinalize(
        bytes32 userId,
        uint256 depositAmount,
        uint256 redeemedYield,
        int256 accountingDiff,
        uint256 withdrawAmount,
        bytes32 finalizeTxHash
    ) internal {
        uint256 expectedShares = assetCxVault.convertToShares(withdrawAmount);
        vm.prank(user);
        uint256 sharesBurned = assetCxVault.withdraw(withdrawAmount, user, user);
        assertApproxEqAbs(sharesBurned, expectedShares, 1);

        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({
            isDeposit: false, strategy: address(strategy), extraData: abi.encode(withdrawAmount)
        });
        vm.prank(vaultAllocator);
        assetCxVault.allocate(abi.encode(params));

        uint256 currentEpoch = assetCxVault.latestEpochID();

        vm.prank(withdrawalManager);
        assetCxVault.closeEpoch();
        vm.prank(withdrawalManager);
        assetCxVault.processEpoch();

        vm.prank(operator);
        uint256 claimed = merchant.claimVaultWithdrawal(userId, currentEpoch);
        assertEq(claimed, withdrawAmount);
        assertEq(merchant.pendingQCRedemption(userId), withdrawAmount);
        assertEq(merchant.totalPendingQCRedemption(), withdrawAmount);

        vm.prank(operator);
        merchant.finalizeQCRedemption(userId, withdrawAmount, finalizeTxHash);

        assertEq(merchant.pendingQCRedemption(userId), 0);
        assertEq(merchant.totalPendingQCRedemption(), 0);
        assertEq(assetCX.balanceOf(address(merchant)), 0);
        uint256 userAssetBalance = assetCxVault.convertToAssets(assetCxVault.balanceOf(user));
        int256 expectedUserAssetsSigned = int256(depositAmount) - int256(withdrawAmount) + accountingDiff;
        uint256 expectedUserAssets = expectedUserAssetsSigned > 0 ? uint256(expectedUserAssetsSigned) : 0;
        assertApproxEqAbs(userAssetBalance, expectedUserAssets, 1);
        uint256 expectedStrategyBalance = depositAmount + redeemedYield - withdrawAmount;
        assertApproxEqAbs(assetCX.balanceOf(strategyMultisig), expectedStrategyBalance, 1);
    }

    function test_e2e_multiple_vaults_yield_flow() public {
        (user2Vault, strategy2) = _setupUser2VaultAndStrategy();

        {
            uint256 depositAmount1 = 1_500e18;
            uint256 depositAmount2 = 2_000e18;
            _mintDepositAndAllocateMultiple(depositAmount1, depositAmount2);
        }

        uint256 redeemedYield1;
        uint256 redeemedYield2;
        int256 accountingDiff1;
        int256 accountingDiff2;
        {
            uint256 depositAmount1 = 1_500e18;
            uint256 depositAmount2 = 2_000e18;
            (redeemedYield1, redeemedYield2, accountingDiff1, accountingDiff2) =
                _initiateAndFinalizeYieldMultiple(depositAmount1, depositAmount2);
        }

        {
            uint256 depositAmount1 = 1_500e18;
            uint256 depositAmount2 = 2_000e18;
            uint256 withdrawAmount1 = 800e18;
            uint256 withdrawAmount2 = 1_000e18;
            _withdrawAndFinalizeMultiple(
                depositAmount1,
                depositAmount2,
                redeemedYield1,
                redeemedYield2,
                accountingDiff1,
                accountingDiff2,
                withdrawAmount1,
                withdrawAmount2
            );
        }
    }

    function _setupUser2VaultAndStrategy() internal returns (ConcreteAssetCxVaultImpl, AssetCxMultisigStrategy) {
        ConcreteAssetCxVaultImpl vault;
        AssetCxMultisigStrategy strat;
        {
            AllocateModule allocateModule2 = new AllocateModule();
            vault = ConcreteAssetCxVaultImpl(
                factory.create(
                    implId,
                    vaultOwner,
                    abi.encode(address(allocateModule2), address(assetCX), vaultManager, "User 2 Vault", "U2Vault")
                )
            );
        }

        {
            AssetCxMultisigStrategy strategy2Impl = new AssetCxMultisigStrategy();
            ERC1967Proxy strategy2Proxy = new ERC1967Proxy(
                address(strategy2Impl),
                abi.encodeCall(
                    AssetCxMultisigStrategy.initialize,
                    (
                        admin,
                        address(vault),
                        USER_2_STRATEGY_MULTISIG,
                        200,
                        3 days,
                        1 days,
                        address(0),
                        address(merchant)
                    )
                )
            );
            strat = AssetCxMultisigStrategy(address(strategy2Proxy));
        }

        {
            vm.startPrank(admin);
            merchant.setUserAccount(USER_ID_2, USER_2);
            merchant.setUserVault(USER_ID_2, IERC4626(address(vault)));
            merchant.setVaultYieldConfig(address(vault), address(strat), USER_2_YIELD_MULTISIG);
            vm.stopPrank();
        }

        {
            vm.prank(vaultManager);
            vault.grantRole(AssetCxRolesLib.MERCHANT_ROLE, address(merchant));
            vm.prank(vaultManager);
            vault.grantRole(RolesLib.WITHDRAWAL_MANAGER, withdrawalManager);
            vm.prank(vaultManager);
            vault.grantRole(RolesLib.ALLOCATOR, vaultManager);
            vm.prank(vaultManager);
            vault.grantRole(RolesLib.STRATEGY_MANAGER, vaultManager);
        }

        {
            vm.prank(USER_2_STRATEGY_MULTISIG);
            yieldToken.approve(address(strat), type(uint256).max);
            vm.prank(USER_2_STRATEGY_MULTISIG);
            assetCX.approve(address(strat), type(uint256).max);
        }

        {
            vm.prank(vaultManager);
            vault.addStrategy(address(strat));

            address[] memory order2 = new address[](1);
            order2[0] = address(strat);
            vm.prank(vaultManager);
            vault.setDeallocationOrder(order2);
        }

        return (vault, strat);
    }

    function _mintDepositAndAllocateMultiple(uint256 depositAmount1, uint256 depositAmount2) internal {
        vm.startPrank(admin);
        merchant.setUserAccount(USER_ID_1, USER_1);
        vm.stopPrank();

        vm.prank(operator);
        merchant.mintAndDeposit(USER_ID_1, depositAmount1, keccak256(bytes("multi-vault-deposit-1")));

        vm.prank(operator);
        merchant.mintAndDeposit(USER_ID_2, depositAmount2, keccak256(bytes("multi-vault-deposit-2")));

        IAllocateModule.AllocateParams[] memory params1 = new IAllocateModule.AllocateParams[](1);
        params1[0] = IAllocateModule.AllocateParams({
            isDeposit: true, strategy: address(strategy), extraData: abi.encode(depositAmount1)
        });
        vm.prank(vaultAllocator);
        assetCxVault.allocate(abi.encode(params1));

        IAllocateModule.AllocateParams[] memory params2 = new IAllocateModule.AllocateParams[](1);
        params2[0] = IAllocateModule.AllocateParams({
            isDeposit: true, strategy: address(strategy2), extraData: abi.encode(depositAmount2)
        });
        vm.prank(vaultManager);
        user2Vault.allocate(abi.encode(params2));

        assertEq(assetCX.balanceOf(strategyMultisig), depositAmount1);
        assertEq(assetCX.balanceOf(USER_2_STRATEGY_MULTISIG), depositAmount2);
    }

    function _initiateAndFinalizeYieldMultiple(uint256 depositAmount1, uint256 depositAmount2)
        internal
        returns (uint256 redeemedYield1, uint256 redeemedYield2, int256 accountingDiff1, int256 accountingDiff2)
    {
        vm.warp(block.timestamp + 3 days + 1);

        uint256 yield1 = 500e18;
        uint256 yield2 = 600e18;
        redeemedYield1 = 480e18;
        redeemedYield2 = 580e18;

        yieldToken.mint(strategyMultisig, yield1);
        uint256 nonce1 = merchant.getNextYieldNonce();
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), yield1, nonce1);

        yieldToken.mint(USER_2_STRATEGY_MULTISIG, yield2);
        uint256 nonce2 = merchant.getNextYieldNonce();
        vm.prank(admin);
        strategy2.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), yield2, nonce2);

        assertEq(yieldToken.balanceOf(yieldMultisig), yield1);
        assertEq(yieldToken.balanceOf(USER_2_YIELD_MULTISIG), yield2);
        assertEq(merchant.pendingYield(nonce1), yield1);
        assertEq(merchant.pendingYield(nonce2), yield2);
        // Both accruals are in the same token, so the per-token aggregate covers both.
        assertEq(merchant.totalPendingYieldByToken(address(yieldToken)), yield1 + yield2);

        vm.prank(operator);
        merchant.finalizeYieldAccrual(
            address(assetCxVault), nonce1, redeemedYield1, keccak256(bytes("multi-vault-yield-1"))
        );

        vm.prank(operator);
        merchant.finalizeYieldAccrual(
            address(user2Vault), nonce2, redeemedYield2, keccak256(bytes("multi-vault-yield-2"))
        );

        assertEq(assetCX.balanceOf(strategyMultisig), depositAmount1 + redeemedYield1);
        assertEq(assetCX.balanceOf(USER_2_STRATEGY_MULTISIG), depositAmount2 + redeemedYield2);

        accountingDiff1 = int256(redeemedYield1) - int256(yield1);
        accountingDiff2 = int256(redeemedYield2) - int256(yield2);

        uint256 accountingNonce1 = strategy.getNextAccountingNonce();
        uint256 accountingNonce2 = strategy2.getNextAccountingNonce();

        assertEq(merchant.totalPendingYieldByToken(address(yieldToken)), 0);

        vm.prank(admin);
        strategy.adjustTotalAssets(accountingDiff1, accountingNonce1);

        vm.prank(admin);
        strategy2.adjustTotalAssets(accountingDiff2, accountingNonce2);
    }

    function _withdrawAndFinalizeMultiple(
        uint256 depositAmount1,
        uint256 depositAmount2,
        uint256 redeemedYield1,
        uint256 redeemedYield2,
        int256 accountingDiff1,
        int256 accountingDiff2,
        uint256 withdrawAmount1,
        uint256 withdrawAmount2
    ) internal {
        _processWithdrawals(withdrawAmount1, withdrawAmount2);

        (uint256 epoch1, uint256 epoch2) = _processEpochs();
        _claimAndFinalizeRedemptions(withdrawAmount1, withdrawAmount2, epoch1, epoch2);
        _verifyFinalBalances(
            depositAmount1,
            depositAmount2,
            redeemedYield1,
            redeemedYield2,
            accountingDiff1,
            accountingDiff2,
            withdrawAmount1,
            withdrawAmount2
        );
    }

    function _processWithdrawals(uint256 withdrawAmount1, uint256 withdrawAmount2) internal {
        vm.prank(USER_1);
        assetCxVault.withdraw(withdrawAmount1, USER_1, USER_1);

        vm.prank(USER_2);
        user2Vault.withdraw(withdrawAmount2, USER_2, USER_2);

        // Deallocate withdrawals from strategies
        IAllocateModule.AllocateParams[] memory withdrawParams1 = new IAllocateModule.AllocateParams[](1);
        withdrawParams1[0] = IAllocateModule.AllocateParams({
            isDeposit: false, strategy: address(strategy), extraData: abi.encode(withdrawAmount1)
        });
        vm.prank(vaultAllocator);
        assetCxVault.allocate(abi.encode(withdrawParams1));

        IAllocateModule.AllocateParams[] memory withdrawParams2 = new IAllocateModule.AllocateParams[](1);
        withdrawParams2[0] = IAllocateModule.AllocateParams({
            isDeposit: false, strategy: address(strategy2), extraData: abi.encode(withdrawAmount2)
        });
        vm.prank(vaultManager);
        user2Vault.allocate(abi.encode(withdrawParams2));
    }

    function _processEpochs() internal returns (uint256 epoch1, uint256 epoch2) {
        epoch1 = assetCxVault.latestEpochID();
        epoch2 = user2Vault.latestEpochID();

        vm.prank(withdrawalManager);
        assetCxVault.closeEpoch();
        vm.prank(withdrawalManager);
        assetCxVault.processEpoch();

        vm.prank(withdrawalManager);
        user2Vault.closeEpoch();
        vm.prank(withdrawalManager);
        user2Vault.processEpoch();
    }

    function _claimAndFinalizeRedemptions(
        uint256 withdrawAmount1,
        uint256 withdrawAmount2,
        uint256 epoch1,
        uint256 epoch2
    ) internal {
        vm.prank(operator);
        uint256 claimed1 = merchant.claimVaultWithdrawal(USER_ID_1, epoch1);
        assertApproxEqAbs(claimed1, withdrawAmount1, 1000);

        vm.prank(operator);
        uint256 claimed2 = merchant.claimVaultWithdrawal(USER_ID_2, epoch2);
        assertApproxEqAbs(claimed2, withdrawAmount2, 1000);

        assertApproxEqAbs(merchant.pendingQCRedemption(USER_ID_1), claimed1, 0);
        assertApproxEqAbs(merchant.pendingQCRedemption(USER_ID_2), claimed2, 0);
        assertEq(merchant.totalPendingQCRedemption(), claimed1 + claimed2);

        vm.prank(operator);
        merchant.finalizeQCRedemption(USER_ID_1, claimed1, keccak256(bytes("multi-vault-finalize-1")));

        vm.prank(operator);
        merchant.finalizeQCRedemption(USER_ID_2, claimed2, keccak256(bytes("multi-vault-finalize-2")));

        assertEq(merchant.pendingQCRedemption(USER_ID_1), 0);
        assertEq(merchant.pendingQCRedemption(USER_ID_2), 0);
        assertEq(merchant.totalPendingQCRedemption(), 0);
    }

    function _verifyFinalBalances(
        uint256 depositAmount1,
        uint256 depositAmount2,
        uint256 redeemedYield1,
        uint256 redeemedYield2,
        int256 accountingDiff1,
        int256 accountingDiff2,
        uint256 withdrawAmount1,
        uint256 withdrawAmount2
    ) internal {
        {
            uint256 user1Balance = assetCxVault.convertToAssets(assetCxVault.balanceOf(USER_1));
            int256 expectedUser1Assets = int256(depositAmount1) - int256(withdrawAmount1) + accountingDiff1;
            assertApproxEqAbs(user1Balance, uint256(expectedUser1Assets), 1000);
        }

        {
            uint256 user2Balance = user2Vault.convertToAssets(user2Vault.balanceOf(USER_2));
            int256 expectedUser2Assets = int256(depositAmount2) - int256(withdrawAmount2) + accountingDiff2;
            assertApproxEqAbs(user2Balance, uint256(expectedUser2Assets), 1000);
        }

        {
            uint256 expectedStrategy1Balance = depositAmount1 + redeemedYield1 - withdrawAmount1;
            uint256 expectedStrategy2Balance = depositAmount2 + redeemedYield2 - withdrawAmount2;
            assertApproxEqAbs(assetCX.balanceOf(strategyMultisig), expectedStrategy1Balance, 1000);
            assertApproxEqAbs(assetCX.balanceOf(USER_2_STRATEGY_MULTISIG), expectedStrategy2Balance, 1000);
        }
    }
}

