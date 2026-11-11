// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {IDolomiteMargin} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomiteMargin.sol";
import {IConcreteMerchant} from "../interface/IConcreteMerchant.sol";
import {IRedemptionClaimToken} from "../interface/IRedemptionClaimToken.sol";

/**
 * @title DolomiteLiquidationModuleStorageLib
 * @author Blueprint Finance
 * @notice EIP-7201 namespaced storage for {DolomiteLiquidationModule}.
 */
library DolomiteLiquidationModuleStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.DolomiteLiquidationModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant DOLOMITE_LIQUIDATION_MODULE_STORAGE_LOCATION =
        0x11e92b01f3c19d27e0ebe6165eaab49c9cc2b7bfa11dcac64ed11e1759233200;

    /// @notice Lifecycle record of one in-flight liquidation (initiate → finalize).
    struct Liquidation {
        /// @notice Owner of the Dolomite borrow position (the strategy operator).
        address positionOwner;
        /// @notice Account number of the BTCcx-backed borrow position (position A).
        uint256 accountNumber;
        /// @notice Account number of the temporary RedemptionClaimToken-backed position (position B).
        uint256 tempAccountNumber;
        /// @notice RedemptionClaimToken minted and supplied as position B collateral.
        uint256 redemptionClaimTokenSupplied;
        /// @notice Debt-token amount moved from position A onto position B at initiation.
        uint256 debtMoved;
        /// @notice Collateral (BTCcx) withdrawn from position A and sent to redemption.
        uint256 collateralRedeemed;
        /// @notice Cumulative debt-token repaid into position B across (possibly partial)
        ///         finalization calls. Reaches `debtMoved` (plus accrued interest) once fully
        ///         unwound.
        uint256 debtRepaid;
        /// @notice Cumulative RedemptionClaimToken withdrawn from position B and burned across
        ///         (possibly partial) finalization calls. Reaches `redemptionClaimTokenSupplied`
        ///         once the position is fully unwound, at which point the record is cleared.
        uint256 redemptionClaimTokenWithdrawn;
        /// @notice True from initiation until the temporary position is fully repaid.
        bool active;
    }

    struct Storage {
        /// @notice The DolomiteMargin core contract.
        IDolomiteMargin dolomiteMargin;
        /// @notice The RedemptionClaimToken this module mints/burns (e.g. rBTCcx-USD1).
        IRedemptionClaimToken redemptionClaimToken;
        /// @notice The ConcreteMerchant used to redeem the extracted BTCcx.
        IConcreteMerchant merchant;
        /// @notice The collateral token being liquidated/redeemed (BTCcx / AssetCX).
        address collateralToken;
        /// @notice The debt token of the market pair (e.g. USD1).
        address debtToken;
        /// @notice LTV at which the RedemptionClaimToken backs debt, in WAD (e.g. 0.98e18).
        ///         Minted claim = debtValue / collateralRatioWad.
        uint256 collateralRatioWad;
        /// @notice Over-withdrawal buffer on the redeemed collateral, in WAD (e.g. 0.05e18).
        ///         Collateral withdrawn is worth debt × (1 + buffer).
        uint256 bufferWad;
        /// @notice Monotonic id assigned to each initiated liquidation.
        uint256 nextRedemptionId;
        /// @notice Liquidation records by redemption id.
        mapping(uint256 redemptionId => Liquidation) liquidations;
        /// @notice Set of active liquidation ids per borrow position (positionOwner, accountNumber).
        ///         An id is added on initiation and removed once its record is cleared on full
        ///         finalization, so the set always reflects the currently in-flight liquidations.
        mapping(address positionOwner => mapping(uint256 accountNumber => EnumerableSet.UintSet))
            liquidationIdsByPosition;
        /// @notice LTV, in WAD, at or above which a borrow position may be liquidated by a
        ///         `LIQUIDATOR_ROLE` caller that does not also hold `DEFAULT_ADMIN_ROLE`. Set by
        ///         governance to the operational self-liquidation band.
        uint256 liquidatableLtvWad;
    }

    function fetch() internal pure returns (Storage storage $) {
        assembly {
            $.slot := DOLOMITE_LIQUIDATION_MODULE_STORAGE_LOCATION
        }
    }

    function storageLocation() internal pure returns (bytes32) {
        return DOLOMITE_LIQUIDATION_MODULE_STORAGE_LOCATION;
    }
}
