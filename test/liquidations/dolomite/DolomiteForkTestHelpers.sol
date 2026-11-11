// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IDolomiteStructs} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomiteStructs.sol";
import {
    IDolomitePriceOracle
} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomitePriceOracle.sol";
import {
    IDolomiteInterestSetter
} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomiteInterestSetter.sol";

/// @notice Minimal view of the DolomiteMargin v2 admin surface used by the fork test. The pinned
///         modules-base package ships the legacy admin ABI, whereas the deployed core uses the v2
///         ownerAddMarket (selector 0xed4d6f5c). Only the calls exercised by the test are declared.
interface IDolomiteMarginAdminV2 {
    function ownerAddMarket(
        address token,
        IDolomitePriceOracle priceOracle,
        IDolomiteInterestSetter interestSetter,
        IDolomiteStructs.Decimal calldata marginPremium,
        IDolomiteStructs.Decimal calldata spreadPremium,
        uint256 maxSupplyWei,
        uint256 maxBorrowWei,
        IDolomiteStructs.Decimal calldata earningsRateOverride,
        bool isClosing
    ) external;

    /// @notice Repoints a market at another oracle; used to swap USD1's live Chainlink feed for the
    ///         constant-price test oracle before warping time (the live feed would go stale).
    function ownerSetPriceOracle(uint256 marketId, IDolomitePriceOracle priceOracle) external;

    /// @notice The live protocol-wide default risk-override setter (the production
    ///         DolomiteAccountRiskOverrideSetter), which the test configures for isolation mode.
    function getDefaultAccountRiskOverrideSetter() external view returns (address);
}

/// @notice Vendored Dolomite v2 interface for the production DolomiteAccountRiskOverrideSetter
///         (absent from the pinned modules-base version). The core calls {getAccountRiskOverride}
///         during final-state verification; the owner-gated {ownerSetRiskFeatureByMarketId}
///         configures a market's isolation-mode (level 3) rules, and the getters expose the config.
interface IDolomiteAccountRiskOverrideSetter {
    enum Category {
        NONE,
        BERA,
        BTC,
        ETH,
        STABLE
    }

    enum RiskFeature {
        NONE,
        BORROW_ONLY,
        SINGLE_COLLATERAL_WITH_STRICT_DEBT
    }

    struct CategoryStruct {
        Category category;
        IDolomiteStructs.Decimal marginRatioOverride;
        IDolomiteStructs.Decimal liquidationRewardOverride;
    }

    struct RiskFeatureStruct {
        RiskFeature riskFeature;
        bytes extraData;
    }

    struct SingleCollateralRiskStruct {
        uint256[] debtMarketIds;
        IDolomiteStructs.Decimal marginRatioOverride;
        IDolomiteStructs.Decimal liquidationRewardOverride;
    }

    function ownerSetRiskFeatureByMarketId(uint256 marketId, RiskFeature riskFeature, bytes calldata extraData) external;

    function getAccountRiskOverride(IDolomiteStructs.AccountInfo calldata account)
        external
        view
        returns (
            IDolomiteStructs.Decimal memory marginRatioOverride,
            IDolomiteStructs.Decimal memory liquidationRewardOverride
        );

    function getCategoryMaskByMarketIds(uint256[] memory marketIds) external view returns (uint256);
    function getCategoryByMarketId(uint256 marketId) external view returns (Category);
    function getCategoryParamByCategory(Category category) external view returns (CategoryStruct memory);
    function getCategoryParamByMarketId(uint256 marketId) external view returns (CategoryStruct memory);
    function getRiskFeatureByMarketId(uint256 marketId) external view returns (RiskFeature);
    function getRiskFeatureParamByMarketId(uint256 marketId) external view returns (RiskFeatureStruct memory);
    function getRiskFeatureForSingleCollateralByMarketId(uint256 marketId)
        external
        view
        returns (SingleCollateralRiskStruct[] memory);
}

/// @notice Constant-price oracle used to list the test markets.
contract TestPriceOracle is IDolomitePriceOracle {
    mapping(address => uint256) internal prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view override returns (IDolomiteStructs.MonetaryPrice memory) {
        return IDolomiteStructs.MonetaryPrice({value: prices[token]});
    }
}

/// @notice Zero-rate interest setter (keeps debt accounting exact across the test).
contract TestInterestSetter is IDolomiteInterestSetter {
    function getInterestRate(address, uint256, uint256) external pure override returns (InterestRate memory) {
        return InterestRate({value: 0});
    }

    function interestSetterType() external pure override returns (InterestSetterType) {
        return InterestSetterType.Other;
    }
}

