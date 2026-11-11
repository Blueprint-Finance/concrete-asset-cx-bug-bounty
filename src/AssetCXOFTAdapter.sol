// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.27;

/**
 * @title AssetCXOFTAdapter
 * @author Blueprint Finance
 * @notice Upgradeable LayerZero OFT adapter for AssetCXOFT enabling cross-chain token transfers
 * @dev Implements UUPS upgradeability pattern with the following features:
 *      - Wraps AssetCX (ERC20) to enable cross-chain functionality via LayerZero's OFT standard
 *      - Locks tokens on source chain and unlocks them on destination chain (1:1 ratio)
 *      - Ownable for managing LayerZero settings and adapter configuration
 *      - Upgradeable via UUPS proxy pattern
 *      - Owner and delegate are different roles. They have distinct responsibilities within the contract.
 */

// ════════════════════════════════════════════════════════════════════════════════════════════════════
// IMPORTS
// ════════════════════════════════════════════════════════════════════════════════════════════════════

import {OFTAdapterUpgradeable} from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTAdapterUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

// ════════════════════════════════════════════════════════════════════════════════════════════════════
// CONTRACT
// ════════════════════════════════════════════════════════════════════════════════════════════════════

contract AssetCXOFTAdapter is OwnableUpgradeable, OFTAdapterUpgradeable, UUPSUpgradeable {
    // ════════════════════════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Constructor that disables initializers to prevent implementation contract initialization
     * @dev This is a security measure for UUPS proxies to prevent the implementation from being initialized
     * @param _token Address of the AssetCX (ERC20) to be adapted for cross-chain transfers
     * @param _lzEndpoint Address of the LayerZero endpoint for cross-chain messaging
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _token, address _lzEndpoint) OFTAdapterUpgradeable(_token, _lzEndpoint) {
        _disableInitializers();
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initializes the AssetCXOFTAdapter with ownership and LayerZero configuration
     * @dev This function replaces the constructor for upgradeable contracts
     * @param _delegate Address that will own this adapter contract and be capable of making
     *                 OApp configurations inside the LayerZero endpoint
     */
    function initialize(address _delegate) public initializer {
        __OFTAdapter_init(_delegate);
        __Ownable_init(_delegate);
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only the owner can authorize upgrades
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
