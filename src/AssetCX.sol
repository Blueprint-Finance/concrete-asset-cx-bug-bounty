// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/access/AccessControlUpgradeable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {TimelockIntegrationLib} from "@concrete-xyz/earn-v2-core/src/lib/TimelockIntegrationLib.sol";
import {ITimelockProtected} from "@concrete-xyz/earn-v2-core/src/interface/ITimelockProtected.sol";
import {AssetCxRolesLib} from "./lib/AssetCxRolesLib.sol";
import {IAssetCX} from "./interface/IAssetCX.sol";

/**
 * @title AssetCX
 * @author Blueprint Finance
 * @notice ERC20 token with role-based access control for minting and burning
 * @dev This contract is upgradeable using the UUPS pattern. Privileged
 *      configuration (`_authorizeUpgrade`, role grants, `setTimelock`,
 *      `unpause`) flows through the Timelock once enforcement is activated.
 *      `pause` and grants of `PAUSER_ROLE` are intentionally instant
 */
contract AssetCX is
    Initializable,
    ERC20PausableUpgradeable,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    ITimelockProtected,
    IAssetCX
{
    /// @dev Validates and consumes the matured timelock schedule entry for the
    ///      calling function. No-op while timelock enforcement is not yet active.
    function _enforceDelay() internal {
        TimelockIntegrationLib.enforceDelay(msg.sig, msg.data[4:]);
    }

    /// @dev Applied to privileged functions that require a prior {ITimelock.propose}
    ///      followed by the matured tier delay before they can execute.
    modifier afterDelay() {
        _enforceDelay();
        _;
    }

    /**
     * @dev Constructor that disables initializers
     */
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IAssetCX
    function initialize(string memory name_, string memory symbol_, address admin, address timelock_)
        public
        initializer
    {
        if (admin == address(0)) {
            revert AdminCannotBeZeroAddress();
        }

        __ERC20_init_unchained(name_, symbol_);
        __Pausable_init_unchained();
        __ERC20Pausable_init_unchained();
        __AccessControlEnumerable_init_unchained();
        __UUPSUpgradeable_init_unchained();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(AssetCxRolesLib.MERCHANT_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(AssetCxRolesLib.PAUSER_ROLE, DEFAULT_ADMIN_ROLE);

        _grantRole(AssetCxRolesLib.PAUSER_ROLE, admin);

        if (timelock_ != address(0)) TimelockIntegrationLib.setTimelock(timelock_);
    }

    /// @inheritdoc IAssetCX
    function reinitializeV2(address[] calldata pausers) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        // reassert the default admin as role admin
        _setRoleAdmin(AssetCxRolesLib.PAUSER_ROLE, DEFAULT_ADMIN_ROLE);
        uint256 len = pausers.length;
        for (uint256 i = 0; i < len; ++i) {
            address pauser = pausers[i];
            if (pauser == address(0)) continue;
            _grantRole(AssetCxRolesLib.PAUSER_ROLE, pauser);
        }
    }

    /// @inheritdoc IAssetCX
    function reinitializeV3(
        address tempAdminA,
        address tempAdminB,
        address[] calldata merchants,
        address[] calldata pausers
    ) external reinitializer(3) onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tempAdminA == address(0) || tempAdminB == address(0)) revert ZeroAddress();
        // A stand-in that already holds the role would have its grant short-circuit and then be
        // revoked below, silently removing an existing admin. The caller always holds the role, so
        // this also rejects the caller naming itself. A repeated stand-in fails to lift the count.
        if (hasRole(DEFAULT_ADMIN_ROLE, tempAdminA)) revert InvalidTempAdmin(tempAdminA);
        if (hasRole(DEFAULT_ADMIN_ROLE, tempAdminB)) revert InvalidTempAdmin(tempAdminB);
        if (tempAdminA == tempAdminB) revert InvalidTempAdmin(tempAdminB);

        // `DEFAULT_ADMIN_ROLE` cannot use the drop-and-re-grant path the other roles use: the
        // caller is the sole admin and is not yet enumerated, so `_revokeRole` would see a member
        // count of zero and trip the last-admin guard. Two throw-away admins lift the count to two
        // first, which lets the caller be dropped and re-entered, after which both are removed
        // again. Neither temp address is ever usable — the whole sequence is internal to this one
        // transaction, and the exit assertion below proves both are gone.
        _grantRole(DEFAULT_ADMIN_ROLE, tempAdminA);
        _grantRole(DEFAULT_ADMIN_ROLE, tempAdminB);

        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        _revokeRole(DEFAULT_ADMIN_ROLE, tempAdminA);
        _revokeRole(DEFAULT_ADMIN_ROLE, tempAdminB);

        _reenterRoleMembers(AssetCxRolesLib.MERCHANT_ROLE, merchants);
        _reenterRoleMembers(AssetCxRolesLib.PAUSER_ROLE, pausers);

        // The admin set must end up holding exactly the caller: one member, and that member is the
        // admin that entered this call. Anything else means a temp admin survived.
        uint256 adminCount = getRoleMemberCount(DEFAULT_ADMIN_ROLE);
        address enumeratedAdmin = adminCount == 1 ? getRoleMember(DEFAULT_ADMIN_ROLE, 0) : address(0);
        if (adminCount != 1 || enumeratedAdmin != msg.sender) {
            revert AdminBackfillMismatch(adminCount, enumeratedAdmin);
        }

        emit RoleMembershipBackfilled(DEFAULT_ADMIN_ROLE, adminCount);
    }

    /// @dev Seeds the enumerable membership set of `role` with accounts that already hold it, by
    ///      dropping and immediately re-granting each one: `_grantRole` short-circuits for an
    ///      existing holder and so would never reach the set. Not usable for `DEFAULT_ADMIN_ROLE`,
    ///      which {reinitializeV3} handles through its own temporary-admin sequence. Used only by
    ///      {reinitializeV3}.
    function _reenterRoleMembers(bytes32 role, address[] calldata members) private {
        uint256 len = members.length;
        for (uint256 i = 0; i < len; ++i) {
            address account = members[i];
            if (!hasRole(role, account)) revert NotACurrentRoleHolder(role, account);
            _revokeRole(role, account);
            _grantRole(role, account);
        }

        emit RoleMembershipBackfilled(role, getRoleMemberCount(role));
    }

    /// @inheritdoc IAssetCX
    function mint(uint256 amount) external onlyRole(AssetCxRolesLib.MERCHANT_ROLE) {
        _mint(msg.sender, amount);
    }

    /// @inheritdoc IAssetCX
    function burn(uint256 amount) external onlyRole(AssetCxRolesLib.MERCHANT_ROLE) {
        _burn(msg.sender, amount);
    }

    /// @inheritdoc ITimelockProtected
    function setTimelock(address timelock_) external override afterDelay onlyRole(DEFAULT_ADMIN_ROLE) {
        if (timelock_ == address(0)) revert ZeroAddress();
        TimelockIntegrationLib.setTimelock(timelock_);
        emit TimelockSet(timelock_);
    }

    /// @inheritdoc ITimelockProtected
    function activateTimelock() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        address tl = TimelockIntegrationLib.activateTimelock();
        emit TimelockActivated(tl);
    }

    /// @inheritdoc ITimelockProtected
    function getTimelock() external view override returns (address timelock_, bool active_) {
        return TimelockIntegrationLib.state();
    }

    /// @dev Routes role grants through the timelock so that role membership
    ///      (notably `MERCHANT_ROLE`) cannot change without a queued proposal.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (role != AssetCxRolesLib.PAUSER_ROLE) {
            _enforceDelay();
        }
        super.grantRole(role, account);
    }

    /// @notice Prevents removing the last `DEFAULT_ADMIN_ROLE`, which would leave the token
    ///         permanently without an admin and therefore unupgradeable.
    /// @dev Both {revokeRole} and {renounceRole} funnel through here, so this single override
    ///      blocks self-revoke, self-renounce and admin-revokes-admin alike. Every revoke or
    ///      renounce of `DEFAULT_ADMIN_ROLE` reverts while the enumerated member count is one or
    ///      less, including for an admin that is not enumerated: the guard reads only
    ///      `getRoleMemberCount`, not `hasRole`.
    function _revokeRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        if (role == DEFAULT_ADMIN_ROLE && getRoleMemberCount(DEFAULT_ADMIN_ROLE) <= 1) {
            revert CannotRemoveLastRoleAdmin();
        }
        return super._revokeRole(role, account);
    }

    /// @inheritdoc IAssetCX
    function pause() external onlyRole(AssetCxRolesLib.PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IAssetCX
    function unpause() external afterDelay onlyRole(AssetCxRolesLib.PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only addresses with DEFAULT_ADMIN_ROLE can authorize upgrades, and
     *      only after the upgrade selector has matured through the timelock.
     *      Emits {AssetCxUpgradeAuthorized} in addition to OZ's {IERC1967.Upgraded}
     *      so monitoring can attribute the upgrade to the queued proposal that
     *      authorized it.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) afterDelay {
        emit AssetCxUpgradeAuthorized(newImplementation, msg.sender);
    }
}
