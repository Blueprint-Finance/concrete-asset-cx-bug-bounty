// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ConcreteAsyncVaultImpl} from "@concrete-xyz/earn-v2-core/src/implementation/ConcreteAsyncVaultImpl.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {ConcreteStandardVaultImpl} from "@concrete-xyz/earn-v2-core/src/implementation/ConcreteStandardVaultImpl.sol";
import {IConcreteAsyncVaultImpl} from "@concrete-xyz/earn-v2-core/src/interface/IConcreteAsyncVaultImpl.sol";
import {
    IDefaultEnforcedVaultConfiguration
} from "@concrete-xyz/earn-v2-core/src/interface/IDefaultEnforcedVaultConfiguration.sol";
import {AssetCxVaultHelperLib} from "../lib/AssetCxVaultHelperLib.sol";
import {AssetCxStateInitLib} from "../lib/AssetCxStateInitLib.sol";
import {AssetCxRolesLib} from "../lib/AssetCxRolesLib.sol";
import {
    ConcreteStandardVaultImplStorageLib as SVLib
} from "@concrete-xyz/earn-v2-core/src/lib/storage/ConcreteStandardVaultImplStorageLib.sol";
import {ContractIdEncoding} from "@concrete-xyz/earn-v2-core/src/lib/ContractIdEncoding.sol";

/**
 * @title ConcreteAssetCxVaultImpl
 * @notice Custom async vault implementation for Asset CX
 * @dev Inherits from ConcreteAsyncVaultImpl
 * @author Blueprint Finance
 */
contract ConcreteAssetCxVaultImpl is ConcreteAsyncVaultImpl {
    error NotImplemented();

    function FLAVOUR() public pure virtual override returns (uint256) {
        return 7; // AssetCX Async vault
    }

    function ID() public pure virtual override(ConcreteAsyncVaultImpl) returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 7, 0);
    }

    constructor(address factory) ConcreteAsyncVaultImpl(factory) {}

    /**
     * @dev Override _initialize to set up async vault specific state
     */
    function _initialize(
        uint64 initialVersion,
        address owner,
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration calldata defaultEnforcedVaultConfig,
        bytes memory data
    ) internal virtual override {
        super._initialize(initialVersion, owner, defaultEnforcedVaultConfig, data);
        __ConcreteAssetCxVaultImpl_init();
    }

    function __ConcreteAssetCxVaultImpl_init() internal onlyInitializing {
        AssetCxStateInitLib.stateInitAssetCxVaultImpl();
    }

    /**
     * @dev Upgrade hook for proxies migrating to this implementation.
     *
     * Runs the inherited earn-v2 async migration first.
     */
    function _upgrade(uint64 newVersion, bytes calldata data) internal virtual override {
        super._upgrade(newVersion, data);
        AssetCxStateInitLib.stateUpgradeAssetCxVaultImpl();
    }

    function deposit(uint256 assets, address receiver)
        public
        virtual
        override(ConcreteStandardVaultImpl, IERC4626)
        onlyRole(AssetCxRolesLib.MERCHANT_ROLE)
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        virtual
        override(ConcreteStandardVaultImpl, IERC4626)
        onlyRole(AssetCxRolesLib.MERCHANT_ROLE)
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function claimWithdrawal(address user, uint256[] calldata epochIDs)
        external
        virtual
        override
        onlyRole(AssetCxRolesLib.MERCHANT_ROLE)
    {
        require(user != address(0), ZeroAddress());
        require(epochIDs.length > 0, EmptyEpochIDs());
        AssetCxVaultHelperLib.claimWithdrawal(user, epochIDs, decimals());
    }

    function claimWithdrawal(uint256[] calldata) external virtual override {
        revert NotImplemented();
    }

    function claimUsersBatch(address[] calldata, uint256) external virtual override {
        revert NotImplemented();
    }

    function toggleQueueActive() external virtual override {
        revert NotImplemented();
    }

    /**
     * @notice Returns the hook target address configured for this vault
     * @return The address of the hook contract (e.g., WhitelistHook)
     */
    function getHook() external view returns (address) {
        return SVLib.fetch().hooks.target;
    }
}

