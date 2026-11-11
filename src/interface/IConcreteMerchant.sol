// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {AssetCX} from "../AssetCX.sol";

/// @title IConcreteMerchant
/// @notice External surface, events and errors of the ConcreteMerchant contract.
/// @dev Inherited by `ConcreteMerchant` so all members stay addressable as
///      `ConcreteMerchant.<Member>` (e.g. in tests and integrations).
interface IConcreteMerchant {
    // ─────────────────────────────── Errors ───────────────────────────────

    error InvalidAddress();
    error UnknownUser(bytes32 userId);
    error ClaimAmountMismatch(uint256 expected, uint256 actual);
    error WrongRedemptionAmount(uint256 requested, uint256 available);
    error NoPendingYieldForNonce(uint256 nonce);
    error YieldConfigNotSet();
    error InvalidAmount();
    error YieldNonceAlreadyPending(uint256 nonce);
    error InvalidNonce(uint256 expected, uint256 provided);
    error InvalidVaultAsset();
    error StrategyVaultMismatch(address expected, address provided);
    error TxHashAlreadyUsed(bytes32 txHash);
    error InvalidTxHash();
    /// @notice Thrown when attempting to mutate a vault's yield config while any
    ///         whitelisted yield token still has pending unsettled accrual for that vault.
    error PendingYieldForVault(address vault, address yieldToken, uint256 pendingAmount);
    error UserHasActiveDeposits(bytes32 userId, uint256 activeShares);
    error InsufficientShareBalance(uint256 required, uint256 available);
    error ZeroAddress();
    error UserAccountAlreadyUsed(address account);
    error YieldTokenNotWhitelisted(address token);
    error YieldTokenAlreadyWhitelisted(address token);
    error YieldTokenWhitelistFull(uint256 cap);
    /// @notice Thrown when trying to de-whitelist a token that still has unsettled
    ///         pending accruals on any vault. The token must drain to zero pending
    ///         (across all vaults) before it can be removed from the whitelist.
    error PendingYieldForToken(address token, uint256 pendingAmount);
    /// @notice No longer thrown. It was raised by the 1.3.0 `reinitializeV2` migration, removed
    ///         in 1.4.0, when the upgrading proxy still had pre-V2 pending yield queued under the
    ///         deprecated cross-token aggregate. Kept only so the error stays in the ABI.
    error PendingLegacyYieldOnUpgrade(uint256 deprecatedPendingAmount);
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

    event PendingQCRedemption(
        bytes32 indexed userId, uint256 indexed epochID, uint256 amount, uint256 userPending, uint256 totalPending
    );
    event QCRedemptionFinalized(
        bytes32 indexed userId, uint256 amount, uint256 userPending, uint256 totalPending, bytes32 indexed txHash
    );
    /// @notice Emitted when a yield accrual is initiated by a strategy.
    event PendingYieldAccrual(
        uint256 indexed nonce,
        address indexed yieldToken,
        address indexed vault,
        uint256 amount,
        uint256 totalPendingForToken,
        uint256 totalPendingForVaultByToken
    );
    /// @notice Emitted when a previously initiated yield accrual is finalized.
    event YieldAccrualFinalized(
        uint256 indexed nonce,
        address yieldToken,
        address indexed vault,
        uint256 pendingAmountInYieldToken,
        uint256 actualAmountInAsset,
        bytes32 indexed txHash
    );
    /// @notice Emitted whenever the whitelisted status of a yield token changes.
    event YieldTokenWhitelisted(address indexed token, bool whitelisted);
    event MintAndDeposit(bytes32 indexed userId, uint256 amount, bytes32 indexed txHash);
    event AssetCxRedemption(address indexed receiver, uint256 amount, uint256 totalPending);
    event AssetCxRedemptionFinalized(
        address indexed receiver, uint256 amount, uint256 remainingPending, bytes32 indexed txHash
    );
    event VaultYieldConfigSet(address indexed vault, address indexed strategy, address indexed multisig);
    event UserAccountSet(bytes32 indexed userId, address indexed userAccount);
    event UserVaultSet(bytes32 indexed userId, address indexed vault);
    event UserVaultRemoved(bytes32 indexed userId);
    event UserDataSet(bytes32 indexed userId, bytes data);
    event EmergencyUserAccountMigrated(
        bytes32 indexed userId, address indexed oldAccount, address indexed newAccount, uint256 sharesMigrated
    );

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
    event MerchantUpgradeAuthorized(address indexed newImplementation, address indexed authorizer);

    // ──────────────────────── Initialization ────────────────────────

    /**
     * @notice Initializes the merchant
     * @dev The yield-token whitelist is left empty at deployment.
     * @param admin         Address that receives `DEFAULT_ADMIN_ROLE` and the initial
     *                      `MERCHANT_MANAGER_ROLE` grant.
     * @param assetCX_      The AssetCX token contract this merchant mints/burns.
     * @param assetCXVault_ Default ERC-4626 vault used when a user has no override.
     * @param timelock_     Address of the Timelock contract. Pass `address(0)` to
     *                      deploy without timelock enforcement (timelock can be
     *                      configured later until enforcement is activated).
     */
    function initialize(address admin, AssetCX assetCX_, IERC4626 assetCXVault_, address timelock_) external;

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
     *      Intended invocation: `proxy.upgradeToAndCall(newImpl,
     *      abi.encodeCall(this.reinitializeV3, (tempA, tempB, managers, operators, pausers)))`.
     *
     *      The exit check ({AdminBackfillMismatch}) only sees enumerated admins. It catches another
     *      admin that is already enumerated, such as one granted through {grantRole} between the
     *      implementation upgrade and a separate {reinitializeV3} call. It does not detect other
     *      `DEFAULT_ADMIN_ROLE` holders granted under the non-enumerable implementation: they keep
     *      the role but stay unenumerated, and this function cannot be re-run to fix that.
     *
     *
     * @param tempAdminA       Throw-away address used to hold `DEFAULT_ADMIN_ROLE` for the
     *                         duration of the caller's re-entry. Must be non-zero, distinct from
     *                         `tempAdminB` and from the caller, and must not already hold
     *                         `DEFAULT_ADMIN_ROLE`; otherwise the call reverts.
     * @param tempAdminB       Second throw-away address, under the same constraints. Two are
     *                         needed so the count still clears the last-admin guard while the
     *                         first is being removed.
     * @param merchantManagers Every current `MERCHANT_MANAGER_ROLE` holder.
     * @param operators        Every current `OPERATOR_ROLE` holder.
     * @param pausers          Every current `PAUSER_ROLE` holder.
     *
     *      Any list may be empty when the role has no holders, and duplicates within a list are
     *      tolerated (re-entering the same account twice is idempotent).
     */
    function reinitializeV3(
        address tempAdminA,
        address tempAdminB,
        address[] calldata merchantManagers,
        address[] calldata operators,
        address[] calldata pausers
    ) external;

    // ──────────────────────────── Pausing ────────────────────────────

    /**
     * @notice Pauses operational user-facing flows (mint/redeem/yield).
     * @dev Only `PAUSER_ROLE` can pause. Intentionally NOT timelock-gated
     */
    function pause() external;

    /**
     * @notice Lifts the pause.
     * @dev Only `PAUSER_ROLE`, and only after a TIER_2 timelock proposal has
     *      matured.
     */
    function unpause() external;

    // ──────────────────────── User management ────────────────────────

    /**
     * @notice Sets the account address for a given user ID
     * @dev Links an on-chain address to an off-chain user ID for receiving vault shares
     * @dev WARNING: User must have no active deposits (mintedVaultShares == 0) to modify this mapping.
     *      If user has existing deposits, they must fully withdraw before changing their account.
     * @dev An on-chain address can only be bound to one userId at a time. When this function rotates
     *      `userId` away from a previously-bound address, that previous address is automatically
     *      cleared from `usedUserAccounts`
     *      {emergencyMigrateUserAccount} path does NOT free the rotated-out address — it stays
     *      flagged so a compromised address can never be revived.
     * @param userId The unique identifier for the user
     * @param user The on-chain address to associate with the user ID
     */
    function setUserAccount(bytes32 userId, address user) external;

    /**
     * @notice Sets a custom vault for a specific user
     * @dev Allows overriding the default vault for individual users
     * @dev WARNING: User must have no active deposits (mintedVaultShares == 0) to modify this mapping.
     *      If user has existing deposits, they must fully withdraw before changing their vault.
     * @param userId The unique identifier for the user
     * @param vault The custom vault to use for this user's deposits
     */
    function setUserVault(bytes32 userId, IERC4626 vault) external;

    /**
     * @notice Removes the custom vault override for a user, reverting them to the default vault
     * @dev After removal, future deposits for this user will use the default assetCXVault
     * @dev WARNING: User must have no active deposits (mintedVaultShares == 0) to modify this mapping.
     *      If user has existing deposits, they must fully withdraw before removing their vault override.
     * @param userId The unique identifier for the user
     */
    function removeUserVault(bytes32 userId) external;

    /**
     * @notice Stores arbitrary custodian-specific data for a user.
     * @dev Opaque `bytes` blob — the merchant performs no validation on shape
     *      or contents. Interpretation is left entirely to the
     *      off-chain integration. Pass `""` to clear the slot.
     * @param userId The unique identifier for the user.
     * @param data   Arbitrary bytes payload to associate with `userId`.
     */
    function setUserData(bytes32 userId, bytes calldata data) external;

    /**
     * @notice Emergency function to migrate a user's account to a new address
     * @dev WARNING: This is an emergency-only function with significant implications:
     *      - Migrates the user's vault shares from the old account to the new account
     *      - Old account will be removed from the vault whitelist (effectively blacklisted)
     *      - New account will be added to the vault whitelist
     *      - Whitelist hook is fetched automatically from the user's vault
     *      - Assumes pending withdrawals and deposits have been settled before calling
     *      - Validates migrated vaultShares equal totalMintedShares (no pending claims)
     *      - Requires prior approval of vault shares from old account to this contract
     *      - Should only be used in emergency situations such as compromised accounts or lost access
     * @param userId The unique identifier for the user
     * @param newAccount The new on-chain address to migrate the user's shares to
     */
    function emergencyMigrateUserAccount(bytes32 userId, address newAccount) external;

    // ──────────────────────── Merchant operations ────────────────────────

    /**
     * @notice Mints and deposits the assetCX tokens for a given user
     * @dev mints the assetCX tokens backed by a QC deposit and deposits them into the assetCX vault
     * @param userId The ID of the user
     * @param amount The amount of assets to mint and deposit
     * @param txHash The QC transaction hash, used to prevent replay
     * @return shares The amount of vault shares minted to the user's account
     */
    function mintAndDeposit(bytes32 userId, uint256 amount, bytes32 txHash) external returns (uint256 shares);

    /**
     * @notice Authorises (or revokes) a yield token for use in {initiateYieldAccrual}.
     * @dev Idempotency: reverts with {YieldTokenAlreadyWhitelisted} / {YieldTokenNotWhitelisted}
     *
     *      Removal invariant: a token can only be removed when its cross-vault pending
     *      balance is zero. This guarantees the whitelist remains a complete index of
     *      every token with active pending — which {setVaultYieldConfig} relies on.
     *
     *      Cap: the set is hard-capped at `ConcreteMerchant.MAX_WHITELISTED_YIELD_TOKENS` entries.
     * @param token       The ERC-20 to flip.
     * @param whitelisted New whitelist state.
     */
    function setYieldTokenWhitelisted(address token, bool whitelisted) external;

    /**
     * @notice Sets the yield configuration for a specific vault
     * @dev Reverts if ANY whitelisted yield token still has non-zero pending accrual
     *      for `vault`.
     * @param vault The address of the vault
     * @param strategy_ The address of the strategy
     * @param yieldMultisig_ The yield multisig that receives yield tokens in
     *        {initiateYieldAccrual}. Stored independently of the strategy's own multisig
     *        (`IMultisigStrategy.getMultiSig()`); the two are not required to match and are not
     *        compared.
     */
    function setVaultYieldConfig(address vault, address strategy_, address yieldMultisig_) external;

    /**
     * @notice Claims the vault withdrawal for a given user and epoch
     * @dev claims the withdrawal from the assetCX vault and updates the pending redemption accounting
     * @dev burns the assetCX tokens awaiting qc redemption
     * @param userId The ID of the user
     * @param epochID The epoch ID of the withdrawal
     * @return amountClaimed The amount of assetCX claimed from the vault and burned
     */
    function claimVaultWithdrawal(bytes32 userId, uint256 epochID) external returns (uint256 amountClaimed);

    /**
     * @notice Finalizes the assetCX QC redemption for a given user
     * @dev updates the pending redemption accounting
     * @param userId The ID of the user
     * @param amount The amount of assets to redeem
     * @param txHash The QC transaction hash, used to prevent replay
     */
    function finalizeQCRedemption(bytes32 userId, uint256 amount, bytes32 txHash) external;

    /**
     * @notice Transfers the yield to the yield multisig pending swap to ASSET and updates the pending yield
     * @dev Invoked by the strategy contract.
     *
     *      The nonce sequence is continuous across ALL yield tokens — i.e. a single
     *      monotonically increasing counter that the strategy must align with via
     *      {getNextYieldNonce}, regardless of which token is being accrued.
     * @param vault              The vault this accrual is attributed to.
     * @param yieldToken         ERC-20 of the yield. Must be whitelisted.
     * @param amountInYieldToken The amount of `yieldToken` to route to the yield multisig.
     * @param nonce              The expected next yield nonce.
     */
    function initiateYieldAccrual(address vault, address yieldToken, uint256 amountInYieldToken, uint256 nonce) external;

    /**
     * @notice Finalizes the yield accrual for a given nonce
     * @dev Resolves the yield token from the per-nonce record set during initiation so
     *      operators do not need to remember which token any given nonce was paid in.
     *
     * @param vault         The address of the vault this yield accrual is for
     * @param nonce         The nonce of the yield accrual
     * @param amountInAsset The amount of yield to finalize, denominated in assetCX
     * @param txHash        The QC transaction hash, used to prevent replay
     */
    function finalizeYieldAccrual(address vault, uint256 nonce, uint256 amountInAsset, bytes32 txHash) external;

    /**
     * @notice Redeems assetCX tokens by transferring them from the sender and burning them
     * @dev Transfers assetCX from msg.sender, burns them, and records the redemption amount per receiver
     * @param amount The amount of assetCX tokens to redeem
     * @param receiver The address that will receive the redemption (recorded in storage)
     */
    function redeem(uint256 amount, address receiver) external;

    /**
     * @notice Finalizes the assetCX redemption for a given receiver
     * @dev Subtracts the amount from the pending redemption storage for the receiver
     * @param receiver The address of the receiver
     * @param amount The amount to finalize
     * @param txHash The transaction hash to prevent replay
     */
    function finalizeAssetCxRedemption(address receiver, uint256 amount, bytes32 txHash) external;

    // ──────────────────────────── Views ────────────────────────────

    /// @notice The AssetCX token this merchant mints and burns.
    function assetCX() external view returns (AssetCX);

    /// @notice Default ERC-4626 vault used when a user has no vault override.
    function assetCXVault() external view returns (IERC4626);

    /// @notice Vault override for `userId`, or `address(0)` when the default vault applies.
    function userVault(bytes32 userId) external view returns (IERC4626);

    /// @notice On-chain account currently bound to `userId`, or `address(0)` when unset.
    function getUserAccount(bytes32 userId) external view returns (address);

    /**
     * @notice Returns whether a given on-chain address has ever been bound to any userId.
     * @dev Set to `true` permanently the first time an address is assigned via
     *      {setUserAccount} or {emergencyMigrateUserAccount}. Once flagged, the address
     *      cannot be reused for any user.
     * @param user The on-chain address to check.
     */
    function isUserAccountUsed(address user) external view returns (bool);

    /// @notice Custodian-specific data blob stored for `userId` via {setUserData}.
    function userData(bytes32 userId) external view returns (bytes memory);

    /// @notice Cumulative assetCX minted for `userId` via {mintAndDeposit}.
    function totalMinted(bytes32 userId) external view returns (uint256);

    /// @notice Cumulative assetCX burned for `userId` via {claimVaultWithdrawal}.
    function totalBurned(bytes32 userId) external view returns (uint256);

    /// @notice Vault shares currently attributed to `userId`'s deposits.
    function mintedVaultShares(bytes32 userId) external view returns (uint256);

    /// @notice Pending QC redemption amount for `userId`.
    function pendingQCRedemption(bytes32 userId) external view returns (uint256);

    /// @notice Total pending QC redemption amount across all users.
    function totalPendingQCRedemption() external view returns (uint256);

    /// @notice Reports whether `token` is currently authorised for yield accrual.
    function isYieldTokenWhitelisted(address token) external view returns (bool);

    /// @notice Returns a snapshot of every currently-whitelisted yield token.
    /// @dev Bounded by `ConcreteMerchant.MAX_WHITELISTED_YIELD_TOKENS`. Order is not guaranteed.
    function getWhitelistedYieldTokens() external view returns (address[] memory);

    /// @notice Returns the yield token recorded for a given in-flight `nonce`.
    /// @dev Returns `address(0)` for nonces that have already been finalized OR that
    function yieldTokenForPendingYieldNonce(uint256 nonce) external view returns (address);

    /// @notice Cross-vault pending yield expressed in `token`.
    function totalPendingYieldByToken(address token) external view returns (uint256);

    /// @notice Pending yield for `vault` denominated in `token`.
    function pendingYieldForVaultByToken(address vault, address token) external view returns (uint256);

    /// @notice Strategy configured for `vault`, or `address(0)` when unset.
    function vaultYieldStrategy(address vault) external view returns (address);

    /// @notice Yield multisig configured for `vault`, or `address(0)` when unset.
    function vaultYieldMultisig(address vault) external view returns (address);

    /// @notice Next expected yield accrual nonce.
    function getNextYieldNonce() external view returns (uint256);

    /// @notice Pending yield amount (denominated in its yield token) recorded for `nonce`.
    function pendingYield(uint256 nonce) external view returns (uint256);

    /// @notice Pending assetCX redemption amount recorded for `receiver`.
    function pendingAssetCxRedemption(address receiver) external view returns (uint256);
}
