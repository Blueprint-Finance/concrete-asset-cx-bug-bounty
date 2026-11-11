// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {
    IConcreteFactory,
    ConcreteFactoryBaseSetup,
    VaultProxy
} from "@concrete-xyz/earn-v2-core/test/common/ConcreteFactoryBaseSetup.t.sol";
import {IConcreteAsyncVaultImpl} from "@concrete-xyz/earn-v2-core/src/interface/IConcreteAsyncVaultImpl.sol";
import {IContractId} from "@concrete-xyz/earn-v2-core/src/interface/IContractId.sol";
import {ConcreteAssetCxVaultImpl} from "../../src/implementation/ConcreteAssetCxVault.sol";
import {ConcreteFactoryBaseSetup} from "@concrete-xyz/earn-v2-core/test/common/ConcreteFactoryBaseSetup.t.sol";

contract TestBaseAssetCxSetup is ConcreteFactoryBaseSetup {
    ConcreteAssetCxVaultImpl public concreteAssetCxVaultImpl;
    uint64 public implId;

    function setUp() public virtual override {
        ConcreteFactoryBaseSetup.setUp();

        concreteAssetCxVaultImpl = new ConcreteAssetCxVaultImpl(address(factory));
        implId = IContractId(concreteAssetCxVaultImpl).ID();
        vm.startPrank(factoryOwner);
        factory.approveImplementation(address(concreteAssetCxVaultImpl));
        vm.stopPrank();

        assertEq(factory.getImplementationByVaultImpl(implId), address(concreteAssetCxVaultImpl));

        vm.label(address(factory), "factory");
        vm.label(address(factoryOwner), "factoryOwner");
        vm.label(address(concreteAssetCxVaultImpl), "concreteAssetCxVaultImpl");
    }
}
