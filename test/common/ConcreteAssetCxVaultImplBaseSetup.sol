// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {
    IConcreteFactory,
    ConcreteFactoryBaseSetup,
    VaultProxy,
    IConcreteAsyncVaultImpl,
    ConcreteAssetCxVaultImpl,
    TestBaseAssetCxSetup
} from "./TestBaseAssetCxSetup.sol";
import {ConcreteAssetCxVaultImpl} from "../../src/implementation/ConcreteAssetCxVault.sol";
import {ERC20Mock} from "@concrete-xyz/earn-v2-core/test/mock/ERC20Mock.sol";
import {AllocateModule} from "@concrete-xyz/earn-v2-core/src/module/AllocateModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "@concrete-xyz/earn-v2-core/src/lib/Roles.sol";

contract ConcreteAssetCxVaultImplBaseSetup is TestBaseAssetCxSetup {
    address public vaultOwner;
    address public vaultManager;
    address public hookManager;
    address public strategyOperator;
    address public allocator;
    address public withdrawalManager;

    ERC20Mock public asset;
    AllocateModule public allocateModule;
    ConcreteAssetCxVaultImpl public concreteAssetCxVault;

    function setUp() public virtual override {
        TestBaseAssetCxSetup.setUp();

        vaultOwner = makeAddr("vaultOwner");
        vaultManager = makeAddr("vaultManager");
        hookManager = makeAddr("hookManager");
        strategyOperator = makeAddr("strategyOperator");
        allocator = makeAddr("allocator");
        withdrawalManager = makeAddr("withdrawalManager");

        asset = new ERC20Mock();
        allocateModule = new AllocateModule();
        concreteAssetCxVault = ConcreteAssetCxVaultImpl(
            factory.create(
                implId,
                vaultOwner,
                abi.encode(
                    address(allocateModule), address(asset), vaultManager, "Concrete Asset CX Vault", "CACXVault"
                )
            )
        );

        // grant strategy operator role to strategy operator
        vm.startPrank(vaultManager);
        concreteAssetCxVault.grantRole(RolesLib.STRATEGY_MANAGER, strategyOperator);
        // grant allocator role to allocator
        concreteAssetCxVault.grantRole(RolesLib.ALLOCATOR, allocator);
        // grant hook manager role to hook manager
        concreteAssetCxVault.grantRole(RolesLib.HOOK_MANAGER, hookManager);
        // grant withdrawal manager role to withdrawal manager
        concreteAssetCxVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, withdrawalManager);
        vm.stopPrank();
    }
}
