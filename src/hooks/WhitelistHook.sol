// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {BaseHook} from "@concrete-xyz/earn-v2-core/src/periphery/hooks/BaseHook.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {AssetCxRolesLib} from "../lib/AssetCxRolesLib.sol";

/**
 * @title WhitelistHook
 * @notice User action hook that enforces a whitelist across deposit, mint, withdraw and redeem flows.
 * @dev Inherits {BaseHook}, which provides the `[factory (20)][vault (20)]` immutable-args layout
 *      (`FACTORY()` / `VAULT()`), the factory-only initializer guard (`__BaseHook_init`), the
 *      contract identity (`ID()`) and no-op defaults for the full `IHook` surface.
 * @dev Uses AccessControlDefaultAdminRulesUpgradeable for role-based access control.
 *      WHITELIST_MANAGER_ROLE can add/remove users from the whitelist.
 */
contract WhitelistHook is BaseHook, AccessControlDefaultAdminRulesUpgradeable {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error UserNotWhitelisted(address user);
    error DifferentReceiverAndOwner();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event UserWhitelisted(address indexed user);
    event UserRemovedFromWhitelist(address indexed user);

    // ─────────────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice User whitelist for specified vault actions.
    /// @dev Maps user address to whitelist status.
    mapping(address user => bool isWhitelisted) public userWhitelisted;

    // ─────────────────────────────────────────────────────────────────────────────
    // Contract identity
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc BaseHook
    function FLAVOUR() public pure override returns (uint256) {
        return 7; // AssetCx Whitelisting Hook
    }

    /// @inheritdoc BaseHook
    function VERSION() public pure override returns (uint256 major, uint256 minor, uint256 patch) {
        return (1, 7, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes the hook with access control and an optional initial whitelist.
     * @param _admin The admin address that can manage roles.
     * @param _initialWhitelisted Accounts to whitelist immediately upon deployment.
     * @dev Only the factory encoded in the immutable args can initialize (via {BaseHook.__BaseHook_init}),
     *      preventing front-running of an uninitialized clone.
     */
    function initialize(address _admin, address[] calldata _initialWhitelisted) external initializer {
        __BaseHook_init();
        require(_admin != address(0), ZeroAddress());
        __AccessControlDefaultAdminRules_init(0, _admin);
        _setRoleAdmin(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
        for (uint256 i = 0; i < _initialWhitelisted.length; ++i) {
            address user = _initialWhitelisted[i];
            require(user != address(0), ZeroAddress());
            userWhitelisted[user] = true;
            emit UserWhitelisted(user);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the whitelist status for a specific user
     * @param _user The user address to configure
     * @dev Only callable by accounts with WHITELIST_MANAGER_ROLE
     */
    function setUserWhitelisted(address _user) external onlyRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE) {
        require(_user != address(0), ZeroAddress());
        userWhitelisted[_user] = true;
        emit UserWhitelisted(_user);
    }

    /**
     * @notice Removes a user from the whitelist
     * @param _user The user address to remove from the whitelist
     * @dev Only callable by accounts with WHITELIST_MANAGER_ROLE
     */
    function removeUserFromWhitelist(address _user) external onlyRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE) {
        require(_user != address(0), ZeroAddress());
        userWhitelisted[_user] = false;
        emit UserRemovedFromWhitelist(_user);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Implementations - Pre Hooks
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Pre-deposit hook
    function preDeposit(address, uint256, uint256, address receiver, uint256) external view override {
        _validateReceiver(receiver);
    }

    /// @notice Pre-mint hook
    function preMint(address, uint256, uint256, address receiver, uint256) external view override {
        _validateReceiver(receiver);
    }

    /// @notice Pre-withdraw hook
    function preWithdraw(address, uint256, uint256, address receiver, address owner, uint256) external view override {
        _validateReceiverAndOwner(receiver, owner);
    }

    /// @notice Pre-redeem hook
    function preRedeem(address, uint256, uint256, address receiver, address owner, uint256) external view override {
        _validateReceiverAndOwner(receiver, owner);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal Functions
    // ─────────────────────────────────────────────────────────────────────────────

    function _validateReceiver(address receiver) private view {
        require(userWhitelisted[receiver], UserNotWhitelisted(receiver));
    }

    function _validateReceiverAndOwner(address receiver, address owner) private view {
        require(receiver == owner, DifferentReceiverAndOwner());
        _validateReceiver(owner);
    }
}
