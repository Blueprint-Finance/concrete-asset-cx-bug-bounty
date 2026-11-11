// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/access/AccessControlUpgradeable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {TimelockIntegrationLib} from "@concrete-xyz/earn-v2-core/src/lib/TimelockIntegrationLib.sol";
import {ITimelockProtected} from "@concrete-xyz/earn-v2-core/src/interface/ITimelockProtected.sol";

import {IDolomiteMargin} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomiteMargin.sol";
import {IConcreteMerchant} from "../interface/IConcreteMerchant.sol";
import {IRedemptionClaimToken} from "../interface/IRedemptionClaimToken.sol";
import {IDolomiteLiquidationModule} from "../interface/IDolomiteLiquidationModule.sol";
import {AssetCxRolesLib} from "../lib/AssetCxRolesLib.sol";
import {DolomiteLiquidationModuleStorageLib} from "../lib/DolomiteLiquidationModuleStorageLib.sol";
import {DolomiteLiquidationLib} from "../lib/DolomiteLiquidationLib.sol";

/**
 * @title DolomiteLiquidationModule
 * @author Blueprint Finance
 * @notice Executes the RedemptionClaimToken-based liquidation flow on Dolomite for
 *         BTCcx-collateralized debt positions:
 *         - {initiateLiquidationCollateralSwap} mints the RedemptionClaimToken, supplies it as
 *           collateral of a fresh module-owned temporary position, moves the targeted debt
 *           onto it, withdraws the freed BTCcx and initiates its redemption via the merchant;
 *         - {finalizeLiquidationAndRepay} pulls the debt-token proceeds of the off-chain
 *           BTC → debt-token sale, clears the temporary position, burns the RedemptionClaimToken and
 *           applies any surplus to the remaining borrow-position debt.
 * @dev Upgradeable via the UUPS pattern (mirroring {RedemptionClaimToken}). Privileged
 *      configuration (`_authorizeUpgrade`, role grants other than `PAUSER_ROLE`,
 *      `setTimelock`, `unpause`, ratio/buffer setters) flows through the Timelock once
 *      enforcement is activated. Roles:
 *      - `DEFAULT_ADMIN_ROLE`: the main admin; administers all roles and authorizes upgrades.
 *      - `LIQUIDATOR_ROLE`: allowed to run the two liquidation entrypoints, and confined to
 *        positions that have reached `liquidatableLtvWad` unless it is also the admin.
 *      - `PAUSER_ROLE`: emergency stop; granted to the admin by default.
 *
 *      Standing assumptions:
 *      - The module holds `LIQUIDATION_MODULE_ROLE` on the RedemptionClaimToken (sole
 *        minter/burner) and is on its transfer whitelist, alongside DolomiteMargin.
 *      - The module is a Dolomite local operator for the strategy operator that owns the
 *        borrow positions; the temporary RedemptionClaimToken position is owned by the module itself.
 *      - The extracted BTCcx is redeemed through the merchant's `redeem` path with the
 *        calling liquidator (`msg.sender`) as receiver; a merchant `OPERATOR_ROLE` holder clears
 *        the pending claim with `finalizeAssetCxRedemption` once qualified custody has delivered.
 *        The liquidator sells the delivered BTC for the debt token and funds the debt token
 *        pulled back in {finalizeLiquidationAndRepay}.
 */
contract DolomiteLiquidationModule is
    Initializable,
    PausableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    ITimelockProtected,
    IDolomiteLiquidationModule
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @dev WAD fixed-point unit (1e18 = 100%).
    uint256 internal constant WAD = 1e18;

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
     * @notice Initializes the module.
     * @param params Initialization parameters; see {IDolomiteLiquidationModule.InitParams}.
     */
    function initialize(InitParams calldata params) public initializer {
        if (
            params.admin == address(0) || params.dolomiteMargin == address(0)
                || params.redemptionClaimToken == address(0) || params.merchant == address(0)
                || params.debtToken == address(0)
        ) revert ZeroAddress();
        if (params.collateralRatioWad == 0 || params.collateralRatioWad >= WAD) {
            revert InvalidRatio(params.collateralRatioWad);
        }
        if (params.bufferWad == 0 || params.bufferWad > WAD) revert InvalidRatio(params.bufferWad);
        if (params.liquidatableLtvWad == 0 || params.liquidatableLtvWad > WAD) {
            revert InvalidRatio(params.liquidatableLtvWad);
        }

        __Pausable_init();
        __AccessControlEnumerable_init();
        __UUPSUpgradeable_init();

        DolomiteLiquidationModuleStorageLib.Storage storage $ = DolomiteLiquidationModuleStorageLib.fetch();
        $.dolomiteMargin = IDolomiteMargin(params.dolomiteMargin);
        $.redemptionClaimToken = IRedemptionClaimToken(params.redemptionClaimToken);
        $.merchant = IConcreteMerchant(params.merchant);
        $.collateralToken = address(IConcreteMerchant(params.merchant).assetCX());
        if ($.collateralToken == address(0)) revert ZeroAddress();
        $.debtToken = params.debtToken;
        $.collateralRatioWad = params.collateralRatioWad;
        $.bufferWad = params.bufferWad;
        $.liquidatableLtvWad = params.liquidatableLtvWad;

        _grantRole(DEFAULT_ADMIN_ROLE, params.admin);
        _setRoleAdmin(AssetCxRolesLib.LIQUIDATOR_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(AssetCxRolesLib.PAUSER_ROLE, DEFAULT_ADMIN_ROLE);

        _grantRole(AssetCxRolesLib.PAUSER_ROLE, params.admin);
        if (params.liquidator != address(0)) _grantRole(AssetCxRolesLib.LIQUIDATOR_ROLE, params.liquidator);

        if (params.timelock != address(0)) TimelockIntegrationLib.setTimelock(params.timelock);
    }

    // ============ Liquidation flow (LIQUIDATOR_ROLE only) ============

    /// @inheritdoc IDolomiteLiquidationModule
    function initiateLiquidationCollateralSwap(
        address positionOwner,
        uint256 accountNumber,
        uint256 debtAmountToLiquidate,
        address receiver
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(AssetCxRolesLib.LIQUIDATOR_ROLE)
        returns (uint256 redemptionId)
    {
        if (positionOwner == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        if (debtAmountToLiquidate == 0) revert ZeroAmount();

        DolomiteLiquidationModuleStorageLib.Storage storage $ = DolomiteLiquidationModuleStorageLib.fetch();
        if (!$.dolomiteMargin.getIsLocalOperator(positionOwner, address(this))) {
            revert NotDolomiteOperator(positionOwner);
        }

        // The admin override path stays open at any LTV; every other liquidator is confined to
        // positions that have reached the configured band.
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            uint256 ltvWad = DolomiteLiquidationLib.currentLtvWad($.dolomiteMargin, positionOwner, accountNumber);
            if (ltvWad < $.liquidatableLtvWad) revert PositionNotLiquidatable(ltvWad, $.liquidatableLtvWad);
        }

        uint256 positionDebt = DolomiteLiquidationLib.borrowPositionDebt($, positionOwner, accountNumber);
        if (debtAmountToLiquidate > positionDebt) {
            revert DebtAmountExceedsPositionDebt(debtAmountToLiquidate, positionDebt);
        }

        redemptionId = $.nextRedemptionId++;
        uint256 tempAccountNumber =
            uint256(keccak256(abi.encode("concrete.liquidation.temp", address(this), redemptionId)));

        // Size the mint and the withdrawal from oracle prices.
        (uint256 redemptionClaimAmount, uint256 collateralAmount) =
            DolomiteLiquidationLib.computeSwapAmounts($, debtAmountToLiquidate);

        // 1. Mint the RedemptionClaimToken to this module (sole minter) and approve the supply.
        $.redemptionClaimToken.mint(redemptionClaimAmount);
        IERC20(address($.redemptionClaimToken)).forceApprove(address($.dolomiteMargin), redemptionClaimAmount);

        // 2. Single atomic operate: supply the RedemptionClaimToken into the module-owned
        //    temporary position (B), move the debt from the borrow position (A) onto B, and
        //    withdraw the freed BTCcx from A to this module.
        DolomiteLiquidationLib.executeInitiateOperate(
            $,
            positionOwner,
            accountNumber,
            tempAccountNumber,
            redemptionClaimAmount,
            debtAmountToLiquidate,
            collateralAmount
        );

        // Invariant: The whole mint was supplied into the temporary position
        _assertNoRedemptionClaimBalance($);

        // 3. Initiate redemption of the extracted BTCcx (burned by the merchant; the QC
        //    delivers BTC off-chain against the pending redemption). The redemption is recorded
        //    against `receiver`: it takes delivery of the redeemed value, and funds the debt token
        //    pulled back in finalizeLiquidationAndRepay.
        IERC20($.collateralToken).forceApprove(address($.merchant), collateralAmount);
        $.merchant.redeem(collateralAmount, receiver);

        $.liquidations[redemptionId] = DolomiteLiquidationModuleStorageLib.Liquidation({
            positionOwner: positionOwner,
            accountNumber: accountNumber,
            tempAccountNumber: tempAccountNumber,
            redemptionClaimTokenSupplied: redemptionClaimAmount,
            debtMoved: debtAmountToLiquidate,
            collateralRedeemed: collateralAmount,
            debtRepaid: 0,
            redemptionClaimTokenWithdrawn: 0,
            active: true
        });
        $.liquidationIdsByPosition[positionOwner][accountNumber].add(redemptionId);

        emit LiquidationInitiated(
            redemptionId,
            positionOwner,
            accountNumber,
            tempAccountNumber,
            debtAmountToLiquidate,
            redemptionClaimAmount,
            collateralAmount
        );
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function finalizeLiquidationAndRepay(uint256 redemptionId, uint256 debtTokenAmount)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(AssetCxRolesLib.LIQUIDATOR_ROLE)
    {
        DolomiteLiquidationModuleStorageLib.Storage storage $ = DolomiteLiquidationModuleStorageLib.fetch();
        DolomiteLiquidationModuleStorageLib.Liquidation storage liq = $.liquidations[redemptionId];
        if (!liq.active) revert LiquidationNotActive(redemptionId);
        if (debtTokenAmount == 0) revert ZeroAmount();

        // Outstanding debt on the temporary position (incl. accrued interest). Repayment may be
        // partial: anything up to the full debt clears that much; a full close needs to cover it.
        uint256 tempDebt = DolomiteLiquidationLib.tempPositionDebt($, liq);
        bool fullClose = debtTokenAmount >= tempDebt;
        uint256 repayAmount = fullClose ? tempDebt : debtTokenAmount;

        // Surplus (and the borrow-position repayment / refund it funds) only exists on a full close.
        uint256 surplus = debtTokenAmount - repayAmount;
        uint256 surplusApplied = Math.min(surplus, DolomiteLiquidationLib.borrowPositionDebt($, liq));
        uint256 refund = surplus - surplusApplied;

        // Invariant: the module holds no RedemptionClaimToken between operations, so what it
        // withdraws below is exactly this liquidation's collateral.
        _assertNoRedemptionClaimBalance($);

        // Size the RedemptionClaimToken released this call: all of it on a full close, otherwise
        // whatever the temporary position holds above the collateral backing the debt after repayment
        // temp position ends the call closed or at the configured ratio it was opened at.
        uint256 redemptionClaimWithdraw =
            fullClose ? 0 : DolomiteLiquidationLib.computeRedemptionClaimRelease($, liq, repayAmount, tempDebt);

        // 1. Pull the sale proceeds and approve what will be deposited into Dolomite.
        IERC20($.debtToken).safeTransferFrom(msg.sender, address(this), debtTokenAmount);
        IERC20($.debtToken).forceApprove(address($.dolomiteMargin), repayAmount + surplusApplied);

        // 2. Single atomic operate: repay B's debt, withdraw the released RedemptionClaimToken from
        //    B, and (full close only) apply the surplus to A's remaining debt.
        DolomiteLiquidationLib.executeFinalizeOperate(
            $, liq, repayAmount, redemptionClaimWithdraw, surplusApplied, fullClose
        );

        // 3. Burn the RedemptionClaimToken withdrawn this call (sole burner); the pre-step invariant
        //    guarantees the balance equals precisely what was released above.
        uint256 redemptionClaimBurned = IERC20(address($.redemptionClaimToken)).balanceOf(address(this));
        if (redemptionClaimBurned > 0) $.redemptionClaimToken.burn(redemptionClaimBurned);

        //reset any dust approvals
        IERC20($.debtToken).forceApprove(address($.dolomiteMargin), 0);

        if (refund > 0) IERC20($.debtToken).safeTransfer(msg.sender, refund);

        // Accumulate this call's debt repayment and RedemptionClaimToken withdrawal on the record.
        liq.debtRepaid += repayAmount;
        liq.redemptionClaimTokenWithdrawn += redemptionClaimBurned;

        // On a full close the temporary position is fully unwound: clear the record. A full close
        // must satisfy the unwind invariant — every supplied RedemptionClaimToken has been
        // withdrawn and burned (matching exactly, as all of it is withdrawn on a full close).
        if (fullClose) {
            require(
                liq.redemptionClaimTokenWithdrawn == liq.redemptionClaimTokenSupplied,
                LiquidationInvariantViolated(redemptionId)
            );
            $.liquidationIdsByPosition[liq.positionOwner][liq.accountNumber].remove(redemptionId);
            // Emit before clearing the record so the original position fields are still readable.
            emit LiquidationFinalized(
                redemptionId,
                liq.positionOwner,
                liq.accountNumber,
                repayAmount,
                surplusApplied,
                refund,
                redemptionClaimBurned
            );
            delete $.liquidations[redemptionId];
        } else {
            emit LiquidationPartiallyFinalized(
                redemptionId, liq.positionOwner, liq.accountNumber, repayAmount, redemptionClaimBurned, liq.debtRepaid
            );
        }
    }

    // ============ Configuration (DEFAULT_ADMIN_ROLE, timelocked) ============

    /// @inheritdoc IDolomiteLiquidationModule
    function setCollateralRatio(uint256 collateralRatioWad_) external override afterDelay onlyRole(DEFAULT_ADMIN_ROLE) {
        if (collateralRatioWad_ == 0 || collateralRatioWad_ >= WAD) revert InvalidRatio(collateralRatioWad_);
        DolomiteLiquidationModuleStorageLib.fetch().collateralRatioWad = collateralRatioWad_;
        emit CollateralRatioUpdated(collateralRatioWad_);
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function setBuffer(uint256 bufferWad_) external override afterDelay onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bufferWad_ == 0 || bufferWad_ > WAD) revert InvalidRatio(bufferWad_);
        DolomiteLiquidationModuleStorageLib.fetch().bufferWad = bufferWad_;
        emit BufferUpdated(bufferWad_);
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function setLiquidatableLtv(uint256 liquidatableLtvWad_) external override afterDelay onlyRole(DEFAULT_ADMIN_ROLE) {
        if (liquidatableLtvWad_ == 0 || liquidatableLtvWad_ > WAD) revert InvalidRatio(liquidatableLtvWad_);
        DolomiteLiquidationModuleStorageLib.fetch().liquidatableLtvWad = liquidatableLtvWad_;
        emit LiquidatableLtvUpdated(liquidatableLtvWad_);
    }

    // ============ Pause ============

    /// @inheritdoc IDolomiteLiquidationModule
    function pause() external override onlyRole(AssetCxRolesLib.PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function unpause() external override afterDelay onlyRole(AssetCxRolesLib.PAUSER_ROLE) {
        _unpause();
    }

    // ============ Views ============

    /// @inheritdoc IDolomiteLiquidationModule
    function getLiquidation(uint256 redemptionId)
        external
        view
        override
        returns (DolomiteLiquidationModuleStorageLib.Liquidation memory)
    {
        return DolomiteLiquidationModuleStorageLib.fetch().liquidations[redemptionId];
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function getLiquidationIds(address positionOwner, uint256 accountNumber)
        external
        view
        override
        returns (uint256[] memory)
    {
        DolomiteLiquidationModuleStorageLib.Storage storage $ = DolomiteLiquidationModuleStorageLib.fetch();
        return $.liquidationIdsByPosition[positionOwner][accountNumber].values();
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function dolomiteMargin() external view override returns (IDolomiteMargin) {
        return DolomiteLiquidationModuleStorageLib.fetch().dolomiteMargin;
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function redemptionClaimToken() external view override returns (IRedemptionClaimToken) {
        return DolomiteLiquidationModuleStorageLib.fetch().redemptionClaimToken;
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function merchant() external view override returns (IConcreteMerchant) {
        return DolomiteLiquidationModuleStorageLib.fetch().merchant;
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function collateralToken() external view override returns (address) {
        return DolomiteLiquidationModuleStorageLib.fetch().collateralToken;
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function debtToken() external view override returns (address) {
        return DolomiteLiquidationModuleStorageLib.fetch().debtToken;
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function collateralRatioWad() external view override returns (uint256) {
        return DolomiteLiquidationModuleStorageLib.fetch().collateralRatioWad;
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function bufferWad() external view override returns (uint256) {
        return DolomiteLiquidationModuleStorageLib.fetch().bufferWad;
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function liquidatableLtvWad() external view override returns (uint256) {
        return DolomiteLiquidationModuleStorageLib.fetch().liquidatableLtvWad;
    }

    /// @inheritdoc IDolomiteLiquidationModule
    function positionLtvWad(address positionOwner, uint256 accountNumber) external view override returns (uint256) {
        return DolomiteLiquidationLib.currentLtvWad(
            DolomiteLiquidationModuleStorageLib.fetch().dolomiteMargin, positionOwner, accountNumber
        );
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
    ///      (notably `LIQUIDATOR_ROLE`) cannot change without a queued proposal.
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

    /// @dev Reverts unless the module currently custodies zero RedemptionClaimToken. The token is
    ///      only ever held transiently inside a Dolomite `operate`; between the initiate and
    ///      finalize steps it must live entirely in the temporary positions.
    function _assertNoRedemptionClaimBalance(DolomiteLiquidationModuleStorageLib.Storage storage $) private view {
        uint256 balance = IERC20(address($.redemptionClaimToken)).balanceOf(address(this));
        if (balance != 0) revert UnexpectedRedemptionClaimBalance(balance);
    }

    /// @dev Only `DEFAULT_ADMIN_ROLE` can authorize UUPS upgrades, and only after
    ///      the upgrade selector has matured through the timelock.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) afterDelay {
        emit DolomiteLiquidationModuleUpgradeAuthorized(newImplementation, msg.sender);
    }

    /// @notice Prevents removing the last `DEFAULT_ADMIN_ROLE`, which would
    ///         leave the timelock permanently without an admin.
    /// @dev Both {revokeRole} and {renounceRole} funnel through this hook, so
    ///      this single override blocks self-revoke, self-renounce, and
    ///      admin-revokes-admin alike. With multiple admins any one of them
    ///      (including the caller) can still be removed.
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
