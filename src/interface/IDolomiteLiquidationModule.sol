// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IDolomiteMargin} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomiteMargin.sol";
import {IConcreteMerchant} from "./IConcreteMerchant.sol";
import {IRedemptionClaimToken} from "./IRedemptionClaimToken.sol";
import {DolomiteLiquidationModuleStorageLib} from "../lib/DolomiteLiquidationModuleStorageLib.sol";

/// @title IDolomiteLiquidationModule
/// @author Blueprint Finance
/// @notice External surface, events and errors of the DolomiteLiquidationModule contract.
/// @dev Inherited by `DolomiteLiquidationModule` so all members stay addressable as
///      `DolomiteLiquidationModule.<Member>` (e.g. in tests and integrations).
interface IDolomiteLiquidationModule {
    // ─────────────────────────────── Structs ──────────────────────────────

    /// @notice Initialization parameters (struct avoids stack pressure in `initialize`).
    /// @param admin              Address that receives `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE`.
    /// @param liquidator         Address that receives `LIQUIDATOR_ROLE`. Pass `address(0)`
    ///                           to grant it later through `grantRole`.
    /// @param dolomiteMargin     The DolomiteMargin core contract.
    /// @param redemptionClaimToken         The RedemptionClaimToken this module mints/burns.
    /// @param merchant           The ConcreteMerchant used to redeem the extracted BTCcx.
    /// @param debtToken          The debt token of the market pair (e.g. USD1).
    /// @param collateralRatioWad RedemptionClaimToken collateral ratio, in WAD (e.g. 0.98e18).
    /// @param bufferWad          Collateral over-withdrawal buffer, in WAD (e.g. 0.05e18).
    /// @param liquidatableLtvWad Borrow-position LTV, in WAD, from which a plain `LIQUIDATOR_ROLE`
    ///                           caller may liquidate (e.g. 0.8e18).
    /// @param timelock           Address of the Timelock contract. Pass `address(0)` to deploy
    ///                           without timelock enforcement (configurable until activated).
    struct InitParams {
        address admin;
        address liquidator;
        address dolomiteMargin;
        address redemptionClaimToken;
        address merchant;
        address debtToken;
        uint256 collateralRatioWad;
        uint256 bufferWad;
        uint256 liquidatableLtvWad;
        address timelock;
    }

    // ─────────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();
    /// @notice Thrown when a required amount argument is zero.
    error ZeroAmount();
    /// @notice Thrown when a WAD ratio parameter is outside its allowed range.
    error InvalidRatio(uint256 ratioWad);
    /// @notice Thrown when acting on a redemption id that is unknown or already finalized.
    error LiquidationNotActive(uint256 redemptionId);
    /// @notice Thrown when the debt to take over exceeds the borrow position's outstanding debt.
    error DebtAmountExceedsPositionDebt(uint256 debtAmountToLiquidate, uint256 positionDebt);
    /// @notice Thrown when a full close does not satisfy the unwind invariant: all supplied
    ///         RedemptionClaimToken has been withdrawn
    ///         (`redemptionClaimTokenWithdrawn == redemptionClaimTokenSupplied`).
    error LiquidationInvariantViolated(uint256 redemptionId);
    /// @notice Thrown when trying to remove the last default admin.
    error CannotRemoveLastRoleAdmin();
    /// @notice Thrown when the module lacks Dolomite local-operator rights on the
    ///         position owner's accounts.
    error NotDolomiteOperator(address positionOwner);
    /// @notice Thrown when the module holds a non-zero RedemptionClaimToken balance outside of an
    ///         in-flight Dolomite operation. The module must never custody the token between the
    ///         two liquidation steps: every minted token is supplied straight into its temporary
    ///         position and only briefly withdrawn (then burned) during finalization. A non-zero
    ///         balance would let one liquidation's burn consume another's collateral.
    error UnexpectedRedemptionClaimBalance(uint256 balance);
    /// @notice Thrown when a `LIQUIDATOR_ROLE` caller without `DEFAULT_ADMIN_ROLE` targets a
    ///         borrow position whose LTV is still below the configured liquidatable band.
    error PositionNotLiquidatable(uint256 ltvWad, uint256 liquidatableLtvWad);

    // ─────────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when a liquidation collateral swap is initiated.
    /// @param redemptionId       Id tracking this liquidation until finalization.
    /// @param positionOwner      Owner of the Dolomite borrow position.
    /// @param accountNumber      Account number of the borrow position (position A).
    /// @param tempAccountNumber  Module-owned temporary position backed by the RedemptionClaimToken (position B).
    /// @param debtMoved          Debt-token amount moved from position A onto position B.
    /// @param redemptionClaimTokenSupplied RedemptionClaimToken minted and supplied as position B collateral.
    /// @param collateralRedeemed Collateral (BTCcx) withdrawn from position A and sent to redemption.
    event LiquidationInitiated(
        uint256 indexed redemptionId,
        address indexed positionOwner,
        uint256 indexed accountNumber,
        uint256 tempAccountNumber,
        uint256 debtMoved,
        uint256 redemptionClaimTokenSupplied,
        uint256 collateralRedeemed
    );

    /// @notice Emitted on a partial finalization that repays part of the temporary position's
    ///         debt without fully closing it (the liquidation stays active).
    /// @param redemptionId      Id of the liquidation.
    /// @param positionOwner     Owner of the original Dolomite borrow position (position A).
    /// @param accountNumber     Account number of the original borrow position (position A).
    /// @param debtRepaid        Debt-token amount repaid into the temporary position on this call.
    /// @param redemptionClaimTokenBurned  RedemptionClaimToken released and burned on this call.
    /// @param totalDebtRepaid   Cumulative debt-token repaid into the temporary position so far.
    event LiquidationPartiallyFinalized(
        uint256 indexed redemptionId,
        address indexed positionOwner,
        uint256 indexed accountNumber,
        uint256 debtRepaid,
        uint256 redemptionClaimTokenBurned,
        uint256 totalDebtRepaid
    );

    /// @notice Emitted when a liquidation is fully finalized: the temporary position is cleared,
    ///         the last RedemptionClaimToken burned and any surplus applied/refunded.
    /// @param redemptionId      Id of the finalized liquidation.
    /// @param positionOwner     Owner of the original Dolomite borrow position (position A).
    /// @param accountNumber     Account number of the original borrow position (position A).
    /// @param tempDebtRepaid    Debt-token amount used to clear the temporary position on this call.
    /// @param surplusApplied    Debt-token surplus applied to the remaining position-A debt.
    /// @param refunded          Debt-token remainder returned to the caller.
    /// @param redemptionClaimTokenBurned  RedemptionClaimToken withdrawn from Dolomite and burned on this call.
    event LiquidationFinalized(
        uint256 indexed redemptionId,
        address indexed positionOwner,
        uint256 indexed accountNumber,
        uint256 tempDebtRepaid,
        uint256 surplusApplied,
        uint256 refunded,
        uint256 redemptionClaimTokenBurned
    );

    /// @notice Emitted when the RedemptionClaimToken collateral ratio is updated.
    /// @param collateralRatioWad New ratio, in WAD.
    event CollateralRatioUpdated(uint256 collateralRatioWad);

    /// @notice Emitted when the collateral over-withdrawal buffer is updated.
    /// @param bufferWad New buffer, in WAD.
    event BufferUpdated(uint256 bufferWad);

    /// @notice Emitted when the liquidatable LTV band is updated.
    /// @param liquidatableLtvWad New band, in WAD.
    event LiquidatableLtvUpdated(uint256 liquidatableLtvWad);

    /// @notice Emitted when a UUPS upgrade of this contract is authorized.
    /// @param newImplementation Implementation address the proxy is being upgraded to.
    /// @param authorizer        Account that satisfied the role + timelock checks.
    event DolomiteLiquidationModuleUpgradeAuthorized(address indexed newImplementation, address indexed authorizer);

    // ────────────────────────────── Functions ─────────────────────────────

    /**
     * @notice Initiates a liquidation collateral swap on a Dolomite borrow position.
     * @dev Only `LIQUIDATOR_ROLE`. Atomically:
     *      1. mints `debtAmountToLiquidate / collateralRatio` RedemptionClaimToken;
     *      2. supplies it as collateral of a fresh module-owned temporary position and moves
     *         `debtAmountToLiquidate` of the position's debt onto that temporary position
     *         (the debt token never leaves Dolomite);
     *      3. withdraws collateral (BTCcx) worth `debtAmountToLiquidate × (1 + buffer)` from
     *         the borrow position and initiates its redemption via the merchant.
     *      Requires the module to be a Dolomite local operator for `positionOwner`. Unless the
     *      caller also holds `DEFAULT_ADMIN_ROLE`, the position's LTV must have reached
     *      {liquidatableLtvWad}.
     * @param positionOwner          Owner of the Dolomite borrow position.
     * @param accountNumber          Account number of the borrow position.
     * @param debtAmountToLiquidate  Debt-token (e.g. USD1) amount to take over.
     * @param receiver               Address that takes delivery of the redeemed BTCcx in debt token (the
     *                               merchant redemption is recorded against it and settled
     *                               off-chain: BTC → debt-token leg.)
     * @return redemptionId          Id used to finalize this liquidation.
     */
    function initiateLiquidationCollateralSwap(
        address positionOwner,
        uint256 accountNumber,
        uint256 debtAmountToLiquidate,
        address receiver
    ) external returns (uint256 redemptionId);

    /**
     * @notice Finalizes a liquidation, in one call or across several partial calls: repays the
     *         temporary position, burns the released RedemptionClaimToken and, once fully repaid,
     *         applies any surplus to the remaining borrow-position debt.
     * @dev Only `LIQUIDATOR_ROLE`. Pulls `debtTokenAmount` from the caller (proceeds of the
     *      off-chain BTC → debt-token sale). Supports partial repayment — `debtTokenAmount` may be
     *      less than the temporary position's outstanding debt. Atomically:
     *      - PARTIAL (`debtTokenAmount` < temp debt): repays `debtTokenAmount`, withdraws and burns
     *        the RedemptionClaimToken the temporary position holds above what backs its remaining
     *        debt at the configured ratio — so the position is left at the collateralization it was
     *        opened at, absorbing any interest accrued meanwhile — and leaves the liquidation
     *        active. Reverts if
     *        the residual debt falls below Dolomite's minimum borrow value (size the closing tranche
     *        off-chain to clear it in full).
     *      - FULL (`debtTokenAmount` ≥ temp debt): clears the debt, withdraws and burns all
     *        remaining RedemptionClaimToken, applies any surplus to the borrow position's remaining
     *        debt (refunding the rest to the caller), and marks the liquidation finalized.
     * @param redemptionId    Id returned by {initiateLiquidationCollateralSwap}.
     * @param debtTokenAmount Debt-token amount supplied by the caller.
     */
    function finalizeLiquidationAndRepay(uint256 redemptionId, uint256 debtTokenAmount) external;

    /**
     * @notice Updates the RedemptionClaimToken collateral ratio.
     * @dev Only `DEFAULT_ADMIN_ROLE`, after the timelock delay. Must be in (0, 1e18].
     * @param collateralRatioWad_ New ratio, in WAD (e.g. 0.98e18).
     */
    function setCollateralRatio(uint256 collateralRatioWad_) external;

    /**
     * @notice Updates the collateral over-withdrawal buffer.
     * @dev Only `DEFAULT_ADMIN_ROLE`, after the timelock delay. Must be ≤ 1e18.
     * @param bufferWad_ New buffer, in WAD (e.g. 0.05e18).
     */
    function setBuffer(uint256 bufferWad_) external;

    /**
     * @notice Updates the LTV from which a plain `LIQUIDATOR_ROLE` caller may liquidate a borrow
     *         position. Callers that also hold `DEFAULT_ADMIN_ROLE` are not subject to it.
     * @dev Only `DEFAULT_ADMIN_ROLE`, after the timelock delay. Must be in (0, 1e18].
     * @param liquidatableLtvWad_ New band, in WAD (e.g. 0.8e18).
     */
    function setLiquidatableLtv(uint256 liquidatableLtvWad_) external;

    /// @notice Pauses the liquidation entrypoints.
    /// @dev Only `PAUSER_ROLE`. Intentionally NOT timelock-gated.
    function pause() external;

    /// @notice Lifts the pause.
    /// @dev Only `PAUSER_ROLE`, and only after a timelock proposal has matured.
    function unpause() external;

    /// @notice Returns the liquidation record for `redemptionId`.
    function getLiquidation(uint256 redemptionId)
        external
        view
        returns (DolomiteLiquidationModuleStorageLib.Liquidation memory);

    /// @notice Returns the ids of the currently in-flight liquidations for a borrow position.
    /// @param positionOwner Owner of the Dolomite borrow position.
    /// @param accountNumber Account number of the borrow position.
    /// @return The redemption ids still active for `(positionOwner, accountNumber)` (unordered).
    function getLiquidationIds(address positionOwner, uint256 accountNumber) external view returns (uint256[] memory);

    /// @notice The DolomiteMargin core contract.
    function dolomiteMargin() external view returns (IDolomiteMargin);

    /// @notice The RedemptionClaimToken this module mints/burns.
    function redemptionClaimToken() external view returns (IRedemptionClaimToken);

    /// @notice The ConcreteMerchant used to redeem the extracted collateral.
    function merchant() external view returns (IConcreteMerchant);

    /// @notice The collateral token being liquidated/redeemed (BTCcx / AssetCX).
    function collateralToken() external view returns (address);

    /// @notice The debt token of the market pair (e.g. USD1).
    function debtToken() external view returns (address);

    /// @notice RedemptionClaimToken collateral ratio, in WAD.
    function collateralRatioWad() external view returns (uint256);

    /// @notice Collateral over-withdrawal buffer, in WAD.
    function bufferWad() external view returns (uint256);

    /// @notice LTV, in WAD, from which a plain `LIQUIDATOR_ROLE` caller may liquidate.
    function liquidatableLtvWad() external view returns (uint256);

    /// @notice Current LTV of a borrow position, in WAD; `type(uint256).max` when it supplies
    ///         nothing.
    /// @param positionOwner Owner of the Dolomite borrow position.
    /// @param accountNumber Account number of the borrow position.
    function positionLtvWad(address positionOwner, uint256 accountNumber) external view returns (uint256);
}
