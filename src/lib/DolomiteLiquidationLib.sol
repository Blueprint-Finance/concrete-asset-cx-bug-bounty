// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {IDolomiteMargin} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomiteMargin.sol";
import {IDolomiteStructs} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomiteStructs.sol";
import {AccountActionLib} from "@dolomite-exchange/modules-base/contracts/lib/AccountActionLib.sol";
import {DolomiteLiquidationModuleStorageLib} from "./DolomiteLiquidationModuleStorageLib.sol";

/**
 * @title DolomiteLiquidationLib
 * @author Blueprint Finance
 * @notice Dolomite-facing helpers for {DolomiteLiquidationModule}: amount sizing from
 *         oracle prices, position balance and LTV views, and the two composed `operate`
 *         calls of the liquidation flow.
 * @dev Actions are encoded with Dolomite's own {AccountActionLib}. All functions read the
 *      module's EIP-7201 storage; `address(this)` is the module (libraries are delegatecalled).
 */
library DolomiteLiquidationLib {
    using Math for uint256;

    /// @dev WAD fixed-point unit (1e18 = 100%).
    uint256 internal constant WAD = 1e18;

    /**
     * @notice RedemptionClaimToken that backs `debtAmount` of debt at the configured collateral
     *         ratio, from Dolomite oracle prices (`price × wei` is a 36-decimal USD value).
     * @dev `debtValue / (redemptionClaimPrice × collateralRatio)`, rounded UP so the claim always
     *      fully backs the debt at the listed LTV. Sizes the mint at initiation and the collateral
     *      the temporary position must retain at every partial finalization
     * @param $                    Module storage.
     * @param debtAmount           Debt-token amount to be backed.
     * @param debtPrice            Dolomite price of the debt token.
     * @param redemptionClaimPrice Dolomite price of the RedemptionClaimToken.
     */
    function rcTokenAmountForDebtAndTargetRatio(
        DolomiteLiquidationModuleStorageLib.Storage storage $,
        uint256 debtAmount,
        uint256 debtPrice,
        uint256 redemptionClaimPrice
    ) internal view returns (uint256) {
        return debtAmount.mulDiv(debtPrice * WAD, redemptionClaimPrice * $.collateralRatioWad, Math.Rounding.Ceil);
    }

    /**
     * @notice Sizes the RedemptionClaimToken mint and the collateral withdrawal for a liquidation.
     * @dev redemptionClaim = {rcTokenAmountForDebtAndTargetRatio} of the moved debt;
     *      collateral = debtValue × (1 + buffer) / collateralPrice, rounded down.
     * @param $                     Module storage.
     * @param debtAmountToLiquidate Debt-token amount being taken over.
     * @return redemptionClaimAmount RedemptionClaimToken amount to mint and supply.
     * @return collateralAmount      Collateral (BTCcx) amount to withdraw and redeem.
     */
    function computeSwapAmounts(DolomiteLiquidationModuleStorageLib.Storage storage $, uint256 debtAmountToLiquidate)
        internal
        view
        returns (uint256 redemptionClaimAmount, uint256 collateralAmount)
    {
        IDolomiteMargin dolomite = $.dolomiteMargin;
        uint256 debtPrice = dolomite.getMarketPrice(marketId(dolomite, $.debtToken)).value;
        uint256 redemptionClaimPrice =
            dolomite.getMarketPrice(marketId(dolomite, address($.redemptionClaimToken))).value;
        uint256 collateralPrice = dolomite.getMarketPrice(marketId(dolomite, $.collateralToken)).value;

        redemptionClaimAmount =
            rcTokenAmountForDebtAndTargetRatio($, debtAmountToLiquidate, debtPrice, redemptionClaimPrice);
        collateralAmount = debtAmountToLiquidate.mulDiv(debtPrice * (WAD + $.bufferWad), collateralPrice * WAD);
    }

    /**
     * @notice Sizes the RedemptionClaimToken to release when repaying `repayAmount` of the
     *         temporary position's debt during a partial finalization.
     * @dev Releases whatever the position holds above the {rcTokenAmountForDebtAndTargetRatio} of
     *      the debt it is left with, so it ends the call backed at exactly the configured ratio
     * @param $           Module storage.
     * @param liq         The liquidation record being finalized.
     * @param repayAmount Debt-token amount being repaid on this call.
     * @param tempDebt    Outstanding debt of the temporary position, incl. accrued interest.
     * @return redemptionClaimRelease RedemptionClaimToken to withdraw from the temporary position and burn.
     */
    function computeRedemptionClaimRelease(
        DolomiteLiquidationModuleStorageLib.Storage storage $,
        DolomiteLiquidationModuleStorageLib.Liquidation storage liq,
        uint256 repayAmount,
        uint256 tempDebt
    ) internal view returns (uint256 redemptionClaimRelease) {
        IDolomiteMargin dolomite = $.dolomiteMargin;
        uint256 residualBacking = rcTokenAmountForDebtAndTargetRatio(
            $,
            tempDebt - repayAmount,
            dolomite.getMarketPrice(marketId(dolomite, $.debtToken)).value,
            dolomite.getMarketPrice(marketId(dolomite, address($.redemptionClaimToken))).value
        );

        uint256 collateral = tempPositionRedemptionClaim($, liq);
        redemptionClaimRelease = collateral > residualBacking ? collateral - residualBacking : 0;
    }

    /**
     * @notice Executes the initiation `operate`:
     *         - supplies `redemptionClaimAmount` RedemptionClaimToken into the module-owned
     *           temporary position (B);
     *         - moves `debtAmountToLiquidate` of debt from the borrow position (A) onto B via
     *           an internal balance transfer (the debt token never leaves Dolomite);
     *         - withdraws `collateralAmount` of collateral from A to the module.
     * @param $                      Module storage.
     * @param positionOwner          Owner of the borrow position (A).
     * @param accountNumber          Account number of the borrow position (A).
     * @param tempAccountNumber      Module-owned temporary account number (B).
     * @param redemptionClaimAmount  RedemptionClaimToken amount supplied into B.
     * @param debtAmountToLiquidate  Debt moved from A onto B.
     * @param collateralAmount       Collateral withdrawn from A to the module.
     */
    function executeInitiateOperate(
        DolomiteLiquidationModuleStorageLib.Storage storage $,
        address positionOwner,
        uint256 accountNumber,
        uint256 tempAccountNumber,
        uint256 redemptionClaimAmount,
        uint256 debtAmountToLiquidate,
        uint256 collateralAmount
    ) internal {
        IDolomiteMargin dolomite = $.dolomiteMargin;

        IDolomiteStructs.AccountInfo[] memory accounts = new IDolomiteStructs.AccountInfo[](2);
        accounts[0] = IDolomiteStructs.AccountInfo({owner: address(this), number: tempAccountNumber});
        accounts[1] = IDolomiteStructs.AccountInfo({owner: positionOwner, number: accountNumber});

        IDolomiteStructs.ActionArgs[] memory actions = new IDolomiteStructs.ActionArgs[](3);
        actions[0] = AccountActionLib.encodeDepositAction(
            0,
            marketId(dolomite, address($.redemptionClaimToken)),
            _weiDelta(true, redemptionClaimAmount),
            address(this)
        );
        // Wei delta applied to account B (the "from" account): B goes negative by the debt
        // amount (borrows), A receives the same amount (its debt is repaid).
        actions[1] = AccountActionLib.encodeTransferAction(
            0, 1, marketId(dolomite, $.debtToken), IDolomiteStructs.AssetDenomination.Wei, debtAmountToLiquidate
        );
        actions[2] = AccountActionLib.encodeWithdrawalAction(
            1, marketId(dolomite, $.collateralToken), _weiDelta(false, collateralAmount), address(this)
        );

        dolomite.operate(accounts, actions);
    }

    /**
     * @notice Executes a finalization `operate`, supporting both partial and full repayment:
     *         - repays `repayAmount` of the temporary position's debt (Target 0 on a full close,
     *           otherwise a Wei delta);
     *         - withdraws RedemptionClaimToken collateral from the temporary position to the module
     *           (all of it via Target 0 on a full close, otherwise `redemptionClaimWithdraw`);
     *         - on a full close only, applies `surplusApplied` to the borrow position's debt.
     * @param $                      Module storage.
     * @param liq                    The liquidation record being finalized.
     * @param repayAmount            Debt-token repaid into the temporary position on this call.
     * @param redemptionClaimWithdraw RedemptionClaimToken to withdraw on a partial call (ignored
     *                               when `fullClose`; skipped when zero).
     * @param surplusApplied         Debt-token surplus deposited into the borrow position (full
     *                               close only; skipped if 0).
     * @param fullClose              True to clear the temporary position entirely (Target 0 on
     *                               both the debt repay and the RedemptionClaimToken withdrawal).
     */
    function executeFinalizeOperate(
        DolomiteLiquidationModuleStorageLib.Storage storage $,
        DolomiteLiquidationModuleStorageLib.Liquidation storage liq,
        uint256 repayAmount,
        uint256 redemptionClaimWithdraw,
        uint256 surplusApplied,
        bool fullClose
    ) internal {
        IDolomiteMargin dolomite = $.dolomiteMargin;

        IDolomiteStructs.AccountInfo[] memory accounts = new IDolomiteStructs.AccountInfo[](2);
        accounts[0] = IDolomiteStructs.AccountInfo({owner: address(this), number: liq.tempAccountNumber});
        accounts[1] = IDolomiteStructs.AccountInfo({owner: liq.positionOwner, number: liq.accountNumber});

        bool doRedemptionClaimWithdrawal = fullClose || (redemptionClaimWithdraw > 0);
        IDolomiteStructs.ActionArgs[] memory actions =
            new IDolomiteStructs.ActionArgs[](1 + (doRedemptionClaimWithdrawal ? 1 : 0) + (surplusApplied > 0 ? 1 : 0));
        uint256 i;

        actions[i++] = AccountActionLib.encodeDepositAction(
            0,
            marketId(dolomite, $.debtToken),
            fullClose ? _weiTargetZero() : _weiDelta(true, repayAmount),
            address(this)
        );
        if (doRedemptionClaimWithdrawal) {
            actions[i++] = AccountActionLib.encodeWithdrawalAction(
                0,
                marketId(dolomite, address($.redemptionClaimToken)),
                fullClose ? _weiTargetZero() : _weiDelta(false, redemptionClaimWithdraw),
                address(this)
            );
        }
        if (surplusApplied > 0) {
            actions[i++] = AccountActionLib.encodeDepositAction(
                1, marketId(dolomite, $.debtToken), _weiDelta(true, surplusApplied), address(this)
            );
        }

        dolomite.operate(accounts, actions);
    }

    /// @notice Outstanding debt of the temporary position (B), in debt-token units.
    function tempPositionDebt(
        DolomiteLiquidationModuleStorageLib.Storage storage $,
        DolomiteLiquidationModuleStorageLib.Liquidation storage liq
    ) internal view returns (uint256) {
        return debtOf(
            $.dolomiteMargin,
            IDolomiteStructs.AccountInfo({owner: address(this), number: liq.tempAccountNumber}),
            marketId($.dolomiteMargin, $.debtToken)
        );
    }

    /// @notice RedemptionClaimToken collateral currently held by the temporary position (B), in
    ///         token units.
    function tempPositionRedemptionClaim(
        DolomiteLiquidationModuleStorageLib.Storage storage $,
        DolomiteLiquidationModuleStorageLib.Liquidation storage liq
    ) internal view returns (uint256) {
        return collateralOf(
            $.dolomiteMargin,
            IDolomiteStructs.AccountInfo({owner: address(this), number: liq.tempAccountNumber}),
            marketId($.dolomiteMargin, address($.redemptionClaimToken))
        );
    }

    /// @notice Outstanding debt of the borrow position (A), in debt-token units.
    function borrowPositionDebt(
        DolomiteLiquidationModuleStorageLib.Storage storage $,
        DolomiteLiquidationModuleStorageLib.Liquidation storage liq
    ) internal view returns (uint256) {
        return borrowPositionDebt($, liq.positionOwner, liq.accountNumber);
    }

    /// @notice Outstanding debt of a borrow position, in debt-token units, before any record exists.
    function borrowPositionDebt(
        DolomiteLiquidationModuleStorageLib.Storage storage $,
        address positionOwner,
        uint256 accountNumber
    ) internal view returns (uint256) {
        return debtOf(
            $.dolomiteMargin,
            IDolomiteStructs.AccountInfo({owner: positionOwner, number: accountNumber}),
            marketId($.dolomiteMargin, $.debtToken)
        );
    }

    /**
     * @notice Current loan-to-value of a Dolomite account, in WAD: the account's total borrowed
     *         value over its total supplied value, both at Dolomite oracle prices.
     * @dev An account with no supplied value is reported at `type(uint256).max`, i.e. maximally
     *      liquidatable: whatever debt it carries is backed by nothing. Reverting on it instead
     *      would make an unbacked position the one thing a liquidator could not act on.
     * @param dolomite      The DolomiteMargin core contract.
     * @param positionOwner Owner of the Dolomite account.
     * @param accountNumber Account number to read.
     */
    function currentLtvWad(IDolomiteMargin dolomite, address positionOwner, uint256 accountNumber)
        internal
        view
        returns (uint256)
    {
        (IDolomiteStructs.MonetaryValue memory supplyValue, IDolomiteStructs.MonetaryValue memory borrowValue) =
            dolomite.getAccountValues(IDolomiteStructs.AccountInfo({owner: positionOwner, number: accountNumber}));
        if (supplyValue.value == 0) return type(uint256).max;
        return borrowValue.value.mulDiv(WAD, supplyValue.value);
    }

    /// @notice Debt (negative balance) of `account` in `marketId_`, in token units; 0 if positive.
    function debtOf(IDolomiteMargin dolomite, IDolomiteStructs.AccountInfo memory account, uint256 marketId_)
        internal
        view
        returns (uint256)
    {
        IDolomiteStructs.Wei memory balance = dolomite.getAccountWei(account, marketId_);
        return balance.sign ? 0 : balance.value;
    }

    /// @notice Collateral (positive balance) of `account` in `marketId_`, in token units; 0 if a debt.
    function collateralOf(IDolomiteMargin dolomite, IDolomiteStructs.AccountInfo memory account, uint256 marketId_)
        internal
        view
        returns (uint256)
    {
        IDolomiteStructs.Wei memory balance = dolomite.getAccountWei(account, marketId_);
        return balance.sign ? balance.value : 0;
    }

    /// @notice Resolves a token to its Dolomite market id.
    function marketId(IDolomiteMargin dolomite, address token) internal view returns (uint256) {
        return dolomite.getMarketIdByTokenAddress(token);
    }

    /// @dev Wei-denominated delta amount (`sign == true` increases the balance).
    function _weiDelta(bool sign, uint256 value) private pure returns (IDolomiteStructs.AssetAmount memory) {
        return IDolomiteStructs.AssetAmount({
            sign: sign,
            denomination: IDolomiteStructs.AssetDenomination.Wei,
            ref: IDolomiteStructs.AssetReference.Delta,
            value: value
        });
    }

    /// @dev Wei-denominated target of zero: brings the balance exactly to 0 (used to clear a
    ///      debt with a deposit, or empty a collateral balance with a withdrawal).
    function _weiTargetZero() private pure returns (IDolomiteStructs.AssetAmount memory) {
        return IDolomiteStructs.AssetAmount({
            sign: true,
            denomination: IDolomiteStructs.AssetDenomination.Wei,
            ref: IDolomiteStructs.AssetReference.Target,
            value: 0
        });
    }
}
