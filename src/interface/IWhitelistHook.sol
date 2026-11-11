// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/// @title IWhitelistHook
/// @notice Whitelist management surface of the vault hook used during account migrations.
interface IWhitelistHook {
    function setUserWhitelisted(address _user) external;
    function removeUserFromWhitelist(address _user) external;
}
