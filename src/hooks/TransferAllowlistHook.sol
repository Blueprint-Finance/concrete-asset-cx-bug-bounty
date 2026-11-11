// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {BaseHook} from "@concrete-xyz/earn-v2-core/src/periphery/hooks/BaseHook.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title TransferAllowlistHook
 * @notice Transfer hook that restricts share transfers to an explicit allowlist.
 * @dev A transfer is only permitted when the sender has explicitly been allowed
 *      to transfer to the recipient via `allowed[from][to] == true`. Vault-internal
 *      flows (deposit/mint/withdraw/redeem) do not invoke the transfer hook, so no
 *      vault exemption is needed here.
 * @dev Designed to be combined with other hooks (e.g. WhitelistHook) through a
 *      HookContainer.
 * @dev Inherits {BaseHook}, which provides the `[factory (20)][vault (20)]` immutable-args
 *      layout (`FACTORY()` / `VAULT()`), the factory-only initializer guard
 *      (`__BaseHook_init`), the contract identity (`ID()`) and no-op defaults for the
 *      rest of the {IHook} surface.
 * @dev Uses OwnableUpgradeable for a single-owner access model. The owner manages
 *      the transfer allowlist.
 */
contract TransferAllowlistHook is BaseHook, OwnableUpgradeable {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error TransferNotAllowed(address from, address to);

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event TransferAllowanceSet(address indexed from, address indexed to, bool allowed);

    // ─────────────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Explicit transfer allowlist: `allowed[from][to]` permits `from` to transfer to `to`.
    mapping(address from => mapping(address to => bool isAllowed)) public allowed;

    // ─────────────────────────────────────────────────────────────────────────────
    // Contract identity
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc BaseHook
    function FLAVOUR() public pure override returns (uint256) {
        return 8; // AssetCx Transfer Allowlist Hook
    }

    /// @inheritdoc BaseHook
    function VERSION() public pure override returns (uint256 major, uint256 minor, uint256 patch) {
        return (1, 7, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes a freshly-deployed clone of the hook.
     * @param _owner The owner address that manages the transfer allowlist.
     * @dev Only the factory encoded in the immutable args can initialize (via {BaseHook.__BaseHook_init}).
     *      `_owner` zero-address check is handled by OwnableUpgradeable.
     */
    function initialize(address _owner) external initializer {
        __BaseHook_init();
        __Ownable_init(_owner);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Owner Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Allows or disallows `_from` to transfer shares to `_to`.
     * @param _from The address sending the shares.
     * @param _to The address receiving the shares.
     * @param _allowed Whether the transfer pair should be permitted.
     * @dev Only callable by the owner.
     */
    function setAllowed(address _from, address _to, bool _allowed) external onlyOwner {
        require(_from != address(0), ZeroAddress());
        require(_to != address(0), ZeroAddress());
        allowed[_from][_to] = _allowed;
        emit TransferAllowanceSet(_from, _to, _allowed);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Implementations - Transfer Hooks
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Pre-transfer hook — enforces the transfer allowlist.
    function preTransfer(address, address from, address to, uint256) external view override {
        if (allowed[from][to]) return;
        revert TransferNotAllowed(from, to);
    }
}
