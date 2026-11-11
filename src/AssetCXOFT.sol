// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.27;

/**
 *
 * @title AssetCXOFT
 * @author Blueprint Finance
 * @notice Upgradeable ERC20 token with native cross-chain functionality via LayerZero OFT
 * @dev Implements UUPS upgradeability pattern with the following features:
 *      - ERC20 standard with Permit extension (EIP-2612)
 *      - Native cross-chain transfers via LayerZero's Omnichain Fungible Token (OFT) standard
 *      - Burns tokens on source chain and mints on destination chain (1:1 ratio)
 *      - Ownable for managing LayerZero settings and token configuration
 *      - Upgradeable via UUPS proxy pattern
 *.     - Owner and delegate are different roles. They have distinct responsibilities within the contract.
 */

// ════════════════════════════════════════════════════════════════════════════════════════════════════
// IMPORTS
// ════════════════════════════════════════════════════════════════════════════════════════════════════

import {OFTUpgradeable} from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

// ════════════════════════════════════════════════════════════════════════════════════════════════════
// CONTRACT
// ════════════════════════════════════════════════════════════════════════════════════════════════════

contract AssetCXOFT is OwnableUpgradeable, OFTUpgradeable, ERC20PermitUpgradeable, UUPSUpgradeable {
    // ════════════════════════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when an empty string is provided for name, symbol, or EIP712 name
    error EmptyStringNotAllowed();

    // ════════════════════════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Constructor that disables initializers to prevent implementation contract initialization
     * @dev This is a security measure for UUPS proxies to prevent the implementation from being initialized
     * @param _lzEndpoint Address of the LayerZero endpoint for cross-chain messaging
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _lzEndpoint) OFTUpgradeable(_lzEndpoint) {
        _disableInitializers();
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initializes the AssetCXOFT with token details, ownership, and LayerZero configuration
     * @dev This function replaces the constructor for upgradeable contracts
     * @param _name Name of the token
     * @param _symbol Symbol of the token
     * @param _delegate Address that will own this token contract and be capable of making
     *                 OApp configurations inside the LayerZero endpoint
     */
    function initialize(string memory _name, string memory _symbol, address _delegate) public initializer {
        if (bytes(_name).length == 0) revert EmptyStringNotAllowed();
        if (bytes(_symbol).length == 0) revert EmptyStringNotAllowed();

        __OFT_init(_name, _symbol, _delegate);
        __Ownable_init(_delegate);
        __ERC20Permit_init(_name);
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
