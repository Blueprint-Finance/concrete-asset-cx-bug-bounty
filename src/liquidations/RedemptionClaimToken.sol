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
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {TimelockIntegrationLib} from "@concrete-xyz/earn-v2-core/src/lib/TimelockIntegrationLib.sol";
import {ITimelockProtected} from "@concrete-xyz/earn-v2-core/src/interface/ITimelockProtected.sol";
import {AssetCxRolesLib} from "../lib/AssetCxRolesLib.sol";
import {RedemptionClaimTokenStorageLib} from "../lib/RedemptionClaimTokenStorageLib.sol";
import {IRedemptionClaimToken} from "../interface/IRedemptionClaimToken.sol";

/**
 * @title RedemptionClaimToken
 * @author Blueprint Finance
 * @notice Debt-segregated redemption-claim ERC-20 that temporarily stands in for
 *         redeemed collateral inside a Dolomite position during a liquidation, then is burned.
 *         One instance is deployed per collateral/debt market pair; the first deployment is
 *         `rBTCcx-USD1` (redemption claim, BTCcx to USD1).
 * @dev Upgradeable via the UUPS pattern (mirroring {AssetCX}). Privileged configuration
 *      (`_authorizeUpgrade`, role grants other than `PAUSER_ROLE`, `setTimelock`, `unpause`)
 *      flows through the Timelock once enforcement is activated. `pause` and grants of
 *      `PAUSER_ROLE` are intentionally instant. Roles:
 *      - `DEFAULT_ADMIN_ROLE`: the main admin; administers all roles and authorizes upgrades.
 *      - `LIQUIDATION_MODULE_ROLE`: the only party allowed to mint and burn (the
 *        `DolomiteLiquidationModule`).
 *      - `WHITELIST_MANAGER_ROLE`: manages the transfer whitelist; granted to the admin by
 *        default at initialization.
 *      - `PAUSER_ROLE`: emergency stop; granted to the admin by default.
 *
 *      Transfers are confined to a closed ecosystem: every non-zero `from`/`to` endpoint must
 *      be on the whitelist, so the token only ever moves between the merchant/module and the
 *      Dolomite account. Mint (`from == address(0)`) and burn (`to == address(0)`) are allowed
 *      as long as the non-zero counterparty is whitelisted.
 */
contract RedemptionClaimToken is
    Initializable,
    ERC20PausableUpgradeable,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    ITimelockProtected,
    IRedemptionClaimToken
{
    using EnumerableSet for EnumerableSet.AddressSet;

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

    /// @dev Disables initializers on the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the token.
     * @param name_       Token name.
     * @param symbol_     Token symbol.
     * @param admin       Address that receives `DEFAULT_ADMIN_ROLE`, `WHITELIST_MANAGER_ROLE`
     *                    and `PAUSER_ROLE`. `LIQUIDATION_MODULE_ROLE` is granted separately after
     *                    the liquidation module is deployed with this token as a dependency.
     * @param decimals_   Token decimals; must be non-zero.
     * @param timelock_   Address of the Timelock contract. Pass `address(0)` to deploy without
     *                    timelock enforcement (it can be configured later until activated).
     */
    function initialize(string memory name_, string memory symbol_, address admin, uint8 decimals_, address timelock_)
        public
        initializer
    {
        if (admin == address(0)) revert ZeroAddress();
        if (decimals_ == 0) revert ZeroDecimals();

        __ERC20_init_unchained(name_, symbol_);
        __Pausable_init_unchained();
        __ERC20Pausable_init_unchained();
        __AccessControlEnumerable_init_unchained();
        __UUPSUpgradeable_init_unchained();

        RedemptionClaimTokenStorageLib.fetch().decimalsValue = decimals_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(AssetCxRolesLib.LIQUIDATION_MODULE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(AssetCxRolesLib.PAUSER_ROLE, DEFAULT_ADMIN_ROLE);

        _grantRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE, admin);
        _grantRole(AssetCxRolesLib.PAUSER_ROLE, admin);

        if (timelock_ != address(0)) TimelockIntegrationLib.setTimelock(timelock_);
    }

    /// @inheritdoc ERC20Upgradeable
    function decimals() public view override returns (uint8) {
        return RedemptionClaimTokenStorageLib.fetch().decimalsValue;
    }

    // ============ Mint / Burn (LIQUIDATION_MODULE_ROLE only) ============

    /// @inheritdoc IRedemptionClaimToken
    function mint(uint256 amount) external override onlyRole(AssetCxRolesLib.LIQUIDATION_MODULE_ROLE) {
        _mint(msg.sender, amount);
    }

    /// @inheritdoc IRedemptionClaimToken
    function burn(uint256 amount) external override onlyRole(AssetCxRolesLib.LIQUIDATION_MODULE_ROLE) {
        _burn(msg.sender, amount);
    }

    // ============ Whitelist management (WHITELIST_MANAGER_ROLE only) ============

    /// @inheritdoc IRedemptionClaimToken
    function addToWhitelist(address account)
        external
        override
        afterDelay
        onlyRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE)
    {
        if (account == address(0)) revert ZeroAddress();
        if (!RedemptionClaimTokenStorageLib.fetch().whitelist.add(account)) revert AlreadyWhitelisted(account);
        emit WhitelistAdded(account);
    }

    /// @inheritdoc IRedemptionClaimToken
    function removeFromWhitelist(address account) external override onlyRole(AssetCxRolesLib.WHITELIST_MANAGER_ROLE) {
        if (!RedemptionClaimTokenStorageLib.fetch().whitelist.remove(account)) revert NotInWhitelist(account);
        emit WhitelistRemoved(account);
    }

    // ============ Whitelist views ============

    /// @inheritdoc IRedemptionClaimToken
    function getWhitelist() external view override returns (address[] memory) {
        return RedemptionClaimTokenStorageLib.fetch().whitelist.values();
    }

    /// @inheritdoc IRedemptionClaimToken
    function isWhitelisted(address account) external view override returns (bool) {
        return RedemptionClaimTokenStorageLib.fetch().whitelist.contains(account);
    }

    /// @inheritdoc IRedemptionClaimToken
    function whitelistLength() external view override returns (uint256) {
        return RedemptionClaimTokenStorageLib.fetch().whitelist.length();
    }

    // ============ Pause ============

    /// @inheritdoc IRedemptionClaimToken
    function pause() external override onlyRole(AssetCxRolesLib.PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IRedemptionClaimToken
    function unpause() external override afterDelay onlyRole(AssetCxRolesLib.PAUSER_ROLE) {
        _unpause();
    }

    // ============ Timelock ============

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
    ///      (notably `LIQUIDATION_MODULE_ROLE`) cannot change without a queued proposal.
    ///      Grants of `PAUSER_ROLE` are exempt so a fresh pauser can be onboarded
    ///      without delay during an incident.
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

    // ============ Internal ============

    /**
     * @dev Enforces the whitelist on every transfer (and the pause via
     *      {ERC20PausableUpgradeable}). Each non-zero endpoint must be whitelisted;
     *      the `address(0)` endpoint of a mint/burn is exempt so that minting to, and
     *      burning from, a whitelisted holder is permitted.
     */
    function _update(address from, address to, uint256 value) internal override(ERC20PausableUpgradeable) {
        RedemptionClaimTokenStorageLib.Storage storage $ = RedemptionClaimTokenStorageLib.fetch();
        if (from != address(0) && !$.whitelist.contains(from)) revert NotWhitelisted(from);
        if (to != address(0) && !$.whitelist.contains(to)) revert NotWhitelisted(to);
        super._update(from, to, value);
    }

    /// @dev Only `DEFAULT_ADMIN_ROLE` can authorize UUPS upgrades, and only after
    ///      the upgrade selector has matured through the timelock.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) afterDelay {
        emit RedemptionClaimTokenUpgradeAuthorized(newImplementation, msg.sender);
    }

    /// @notice Prevents removing the last ROLE_ADMIN, which would leave the contract
    ///         permanently without an admin.
    /// @dev Both {revokeRole} and {renounceRole} funnel through this hook, so this single
    ///      override blocks self-revoke, self-renounce, and admin-revokes-admin alike. With
    ///      multiple ROLE_ADMINs any one of them (including the caller) can still be removed.
    function _revokeRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        if (role == DEFAULT_ADMIN_ROLE && getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1) {
            revert CannotRemoveLastRoleAdmin();
        }
        return super._revokeRole(role, account);
    }
}
