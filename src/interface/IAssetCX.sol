// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/// @title IAssetCX
/// @notice External surface, events and errors of the AssetCX token contract.
/// @dev Inherited by `AssetCX` so all members stay addressable as
///      `AssetCX.<Member>` (e.g. in tests and integrations).
interface IAssetCX {
    // ─────────────────────────────── Errors ───────────────────────────────

    error AdminCannotBeZeroAddress();
    error ZeroAddress();
    /// @notice Thrown by {reinitializeV3} when an entry names an account that does not already
    ///         hold the role. Re-entering a non-holder would grant a live privilege rather than
    ///         repair bookkeeping, so the whole migration is rejected.
    error NotACurrentRoleHolder(bytes32 role, address account);
    /// @notice Thrown by {reinitializeV3} when the admin membership set it produced is not exactly
    ///         the caller — i.e. a temporary admin survived the sequence, or another admin is
    ///         already enumerated, such as one granted through {grantRole} between the
    ///         implementation upgrade and a separate {reinitializeV3} call.
    /// @dev Only enumerated admins are visible to this check. Other `DEFAULT_ADMIN_ROLE` holders
    ///      granted under the non-enumerable implementation are not detected: they keep the role
    ///      but stay unenumerated.
    /// @param adminCount      Members enumerated for `DEFAULT_ADMIN_ROLE` on exit.
    /// @param enumeratedAdmin The sole member when `adminCount` is 1, otherwise `address(0)`.
    error AdminBackfillMismatch(uint256 adminCount, address enumeratedAdmin);
    /// @notice Thrown by {reinitializeV3} when a temporary admin already holds
    ///         `DEFAULT_ADMIN_ROLE` (including the caller itself) or both temporaries are the same
    ///         address. Accepting an existing admin would revoke it as a side effect of the migration.
    /// @param tempAdmin The rejected temporary admin address.
    error InvalidTempAdmin(address tempAdmin);
    /// @notice Thrown by every revoke or renounce of `DEFAULT_ADMIN_ROLE` while
    ///         `getRoleMemberCount(DEFAULT_ADMIN_ROLE)` is one or less. The check reads only the
    ///         enumerated count, so it also blocks removing an admin that is not enumerated (for
    ///         example one granted under the non-enumerable implementation and not re-entered by
    ///         {reinitializeV3}), even when other admins hold the role. A count of `0` means
    ///         membership is still unknown because {reinitializeV3} has not run.
    error CannotRemoveLastRoleAdmin();

    // ─────────────────────────────── Events ───────────────────────────────

    /// @notice Emitted by {reinitializeV3} once per role, after that role's enumerable membership
    ///         set has been seeded.
    /// @param role        The role whose membership set was seeded.
    /// @param memberCount Members tracked for `role` once the seeding finished, so duplicate
    ///                    entries in the supplied list are not double-counted. Cross-check this
    ///                    against the holder set reconstructed from the proxy's role event log.
    event RoleMembershipBackfilled(bytes32 indexed role, uint256 memberCount);

    /// @notice Emitted when a UUPS upgrade of this contract is authorized.
    /// @param newImplementation Implementation address that the proxy is being upgraded to.
    /// @param authorizer        Account that satisfied the role + timelock checks for the upgrade.
    event AssetCxUpgradeAuthorized(address indexed newImplementation, address indexed authorizer);

    // ────────────────────────────── Functions ──────────────────────────────

    /**
     * @notice Initializes the token
     * @param name_     Token name
     * @param symbol_   Token symbol
     * @param admin     Address that will receive the default admin role
     * @param timelock_ Address of the Timelock contract. Pass `address(0)` to
     *                  deploy without timelock enforcement (timelock can be
     *                  configured later until enforcement is activated).
     */
    function initialize(string memory name_, string memory symbol_, address admin, address timelock_) external;

    /**
     * @notice One-shot post-upgrade migration for proxies upgraded from a pre-1.3.0 implementation.
     * @dev Grants `PAUSER_ROLE` to the supplied addresses under the new role model.
     *
     *      Marked `reinitializer(2)` so it runs at most once and only after a prior
     *      `initialize` bumped the initializable version to `1`. The intended invocation
     *      is to bundle it into the upgrade itself via
     *      `proxy.upgradeToAndCall(newImpl, abi.encodeCall(this.reinitializeV2, (pausers)))`.
     *
     *      Proxies already on 1.3.0 have run this and are at version `2`; they go straight to
     *      {reinitializeV3}, which is what seeds the enumerable membership sets.
     *
     * @param pausers Addresses to grant `PAUSER_ROLE`. Zero addresses are skipped.
     */
    function reinitializeV2(address[] calldata pausers) external;

    /**
     * @notice One-shot migration that seeds the enumerable role membership sets on a proxy whose
     *         roles were granted by a non-enumerable implementation.
     * @dev Adding `AccessControlEnumerableUpgradeable` to a live proxy is storage-safe (the
     *      extension keeps its members under its own ERC-7201 namespace) but the sets start
     *      empty while `hasRole` keeps reporting the pre-upgrade holders. Every entry is
     *      therefore internally revoked and immediately re-granted in the same call, because
     *      `_grantRole` short-circuits for an account that already holds the role and so never
     *      reaches the membership set.
     *
     *      `DEFAULT_ADMIN_ROLE` is handled separately, because the drop-and-re-grant used for the
     *      other roles would trip the unconditional last-admin guard in `_revokeRole` while the
     *      admin set still reads empty. Instead `tempAdminA` and `tempAdminB` are granted the role
     *      to lift the member count to two, the caller is then dropped and re-granted, and both
     *      temporaries are removed again — all within this one internal call, so neither temporary
     *      address is ever usable and the exit assertion proves both are gone.
     *
     *      Three properties make this safe to run against a live deployment:
     *
     *      1. Each non-admin entry must already satisfy `hasRole`, so the migration cannot change
     *         who is privileged — it can only re-enter existing holders. A typo reverts the
     *         upgrade instead of minting a new merchant.
     *      2. It is internal-only and atomic. The caller re-enters its own `DEFAULT_ADMIN_ROLE`
     *         without passing through the external role-admin checks, so there is no window in
     *         which the admin is unprivileged. It also bypasses the timelock gate on the public
     *         {grantRole}, which the upgrade proposal itself already covers.
     *      3. The admin set is asserted on exit: exactly one member, and that member is the
     *         caller. Anything else — including a surviving temporary admin — reverts the upgrade.
     *
     *      The caller is treated as the only `DEFAULT_ADMIN_ROLE` holder. Any other admin keeps
     *      its role but stays unenumerated, and this function cannot be re-run to fix that.
     *
     *      One list per remaining role, each holding every current member of that role. Intended
     *      invocation is bundled into the upgrade itself: `proxy.upgradeToAndCall(newImpl,
     *      abi.encodeCall(this.reinitializeV3, (tempA, tempB, merchants, pausers)))`.
     *
     *      WARNING: `reinitializer(3)` requires the proxy's initializable version to still be below `3`,
     *      i.e. `initialize` has run and {reinitializeV2} may or may not have. Confirm this before calling
     *      (low 8 bytes of slot
     *      `0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00`); a proxy already
     *      past version 3 reverts with `InvalidInitialization` and needs the version bumped here
     *      instead.
     *
     *      Completeness cannot be verified on-chain — the contract has no way to enumerate
     *      holders, which is the problem being fixed. Build the lists from the proxy's
     *      `RoleGranted`/`RoleRevoked` history (the grants in {initialize} emit those events too)
     *      and verify them against the per-role {RoleMembershipBackfilled} events plus
     *      `getRoleMemberCount`.
     *
     * @param tempAdminA Throw-away address used to hold `DEFAULT_ADMIN_ROLE` for the duration of
     *                   the caller's re-entry. Must be non-zero, distinct from `tempAdminB` and
     *                   from the caller, and must not already hold `DEFAULT_ADMIN_ROLE`;
     *                   otherwise the call reverts.
     * @param tempAdminB Second throw-away address, under the same constraints. Two are needed so
     *                   the count still clears the last-admin guard while the first is being
     *                   removed.
     * @param merchants  Every current `MERCHANT_ROLE` holder.
     * @param pausers    Every current `PAUSER_ROLE` holder.
     *
     *      Either list may be empty when the role has no holders, and duplicates within a list are
     *      tolerated (re-entering the same account twice is idempotent).
     */
    function reinitializeV3(
        address tempAdminA,
        address tempAdminB,
        address[] calldata merchants,
        address[] calldata pausers
    ) external;

    /**
     * @notice Mints tokens to merchant
     * @param amount Amount of tokens to mint
     * @dev Only addresses with MERCHANT_ROLE can call this function
     */
    function mint(uint256 amount) external;

    /**
     * @notice Burns tokens from merchant
     * @param amount Amount of tokens to burn
     * @dev Only addresses with MERCHANT_ROLE can call this function
     */
    function burn(uint256 amount) external;

    /**
     * @notice Pauses ERC-20 transfers, mints and burns.
     * @dev Only `PAUSER_ROLE` can pause. Intentionally NOT timelock-gated
     */
    function pause() external;

    /**
     * @notice Lifts the pause.
     * @dev Only `PAUSER_ROLE`, and only after a TIER_2 timelock proposal has
     *      matured.
     */
    function unpause() external;
}
