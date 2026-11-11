// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/// @title IRedemptionClaimToken
/// @author Blueprint Finance
/// @notice External surface, events and errors of the RedemptionClaimToken ("IOU") contract.
/// @dev Inherited by `RedemptionClaimToken` so all members stay addressable as
///      `RedemptionClaimToken.<Member>` (e.g. in tests and integrations).
interface IRedemptionClaimToken {
    // ─────────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();
    /// @notice Thrown when the token is initialized with zero decimals.
    error ZeroDecimals();
    /// @notice Thrown when a transfer endpoint is not on the whitelist.
    error NotWhitelisted(address account);
    /// @notice Thrown when adding an address that is already on the whitelist.
    error AlreadyWhitelisted(address account);
    /// @notice Thrown when removing an address that is not on the whitelist.
    error NotInWhitelist(address account);
    /// @notice Thrown when trying to remove the last default admin.
    error CannotRemoveLastRoleAdmin();

    // ─────────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when an address is added to the transfer whitelist.
    /// @param account Address that gained transfer permission.
    event WhitelistAdded(address indexed account);

    /// @notice Emitted when an address is removed from the transfer whitelist.
    /// @param account Address that lost transfer permission.
    event WhitelistRemoved(address indexed account);

    /// @notice Emitted when a UUPS upgrade of this contract is authorized.
    /// @param newImplementation Implementation address that the proxy is being upgraded to.
    /// @param authorizer        Account that satisfied the role + timelock checks for the upgrade.
    event RedemptionClaimTokenUpgradeAuthorized(address indexed newImplementation, address indexed authorizer);

    // ────────────────────────────── Functions ─────────────────────────────

    /// @notice Mints `amount` tokens to the caller.
    /// @dev Only `LIQUIDATION_MODULE_ROLE`. The caller must be whitelisted (enforced on transfer).
    /// @param amount Amount to mint.
    function mint(uint256 amount) external;

    /// @notice Burns `amount` tokens from the caller.
    /// @dev Only `LIQUIDATION_MODULE_ROLE`. The caller must be whitelisted (enforced on transfer).
    /// @param amount Amount to burn.
    function burn(uint256 amount) external;

    /// @notice Adds `account` to the transfer whitelist.
    /// @dev Only `WHITELIST_MANAGER_ROLE`, and only after a timelock proposal has matured.
    ///      Reverts with {AlreadyWhitelisted} if already present.
    /// @param account Address to grant transfer permission.
    function addToWhitelist(address account) external;

    /// @notice Removes `account` from the transfer whitelist.
    /// @dev Only `WHITELIST_MANAGER_ROLE`. Reverts with {NotInWhitelist} if not present.
    /// @param account Address to revoke transfer permission.
    function removeFromWhitelist(address account) external;

    /// @notice Returns the full current transfer whitelist.
    /// @return The list of whitelisted addresses.
    function getWhitelist() external view returns (address[] memory);

    /// @notice Returns whether `account` is on the transfer whitelist.
    /// @param account Address to query.
    /// @return True if `account` is whitelisted.
    function isWhitelisted(address account) external view returns (bool);

    /// @notice Returns the number of addresses on the transfer whitelist.
    /// @return The whitelist cardinality.
    function whitelistLength() external view returns (uint256);

    /// @notice Pauses transfers, mints and burns.
    /// @dev Only `PAUSER_ROLE`. Intentionally NOT timelock-gated.
    function pause() external;

    /// @notice Lifts the pause.
    /// @dev Only `PAUSER_ROLE`, and only after a timelock proposal has matured.
    function unpause() external;
}
