// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IDolomiteMargin} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomiteMargin.sol";
import {IDolomiteStructs} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomiteStructs.sol";
import {
    IDolomitePriceOracle
} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomitePriceOracle.sol";
import {
    IDolomiteInterestSetter
} from "@dolomite-exchange/modules-base/contracts/protocol/interfaces/IDolomiteInterestSetter.sol";

import {ERC4626Mock} from "@concrete-xyz/earn-v2-core/test/mock/ERC4626Mock.sol";

import {AssetCX} from "../../src/AssetCX.sol";
import {ConcreteMerchant} from "../../src/merchant/ConcreteMerchant.sol";
import {RedemptionClaimToken} from "../../src/liquidations/RedemptionClaimToken.sol";
import {DolomiteLiquidationModule} from "../../src/liquidations/DolomiteLiquidationModule.sol";
import {IDolomiteLiquidationModule} from "../../src/interface/IDolomiteLiquidationModule.sol";
import {DolomiteLiquidationModuleStorageLib} from "../../src/lib/DolomiteLiquidationModuleStorageLib.sol";
import {AssetCxRolesLib} from "../../src/lib/AssetCxRolesLib.sol";

import {
    IDolomiteMarginAdminV2,
    IDolomiteAccountRiskOverrideSetter,
    TestPriceOracle,
    TestInterestSetter
} from "./dolomite/DolomiteForkTestHelpers.sol";

/// @notice Owner-gated mint on the live USD1 token (mints to the caller).
interface IUSD1Mintable {
    function mint(uint256 amount) external;
}

/// @title DolomiteLiquidationModuleForkTest
/// @notice End-to-end fork test of {DolomiteLiquidationModule} against the live DolomiteMargin
///         core on Ethereum mainnet. The DolomiteMargin admin is impersonated to list the BTCcx
///         (AssetCX) and RedemptionClaimToken markets (USD1 is already market 1) and to configure
///         both BTCcx and the RedemptionClaimToken as isolation-mode (level 3) collateral on the
///         live production DolomiteAccountRiskOverrideSetter (SINGLE_COLLATERAL_WITH_STRICT_DEBT):
///         each is borrowable only against USD1 and cannot share a position with other collateral.
contract DolomiteLiquidationModuleForkTest is Test {
    // ── Fork block pinned for reproducible state (requires an archive RPC in `MAIN_RPC`) ──
    uint256 internal constant FORK_BLOCK = 25523411;

    // ── Live mainnet DolomiteMargin core ──────────────────────────────────────
    address internal constant DOLOMITE_MARGIN = 0x003Ca23Fd5F0ca87D01F6eC6CD14A8AE60c2b97D;

    // ── Live USD1 (World Liberty Financial USD) — the debt token, already Dolomite market 1 ──
    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address internal constant USD1_OWNER = 0xEE9B1A09AEDAceD9dCDA74964EA447feb93861C2;

    // ── Oracle prices for the added markets (USD price of one base unit × 10^(36 - decimals);
    //    both tokens 18 dp). USD1 keeps its live on-chain oracle, and the RedemptionClaimToken
    //    (delta-neutral to USD1) is priced at that same live USD1 price (see `rctPrice`). ──
    uint256 internal constant ASSETCX_PRICE = 100_000e18; // $100k (BTCcx)

    // ── Position sizing ───────────────────────────────────────────────────────
    uint256 internal constant COLLATERAL_SUPPLY = 1e18; // 1 BTCcx ($100k)
    uint256 internal constant USD1_BORROW = 50_000e18; // ~$50k debt
    uint256 internal constant ACCOUNT_A = 1; // strategy operator's borrow position

    // Tolerance for USD1 balances: the live market's interest index (> 1) introduces sub-token
    // Par/Wei rounding dust on borrow/repay/transfer.
    uint256 internal constant USD1_DUST = 1e10;

    uint256 internal constant COLLATERAL_RATIO_WAD = 0.98e18;
    uint256 internal constant BUFFER_WAD = 0.05e18;
    // Liquidatable band a plain LIQUIDATOR_ROLE caller is confined to. Kept well under the ~50%
    // LTV the position opens at: every liquidation lowers A's LTV, so the band has to sit below
    // the whole sequence the tests walk, not just its first call.
    uint256 internal constant LIQUIDATABLE_LTV_WAD = 0.3e18;
    // Isolation-mode (SINGLE_COLLATERAL_WITH_STRICT_DEBT) parameters. The production
    // DolomiteAccountRiskOverrideSetter requires a non-zero margin ratio and liquidation reward per
    // isolation market (reward < ratio, both within the risk limits: marginRatioMax 2e18,
    // liquidationSpreadMax 0.5e18).
    // BTCcx: conservative BTC-like margin (15% → ~87% LTV). RedemptionClaimToken: tight 1% margin
    // (required collateralization 101%, below the ~102% it provides at 98% LTV).
    uint256 internal constant ASSETCX_ISO_MARGIN_RATIO = 0.15e18;
    uint256 internal constant ASSETCX_ISO_LIQ_REWARD = 0.05e18;
    uint256 internal constant RCT_ISO_MARGIN_RATIO = 0.01e18;
    uint256 internal constant RCT_ISO_LIQ_REWARD = 0.005e18;

    IDolomiteMargin internal dolomite;
    address internal dolomiteOwner;

    IERC20 internal usd1;
    AssetCX internal assetCX;
    ConcreteMerchant internal merchant;
    RedemptionClaimToken internal rct;
    DolomiteLiquidationModule internal module;

    TestPriceOracle internal oracle;
    TestInterestSetter internal interestSetter;
    IDolomiteAccountRiskOverrideSetter internal riskOverride; // the live production default setter

    uint256 internal rctPrice; // live USD1 price mirrored onto the RedemptionClaimToken oracle

    uint256 internal usd1MarketId;
    uint256 internal assetCXMarketId;
    uint256 internal rctMarketId;

    address internal admin = makeAddr("admin");
    address internal strategyOperator = makeAddr("strategyOperator");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        // Pin the fork to a fixed block for deterministic, reproducible runs. `MAIN_RPC` must
        // point at an archive-capable endpoint (a non-archive public node cannot serve state at
        // a historical block).
        string memory rpc = vm.envOr("MAIN_RPC", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpc, FORK_BLOCK);

        dolomite = IDolomiteMargin(DOLOMITE_MARGIN);
        dolomiteOwner = dolomite.owner();

        _deployTokensAndModule();
        _listDolomiteMarkets();
        _wireRolesAndWhitelist();
        _seedLiquidityAndPosition();
    }

    // ─────────────────────────────── Setup steps ──────────────────────────────

    function _deployTokensAndModule() internal {
        usd1 = IERC20(USD1);
        vm.label(USD1, "USD1");

        assetCX = AssetCX(
            address(
                new ERC1967Proxy(
                    address(new AssetCX()),
                    abi.encodeCall(AssetCX.initialize, ("AssetCX BTCcx", "BTCcx", admin, address(0)))
                )
            )
        );
        vm.label(address(assetCX), "AssetCX");

        ERC4626Mock vault = new ERC4626Mock(address(assetCX));
        merchant = ConcreteMerchant(
            address(
                new ERC1967Proxy(
                    address(new ConcreteMerchant()),
                    abi.encodeCall(ConcreteMerchant.initialize, (admin, assetCX, IERC4626(address(vault)), address(0)))
                )
            )
        );
        vm.label(address(merchant), "ConcreteMerchant");

        rct = RedemptionClaimToken(
            address(
                new ERC1967Proxy(
                    address(new RedemptionClaimToken()),
                    abi.encodeCall(
                        RedemptionClaimToken.initialize,
                        ("Redemption Claim BTCcx-USD1", "rBTCcx-USD1", admin, 18, address(0))
                    )
                )
            )
        );
        vm.label(address(rct), "RedemptionClaimToken");

        IDolomiteLiquidationModule.InitParams memory params = IDolomiteLiquidationModule.InitParams({
            admin: admin,
            liquidator: liquidator,
            dolomiteMargin: DOLOMITE_MARGIN,
            redemptionClaimToken: address(rct),
            merchant: address(merchant),
            debtToken: address(usd1),
            collateralRatioWad: COLLATERAL_RATIO_WAD,
            bufferWad: BUFFER_WAD,
            liquidatableLtvWad: LIQUIDATABLE_LTV_WAD,
            timelock: address(0)
        });
        module = DolomiteLiquidationModule(
            address(
                new ERC1967Proxy(
                    address(new DolomiteLiquidationModule()),
                    abi.encodeCall(DolomiteLiquidationModule.initialize, (params))
                )
            )
        );
        vm.label(address(module), "DolomiteLiquidationModule");
    }

    function _listDolomiteMarkets() internal {
        // USD1 is already listed (market 1) with its live oracle; only price the added markets.
        // The RedemptionClaimToken is delta-neutral to USD1, so it mirrors USD1's live price.
        rctPrice = dolomite.getMarketPrice(dolomite.getMarketIdByTokenAddress(USD1)).value;
        oracle = new TestPriceOracle();
        oracle.setPrice(address(assetCX), ASSETCX_PRICE);
        oracle.setPrice(address(rct), rctPrice);

        interestSetter = new TestInterestSetter();

        // Use the live production default risk-override setter (DolomiteAccountRiskOverrideSetter).
        riskOverride = IDolomiteAccountRiskOverrideSetter(
            IDolomiteMarginAdminV2(DOLOMITE_MARGIN).getDefaultAccountRiskOverrideSetter()
        );

        IDolomiteMarginAdminV2 admin_ = IDolomiteMarginAdminV2(DOLOMITE_MARGIN);
        vm.startPrank(dolomiteOwner);
        _addMarket(admin_, address(assetCX));
        _addMarket(admin_, address(rct));
        vm.stopPrank();

        usd1MarketId = dolomite.getMarketIdByTokenAddress(USD1);
        assetCXMarketId = dolomite.getMarketIdByTokenAddress(address(assetCX));
        rctMarketId = dolomite.getMarketIdByTokenAddress(address(rct));

        // Configure BTCcx → USD1 and RedemptionClaimToken → USD1 as isolation-mode level 3
        // (SINGLE_COLLATERAL_WITH_STRICT_DEBT) directly on the live setter: each is the sole
        // collateral in its position and may only be borrowed against USD1.
        _configureIsolation(assetCXMarketId, ASSETCX_ISO_MARGIN_RATIO, ASSETCX_ISO_LIQ_REWARD, usd1MarketId);
        _configureIsolation(rctMarketId, RCT_ISO_MARGIN_RATIO, RCT_ISO_LIQ_REWARD, usd1MarketId);
    }

    /// @dev Registers `isoMarketId` as SINGLE_COLLATERAL_WITH_STRICT_DEBT on the live setter, with a
    ///      single allowed debt market, impersonating the DolomiteMargin owner (the setter's admin).
    function _configureIsolation(uint256 isoMarketId, uint256 marginRatio, uint256 liqReward, uint256 debtMarketId)
        internal
    {
        uint256[] memory debtMarketIds = new uint256[](1);
        debtMarketIds[0] = debtMarketId;

        IDolomiteAccountRiskOverrideSetter.SingleCollateralRiskStruct[] memory structs =
            new IDolomiteAccountRiskOverrideSetter.SingleCollateralRiskStruct[](1);
        structs[0] = IDolomiteAccountRiskOverrideSetter.SingleCollateralRiskStruct({
            debtMarketIds: debtMarketIds,
            marginRatioOverride: IDolomiteStructs.Decimal({value: marginRatio}),
            liquidationRewardOverride: IDolomiteStructs.Decimal({value: liqReward})
        });

        vm.prank(dolomiteOwner);
        riskOverride.ownerSetRiskFeatureByMarketId(
            isoMarketId,
            IDolomiteAccountRiskOverrideSetter.RiskFeature.SINGLE_COLLATERAL_WITH_STRICT_DEBT,
            abi.encode(structs)
        );
    }

    function _addMarket(IDolomiteMarginAdminV2 admin_, address token) internal {
        admin_.ownerAddMarket(
            token,
            oracle,
            interestSetter,
            IDolomiteStructs.Decimal({value: 0}), // marginPremium
            IDolomiteStructs.Decimal({value: 0}), // spreadPremium
            0, // maxSupplyWei (unlimited)
            0, // maxBorrowWei (unlimited)
            IDolomiteStructs.Decimal({value: 0}), // earningsRateOverride (use global)
            false // isClosing
        );
    }

    function _wireRolesAndWhitelist() internal {
        vm.startPrank(admin);
        // Module is the sole minter/burner of the RedemptionClaimToken.
        rct.grantRole(AssetCxRolesLib.LIQUIDATION_MODULE_ROLE, address(module));
        // Closed-ecosystem transfer whitelist: module + DolomiteMargin.
        rct.addToWhitelist(address(module));
        rct.addToWhitelist(DOLOMITE_MARGIN);
        // Merchant burns AssetCX during redemption; the test also mints collateral for the operator.
        assetCX.grantRole(AssetCxRolesLib.MERCHANT_ROLE, address(merchant));
        assetCX.grantRole(AssetCxRolesLib.MERCHANT_ROLE, address(this));
        vm.stopPrank();
    }

    function _seedLiquidityAndPosition() internal {
        // USD1 lending liquidity is drawn from the live market (DolomiteMargin already holds a
        // large USD1 balance), so no additional supply is seeded here.

        // Mint BTCcx collateral (AssetCX) to the strategy operator.
        assetCX.mint(COLLATERAL_SUPPLY);
        assetCX.transfer(strategyOperator, COLLATERAL_SUPPLY);

        // Operator opens the borrow position: supply BTCcx and borrow USD1 in a single operation.
        vm.startPrank(strategyOperator);
        assetCX.approve(DOLOMITE_MARGIN, type(uint256).max);
        _operateSupplyAndBorrow(
            strategyOperator, ACCOUNT_A, assetCXMarketId, COLLATERAL_SUPPLY, usd1MarketId, USD1_BORROW
        );
        // Authorize the module as a local operator over the operator's Dolomite accounts.
        IDolomiteStructs.OperatorArg[] memory ops = new IDolomiteStructs.OperatorArg[](1);
        ops[0] = IDolomiteStructs.OperatorArg({operator: address(module), trusted: true});
        dolomite.setOperators(ops);
        vm.stopPrank();
    }

    // ─────────────────────────────── The test ─────────────────────────────────

    function test_fullLiquidation() public {
        // USD1 keeps its live oracle price; size expectations off it (RedemptionClaimToken and
        // BTCcx use the configured test prices).
        uint256 debtPrice = dolomite.getMarketPrice(usd1MarketId).value;

        // Sanity: position A starts with the expected collateral and debt.
        assertEq(_wei(strategyOperator, ACCOUNT_A, assetCXMarketId, true), COLLATERAL_SUPPLY, "A collateral pre");
        assertApproxEqAbs(_wei(strategyOperator, ACCOUNT_A, usd1MarketId, false), USD1_BORROW, USD1_DUST, "A debt pre");

        // ── Initiate: mint RedemptionClaimToken, swap collateral, redeem BTCcx ──
        vm.prank(liquidator);
        uint256 redemptionId =
            module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, USD1_BORROW, liquidator);

        DolomiteLiquidationModuleStorageLib.Liquidation memory liq = module.getLiquidation(redemptionId);
        assertTrue(liq.active, "liquidation active");
        uint256 tempAccount = liq.tempAccountNumber;
        uint256 rctSupplied = liq.redemptionClaimTokenSupplied;
        uint256 collateralRedeemed = liq.collateralRedeemed;

        // Expected sizing: mint = debtValue / (rctPrice × ratio) (rounded up);
        // collateral = debtValue × (1 + buffer) / collateralPrice.
        assertEq(rctSupplied, _ceilDiv(USD1_BORROW * debtPrice * 1e18, rctPrice * COLLATERAL_RATIO_WAD), "rct minted");
        assertEq(
            collateralRedeemed,
            USD1_BORROW * (debtPrice * (1e18 + BUFFER_WAD)) / (ASSETCX_PRICE * 1e18),
            "collateral withdrawn"
        );

        // Position A: debt fully moved off, collateral reduced by the withdrawn buffer amount.
        assertApproxEqAbs(_wei(strategyOperator, ACCOUNT_A, usd1MarketId, false), 0, USD1_DUST, "A debt cleared");
        assertEq(
            _wei(strategyOperator, ACCOUNT_A, assetCXMarketId, true),
            COLLATERAL_SUPPLY - collateralRedeemed,
            "A collateral post"
        );

        // Temporary position B: RedemptionClaimToken collateral and the moved USD1 debt.
        assertEq(_wei(address(module), tempAccount, rctMarketId, true), rctSupplied, "B rct collateral");
        assertApproxEqAbs(_wei(address(module), tempAccount, usd1MarketId, false), USD1_BORROW, USD1_DUST, "B debt");

        // Extracted BTCcx was redeemed through the merchant and burned; module holds none.
        // The redemption is recorded against the calling liquidator (the receiver), not the module.
        assertEq(assetCX.balanceOf(address(module)), 0, "module holds no BTCcx");
        assertEq(merchant.pendingAssetCxRedemption(liquidator), collateralRedeemed, "merchant redemption pending");
        assertEq(rct.totalSupply(), rctSupplied, "rct supply mid-flow");

        // ── Finalize: off-chain BTC → USD1 proceeds repay the temporary position ──
        // Supply more than the temporary debt. Position A's debt was fully liquidated, so nothing
        // is left for the surplus to repay and the entire excess is refunded to the caller.
        uint256 tempDebt = _wei(address(module), tempAccount, usd1MarketId, false);
        uint256 surplus = 1_000e18;
        uint256 provided = tempDebt + surplus;
        _mintUsd1(liquidator, provided);
        vm.startPrank(liquidator);
        usd1.approve(address(module), provided);
        module.finalizeLiquidationAndRepay(redemptionId, provided);
        vm.stopPrank();

        // Temporary position fully unwound and the RedemptionClaimToken burned.
        assertEq(_wei(address(module), tempAccount, usd1MarketId, false), 0, "B debt repaid");
        assertEq(_wei(address(module), tempAccount, rctMarketId, true), 0, "B rct withdrawn");
        assertEq(rct.totalSupply(), 0, "rct fully burned");
        assertEq(rct.balanceOf(address(module)), 0, "module holds no rct");

        // Surplus refunded in full (A had no remaining debt); module retains no debt token.
        assertApproxEqAbs(_wei(strategyOperator, ACCOUNT_A, usd1MarketId, false), 0, USD1_DUST, "A debt still clear");
        assertApproxEqAbs(usd1.balanceOf(liquidator), surplus, USD1_DUST, "surplus refunded to caller");
        assertApproxEqAbs(usd1.balanceOf(address(module)), 0, USD1_DUST, "module holds no debt token");
        assertEq(usd1.allowance(address(module), DOLOMITE_MARGIN), 0, "no dangling debt token approval");

        assertFalse(module.getLiquidation(redemptionId).active, "liquidation finalized");
    }

    /// @notice Taking over more debt than the position owes would flip its balance into a supply.
    function test_initiate_revertsWhenDebtAmountExceedsPositionDebt() public {
        uint256 positionDebt = _wei(strategyOperator, ACCOUNT_A, usd1MarketId, false);

        vm.startPrank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDolomiteLiquidationModule.DebtAmountExceedsPositionDebt.selector, positionDebt + 1, positionDebt
            )
        );
        module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, positionDebt + 1, liquidator);

        uint256 redemptionId =
            module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, positionDebt, liquidator);
        vm.stopPrank();

        assertTrue(module.getLiquidation(redemptionId).active, "the full debt is still accepted");
        assertEq(_wei(strategyOperator, ACCOUNT_A, usd1MarketId, false), 0, "A debt fully moved off");
    }

    /// @notice A plain `LIQUIDATOR_ROLE` caller may only act on a position that has reached the
    ///         configured liquidatable band; a caller that also holds `DEFAULT_ADMIN_ROLE` keeps
    ///         the override path open below it.
    function test_initiate_liquidatableLtvGate() public {
        uint256 tranche = 10_000e18;

        // A opens at ~50% LTV, inside the 45% band, so the plain liquidator is let through.
        assertGe(module.positionLtvWad(strategyOperator, ACCOUNT_A), LIQUIDATABLE_LTV_WAD, "A inside the band");
        vm.prank(liquidator);
        uint256 insideBandId =
            module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, tranche, liquidator);
        assertTrue(module.getLiquidation(insideBandId).active, "liquidator accepted inside the band");

        // Doubling BTCcx's price halves A's LTV, taking it below the band.
        oracle.setPrice(address(assetCX), ASSETCX_PRICE * 2);
        uint256 ltvWad = module.positionLtvWad(strategyOperator, ACCOUNT_A);
        assertLt(ltvWad, LIQUIDATABLE_LTV_WAD, "A below the band");

        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDolomiteLiquidationModule.PositionNotLiquidatable.selector, ltvWad, LIQUIDATABLE_LTV_WAD
            )
        );
        module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, tranche, liquidator);

        // The admin runs the same call on the same position.
        vm.startPrank(admin);
        module.grantRole(AssetCxRolesLib.LIQUIDATOR_ROLE, admin);
        uint256 overrideId = module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, tranche, admin);
        vm.stopPrank();
        assertTrue(module.getLiquidation(overrideId).active, "admin override accepted below the band");
    }

    /// @notice A partial (25%) liquidation of an unhealthy BTCcx position: only a quarter of the
    ///         debt and its proportional collateral are swapped out, restoring the borrow position
    ///         to health while leaving no dust in the module and fully unwinding the temporary one.
    function test_partialLiquidation() public {
        uint256 debtPrice = dolomite.getMarketPrice(usd1MarketId).value;

        // ── 1. Simulate the BTCcx price crashing so position A breaches the 15% isolation margin ──
        // Pick P/d = 56_875 (price ratio to USD1): A's collateralization is
        //   R0 = P/(50_000·d) ≈ 1.1375  (< 1.15 → unhealthy),
        // and after a 25% liquidation (12_500 debt + its buffered collateral removed):
        //   R1 = (P/d − 13_125)/37_500 ≈ 1.1667  (≥ 1.15 → healthy again).
        uint256 depressedPrice = 56_875 * debtPrice;
        oracle.setPrice(address(assetCX), depressedPrice);
        assertFalse(_isHealthy(strategyOperator, ACCOUNT_A), "A unhealthy pre-liquidation");

        // While A is unhealthy, the position owner cannot pull out even 1 wei of collateral on its own
        {
            IDolomiteStructs.AccountInfo[] memory accounts = new IDolomiteStructs.AccountInfo[](1);
            accounts[0] = IDolomiteStructs.AccountInfo({owner: strategyOperator, number: ACCOUNT_A});
            IDolomiteStructs.ActionArgs[] memory actions = new IDolomiteStructs.ActionArgs[](1);
            actions[0] = _withdraw(0, assetCXMarketId, 1, strategyOperator);

            bytes memory expectedRevert = abi.encodeWithSignature(
                "Error(string)",
                string(
                    abi.encodePacked(
                        "OperationImpl: Undercollateralized account <",
                        _toLowerHexString(strategyOperator),
                        ", ",
                        vm.toString(ACCOUNT_A),
                        ">"
                    )
                )
            );
            vm.prank(strategyOperator);
            vm.expectRevert(expectedRevert);
            dolomite.operate(accounts, actions);
        }

        // ── 2. Liquidate 25% of the outstanding debt ──
        uint256 liquidateAmount = USD1_BORROW / 4; // 12_500 USD1
        vm.prank(liquidator);
        uint256 redemptionId =
            module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, liquidateAmount, liquidator);

        DolomiteLiquidationModuleStorageLib.Liquidation memory liq = module.getLiquidation(redemptionId);
        assertTrue(liq.active, "liquidation active");
        uint256 tempAccount = liq.tempAccountNumber;
        uint256 rctSupplied = liq.redemptionClaimTokenSupplied;
        uint256 collateralRedeemed = liq.collateralRedeemed;

        // Sizing mirrors the full case but scaled to the liquidated quarter and the depressed price.
        assertEq(
            rctSupplied, _ceilDiv(liquidateAmount * debtPrice * 1e18, rctPrice * COLLATERAL_RATIO_WAD), "rct minted"
        );
        assertEq(
            collateralRedeemed,
            liquidateAmount * (debtPrice * (1e18 + BUFFER_WAD)) / (depressedPrice * 1e18),
            "collateral withdrawn"
        );

        // Only the liquidated quarter of the debt moved off A; the rest stays on the borrow position.
        assertApproxEqAbs(
            _wei(strategyOperator, ACCOUNT_A, usd1MarketId, false),
            USD1_BORROW - liquidateAmount,
            USD1_DUST,
            "A retains 75% debt"
        );
        assertEq(
            _wei(strategyOperator, ACCOUNT_A, assetCXMarketId, true),
            COLLATERAL_SUPPLY - collateralRedeemed,
            "A collateral reduced"
        );

        // Temporary position B carries the RedemptionClaimToken collateral and the moved debt.
        assertEq(_wei(address(module), tempAccount, rctMarketId, true), rctSupplied, "B rct collateral");
        assertApproxEqAbs(_wei(address(module), tempAccount, usd1MarketId, false), liquidateAmount, USD1_DUST, "B debt");

        // ── Finalize: repay exactly the temporary debt (no surplus in the partial case) ──
        uint256 tempDebt = _wei(address(module), tempAccount, usd1MarketId, false);
        _mintUsd1(liquidator, tempDebt);
        vm.startPrank(liquidator);
        usd1.approve(address(module), tempDebt);
        module.finalizeLiquidationAndRepay(redemptionId, tempDebt);
        vm.stopPrank();

        // ── 3. No tokens stuck in the module; temporary position fully cleared ──
        assertEq(assetCX.balanceOf(address(module)), 0, "module holds no BTCcx");
        assertEq(rct.balanceOf(address(module)), 0, "module holds no rct");
        assertEq(rct.totalSupply(), 0, "rct fully burned");
        assertApproxEqAbs(usd1.balanceOf(address(module)), 0, USD1_DUST, "module holds no debt token");

        assertEq(_wei(address(module), tempAccount, usd1MarketId, false), 0, "B debt cleared");
        assertEq(_wei(address(module), tempAccount, rctMarketId, true), 0, "B rct withdrawn");
        assertEq(
            dolomite.getAccountNumberOfMarketsWithBalances(
                IDolomiteStructs.AccountInfo({owner: address(module), number: tempAccount})
            ),
            0,
            "B has no remaining balances"
        );

        // ── 4. The remaining borrow position is healthy again (even at the depressed price) ──
        assertTrue(_isHealthy(strategyOperator, ACCOUNT_A), "A healthy post-liquidation");
        assertFalse(module.getLiquidation(redemptionId).active, "liquidation finalized");
    }

    /// @notice Two partial liquidations can be active on the same position at once. They use
    ///         independent temporary accounts and independent RedemptionClaimToken collateral, and
    ///         can be finalized out of order (liq 2 before liq 1) without either interfering with
    ///         the other — the second finalization only burns its own withdrawn tokens.
    function test_concurrentPartialLiquidations() public {
        uint256 debtPrice = dolomite.getMarketPrice(usd1MarketId).value;
        uint256 amount1 = 10_000e18;
        uint256 amount2 = 15_000e18;

        // ── Initiate liq 1, then liq 2 (both active on position A simultaneously) ──
        vm.prank(liquidator);
        uint256 id1 = module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, amount1, liquidator);
        vm.prank(liquidator);
        uint256 id2 = module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, amount2, liquidator);

        DolomiteLiquidationModuleStorageLib.Liquidation memory liq1 = module.getLiquidation(id1);
        DolomiteLiquidationModuleStorageLib.Liquidation memory liq2 = module.getLiquidation(id2);
        uint256 temp1 = liq1.tempAccountNumber;
        uint256 temp2 = liq2.tempAccountNumber;
        uint256 rct1 = liq1.redemptionClaimTokenSupplied;
        uint256 rct2 = liq2.redemptionClaimTokenSupplied;

        // The two liquidations are isolated: distinct temp accounts, both active, sized off amounts.
        assertTrue(temp1 != temp2, "distinct temp accounts");
        assertTrue(liq1.active && liq2.active, "both active");

        // Both pending liquidations are visible via the per-position view.
        {
            uint256[] memory pending = module.getLiquidationIds(strategyOperator, ACCOUNT_A);
            assertEq(pending.length, 2, "two pending liquidations");
            assertTrue(_containsId(pending, id1) && _containsId(pending, id2), "both ids listed");
        }
        assertEq(rct1, _ceilDiv(amount1 * debtPrice * 1e18, rctPrice * COLLATERAL_RATIO_WAD), "rct1 sized");
        assertEq(rct2, _ceilDiv(amount2 * debtPrice * 1e18, rctPrice * COLLATERAL_RATIO_WAD), "rct2 sized");
        assertEq(
            liq1.collateralRedeemed, amount1 * (debtPrice * (1e18 + BUFFER_WAD)) / (ASSETCX_PRICE * 1e18), "coll1 sized"
        );
        assertEq(
            liq2.collateralRedeemed, amount2 * (debtPrice * (1e18 + BUFFER_WAD)) / (ASSETCX_PRICE * 1e18), "coll2 sized"
        );

        // Each temp account holds only its own RedemptionClaimToken; the module holds none
        // (every minted token was supplied into its Dolomite temp account).
        assertEq(_wei(address(module), temp1, rctMarketId, true), rct1, "temp1 rct");
        assertEq(_wei(address(module), temp2, rctMarketId, true), rct2, "temp2 rct");
        assertEq(rct.balanceOf(address(module)), 0, "module holds no rct mid-flight");
        assertEq(rct.totalSupply(), rct1 + rct2, "rct supply = both liquidations");

        // A shed both liquidated debt slices; each slice sits on its own temp account.
        assertApproxEqAbs(
            _wei(strategyOperator, ACCOUNT_A, usd1MarketId, false),
            USD1_BORROW - amount1 - amount2,
            USD1_DUST,
            "A debt after both initiates"
        );
        assertApproxEqAbs(_wei(address(module), temp1, usd1MarketId, false), amount1, USD1_DUST, "temp1 debt");
        assertApproxEqAbs(_wei(address(module), temp2, usd1MarketId, false), amount2, USD1_DUST, "temp2 debt");

        // Both liquidations' buffered collateral was withdrawn from A (nothing else touches it).
        assertEq(
            _wei(strategyOperator, ACCOUNT_A, assetCXMarketId, true),
            COLLATERAL_SUPPLY - liq1.collateralRedeemed - liq2.collateralRedeemed,
            "A collateral after both initiates"
        );

        // ── Finalize liq 2 first ──
        uint256 tempDebt2 = _wei(address(module), temp2, usd1MarketId, false);
        _mintUsd1(liquidator, tempDebt2);
        vm.startPrank(liquidator);
        usd1.approve(address(module), tempDebt2);
        module.finalizeLiquidationAndRepay(id2, tempDebt2);
        vm.stopPrank();

        // liq 2 fully unwound; liq 1 completely untouched (its collateral was not burned).
        assertFalse(module.getLiquidation(id2).active, "liq2 finalized");
        assertTrue(module.getLiquidation(id1).active, "liq1 still active");
        assertEq(_wei(address(module), temp2, rctMarketId, true), 0, "temp2 rct withdrawn");
        assertEq(_wei(address(module), temp2, usd1MarketId, false), 0, "temp2 debt cleared");
        assertEq(_wei(address(module), temp1, rctMarketId, true), rct1, "temp1 rct intact");
        assertEq(rct.totalSupply(), rct1, "only liq1 rct remains");
        assertEq(rct.balanceOf(address(module)), 0, "module holds no rct after finalize2");

        // liq 2 removed from the per-position view; liq 1 still pending.
        {
            uint256[] memory pendingAfter2 = module.getLiquidationIds(strategyOperator, ACCOUNT_A);
            assertEq(pendingAfter2.length, 1, "one pending after finalize2");
            assertTrue(_containsId(pendingAfter2, id1), "liq1 still pending");
            assertFalse(_containsId(pendingAfter2, id2), "liq2 removed");
        }

        // ── Finalize liq 1 last ──
        uint256 tempDebt1 = _wei(address(module), temp1, usd1MarketId, false);
        _mintUsd1(liquidator, tempDebt1);
        vm.startPrank(liquidator);
        usd1.approve(address(module), tempDebt1);
        module.finalizeLiquidationAndRepay(id1, tempDebt1);
        vm.stopPrank();

        // Both liquidations fully unwound; nothing stuck; both temp accounts empty.
        assertFalse(module.getLiquidation(id1).active, "liq1 finalized");
        // Both ids removed from the per-position view once fully repaid.
        assertEq(module.getLiquidationIds(strategyOperator, ACCOUNT_A).length, 0, "no pending after both finalized");
        assertEq(rct.totalSupply(), 0, "all rct burned");
        assertEq(rct.balanceOf(address(module)), 0, "module holds no rct");
        assertEq(assetCX.balanceOf(address(module)), 0, "module holds no BTCcx");
        assertApproxEqAbs(usd1.balanceOf(address(module)), 0, USD1_DUST, "module holds no debt token");
        assertEq(
            dolomite.getAccountNumberOfMarketsWithBalances(
                IDolomiteStructs.AccountInfo({owner: address(module), number: temp1})
            ),
            0,
            "temp1 empty"
        );
        assertEq(
            dolomite.getAccountNumberOfMarketsWithBalances(
                IDolomiteStructs.AccountInfo({owner: address(module), number: temp2})
            ),
            0,
            "temp2 empty"
        );

        // A keeps the un-liquidated remainder (each finalize repaid only its temp debt, no surplus).
        assertApproxEqAbs(
            _wei(strategyOperator, ACCOUNT_A, usd1MarketId, false),
            USD1_BORROW - amount1 - amount2,
            USD1_DUST,
            "A remaining debt"
        );
        // Finalization repays debt only; A's remaining collateral is unchanged from post-initiate.
        assertEq(
            _wei(strategyOperator, ACCOUNT_A, assetCXMarketId, true),
            COLLATERAL_SUPPLY - liq1.collateralRedeemed - liq2.collateralRedeemed,
            "A remaining collateral"
        );
    }

    /// @notice If the borrow position's remaining debt is repaid out-of-band between initiate and
    ///         finalize, finalization still unwinds the temporary position cleanly. There is no
    ///         debt left on A for the surplus to service, so the whole surplus is refunded and A's
    ///         collateral is left untouched.
    function test_finalize_afterBorrowPositionFullyRepaid() public {
        vm.prank(liquidator);
        uint256 id = module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, 10_000e18, liquidator);
        uint256 temp = module.getLiquidation(id).tempAccountNumber;
        uint256 collateralBefore = _wei(strategyOperator, ACCOUNT_A, assetCXMarketId, true);

        // Position owner repays A's remaining debt in full (collateral left in place).
        _fullyRepayPositionA(false);
        assertEq(_wei(strategyOperator, ACCOUNT_A, usd1MarketId, false), 0, "A debt fully repaid");
        assertEq(_wei(strategyOperator, ACCOUNT_A, assetCXMarketId, true), collateralBefore, "A keeps collateral");

        _finalizeWithSurplusExpectFullRefund(id, temp);

        // A is left exactly as the owner closed it: no debt, collateral untouched by finalize.
        assertEq(_wei(strategyOperator, ACCOUNT_A, usd1MarketId, false), 0, "A debt still zero");
        assertEq(_wei(strategyOperator, ACCOUNT_A, assetCXMarketId, true), collateralBefore, "A collateral untouched");
    }

    /// @notice If the borrow position is fully closed (debt repaid AND all collateral withdrawn)
    ///         between initiate and finalize, finalization still unwinds the temporary position
    ///         and refunds the surplus in full without touching the now-empty position A.
    function test_finalize_afterBorrowPositionFullyClosed() public {
        vm.prank(liquidator);
        uint256 id = module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, 10_000e18, liquidator);
        uint256 temp = module.getLiquidation(id).tempAccountNumber;

        // Position owner repays the debt and withdraws all collateral, emptying account A.
        _fullyRepayPositionA(true);
        assertEq(
            dolomite.getAccountNumberOfMarketsWithBalances(
                IDolomiteStructs.AccountInfo({owner: strategyOperator, number: ACCOUNT_A})
            ),
            0,
            "A fully closed"
        );

        _finalizeWithSurplusExpectFullRefund(id, temp);

        // A stays empty; finalization never touched it.
        assertEq(
            dolomite.getAccountNumberOfMarketsWithBalances(
                IDolomiteStructs.AccountInfo({owner: strategyOperator, number: ACCOUNT_A})
            ),
            0,
            "A still closed"
        );
    }

    /// @notice A liquidation can be finalized across several partial tranches: each repays part of
    ///         the temporary debt and burns the RedemptionClaimToken freed above the backing of the
    ///         remaining debt, staying active until the closing tranche clears it, at which point
    ///         the record is deleted.
    function test_finalize_inPartialTranches() public {
        uint256 debtPrice = dolomite.getMarketPrice(usd1MarketId).value;

        // Move A's full debt onto temporary position B.
        vm.prank(liquidator);
        uint256 id = module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, USD1_BORROW, liquidator);
        uint256 temp = module.getLiquidation(id).tempAccountNumber;
        uint256 rctSupplied = module.getLiquidation(id).redemptionClaimTokenSupplied;
        assertEq(rct.totalSupply(), rctSupplied, "rct minted");

        // The pending liquidation is visible via the per-position view right after initiation.
        uint256[] memory pendingAfterInitiate = module.getLiquidationIds(strategyOperator, ACCOUNT_A);
        assertEq(pendingAfterInitiate.length, 1, "one pending liquidation");
        assertEq(pendingAfterInitiate[0], id, "pending id listed");

        // ── Tranche 1: repay 20k of the temporary debt (partial, stays active) ──
        uint256 tranche1 = 20_000e18;
        uint256 tempDebtBefore = _wei(address(module), temp, usd1MarketId, false);
        // Everything held above the backing of the debt B is left with (ceil), mirrors the lib.
        uint256 release1 =
            rctSupplied - _ceilDiv((tempDebtBefore - tranche1) * debtPrice * 1e18, rctPrice * COLLATERAL_RATIO_WAD);

        _mintUsd1(liquidator, tranche1);
        vm.startPrank(liquidator);
        usd1.approve(address(module), tranche1);
        module.finalizeLiquidationAndRepay(id, tranche1);
        vm.stopPrank();

        // Liquidation remains active; only debtRepaid advanced; the freed RCT slice was burned.
        assertTrue(module.getLiquidation(id).active, "active after partial");
        assertEq(module.getLiquidation(id).debtRepaid, tranche1, "debtRepaid tracks tranche 1");
        assertEq(rct.totalSupply(), rctSupplied - release1, "freed rct burned");
        assertEq(rct.balanceOf(address(module)), 0, "module holds no rct after partial");
        assertApproxEqAbs(usd1.balanceOf(address(module)), 0, USD1_DUST, "module holds no debt token after partial");
        assertApproxEqAbs(
            _wei(address(module), temp, usd1MarketId, false), tempDebtBefore - tranche1, USD1_DUST, "B debt reduced"
        );
        assertEq(_wei(address(module), temp, rctMarketId, true), rctSupplied - release1, "B rct reduced");
        // A's collateral was extracted at initiate and is untouched by a partial finalize.
        assertGt(_wei(strategyOperator, ACCOUNT_A, assetCXMarketId, true), 0, "A retains collateral");

        // Still pending after a partial finalization — removed only once fully repaid.
        assertTrue(
            _containsId(module.getLiquidationIds(strategyOperator, ACCOUNT_A), id), "still pending after partial"
        );

        // ── Tranche 2: repay the remaining temporary debt in full (closing tranche) ──
        uint256 remaining = _wei(address(module), temp, usd1MarketId, false);
        _mintUsd1(liquidator, remaining);
        vm.startPrank(liquidator);
        usd1.approve(address(module), remaining);
        module.finalizeLiquidationAndRepay(id, remaining);
        vm.stopPrank();

        // Fully closed: all RCT burned, temp position empty, nothing stuck, debt fully repaid.
        // The record is cleared once fully unwound, so getLiquidation returns a zeroed struct.
        assertFalse(module.getLiquidation(id).active, "finalized after closing tranche");
        assertEq(module.getLiquidation(id).positionOwner, address(0), "liquidation record cleared");
        assertEq(rct.totalSupply(), 0, "all rct burned");
        assertEq(rct.balanceOf(address(module)), 0, "module holds no rct");
        assertEq(assetCX.balanceOf(address(module)), 0, "module holds no BTCcx");
        assertApproxEqAbs(usd1.balanceOf(address(module)), 0, USD1_DUST, "module holds no debt token");
        assertEq(_wei(address(module), temp, usd1MarketId, false), 0, "B debt cleared");
        assertEq(_wei(address(module), temp, rctMarketId, true), 0, "B rct cleared");

        // Removed from the per-position view once fully repaid and the record cleared.
        assertEq(module.getLiquidationIds(strategyOperator, ACCOUNT_A).length, 0, "no pending after full repay");
        assertFalse(_containsId(module.getLiquidationIds(strategyOperator, ACCOUNT_A), id), "id no longer listed");
    }

    /// @notice A partial tranche stays affordable after the temporary position's debt has accrued
    ///         interest, and restores the position to the configured collateral ratio.
    /// @dev Regression guard. The release used to be sized off the debt repaid at the CONFIGURED
    ///      ratio — the rate the mint was sized at against the ORIGINAL debt — so once that debt had
    ///      grown, each tranche withdrew ~1/0.98 of collateral per unit of debt it repaid while only
    ///      ~1.03% of slack existed above Dolomite's 101% isolation margin. That consumed B's
    ///      cushion ~97x faster than the interest causing it (max tranche ≈ `debt − 97.04 ×
    ///      interest`), and Dolomite rejected the operate with "OperationImpl: Undercollateralized
    ///      account". Sizing the retained collateral off the LIVE residual debt absorbs the interest
    ///      into the tranche instead.
    function test_finalize_partialTrancheAfterInterestAccrual() public {
        _freezeUsd1Oracle();

        vm.prank(liquidator);
        uint256 id = module.initiateLiquidationCollateralSwap(strategyOperator, ACCOUNT_A, USD1_BORROW, liquidator);
        uint256 temp = module.getLiquidation(id).tempAccountNumber;
        uint256 rctSupplied = module.getLiquidation(id).redemptionClaimTokenSupplied;
        uint256 debt0 = _wei(address(module), temp, usd1MarketId, false);

        // Accrue 0.7% of interest on B's debt: enough that the old sizing put a 20k tranche out of
        // reach entirely, while B is still healthy (2.04% cushion against the 1% margin).
        uint256 elapsedDays = _warpUntilDebtGrows(temp, debt0, 70);
        uint256 tempDebtBefore = _wei(address(module), temp, usd1MarketId, false);
        assertGt(elapsedDays, 0, "time warped");
        assertGe(tempDebtBefore, debt0 + debt0 * 70 / 10_000, "B debt accrued 0.7%");
        assertTrue(_isHealthy(address(module), temp), "B healthy before the tranche");

        uint256 tranche = 20_000e18;
        uint256 residualBacking = _ceilDiv((tempDebtBefore - tranche) * 1e18, COLLATERAL_RATIO_WAD);
        uint256 expectedRelease = rctSupplied - residualBacking;
        // Strictly below what the old sizing released for the same repayment — that over-release,
        // charged against a cushion the accrued interest had already eaten into, is the bug.
        assertLt(expectedRelease, tranche * 1e18 / COLLATERAL_RATIO_WAD, "interest absorbed by the tranche");

        _mintUsd1(liquidator, tranche);
        vm.startPrank(liquidator);
        usd1.approve(address(module), tranche);
        module.finalizeLiquidationAndRepay(id, tranche);
        vm.stopPrank();

        assertTrue(module.getLiquidation(id).active, "active after partial");
        assertEq(module.getLiquidation(id).debtRepaid, tranche, "debtRepaid tracks the tranche");
        assertEq(rct.totalSupply(), rctSupplied - expectedRelease, "freed rct burned");
        assertEq(_wei(address(module), temp, rctMarketId, true), residualBacking, "B left at the residual backing");

        // B is back at the collateralization it was opened with, above the 1% isolation margin, so
        // the next tranche is as affordable as the first: tranche capacity no longer decays.
        uint256 tempDebtAfter = _wei(address(module), temp, usd1MarketId, false);
        assertApproxEqRel(
            residualBacking * 1e18 / tempDebtAfter,
            1e18 * 1e18 / COLLATERAL_RATIO_WAD,
            1e12, // 1e-6 %
            "collateralization restored to 1 / collateralRatio"
        );
        assertGt(residualBacking * 1e18 / tempDebtAfter, rctSupplied * 1e18 / tempDebtBefore, "cushion repaired");
        assertTrue(_isHealthy(address(module), temp), "B healthy after the tranche");

        // The closing tranche still unwinds B completely and satisfies the mint/burn invariant.
        _mintUsd1(liquidator, tempDebtAfter);
        vm.startPrank(liquidator);
        usd1.approve(address(module), tempDebtAfter);
        module.finalizeLiquidationAndRepay(id, tempDebtAfter);
        vm.stopPrank();

        assertFalse(module.getLiquidation(id).active, "finalized after the closing tranche");
        assertEq(rct.totalSupply(), 0, "all rct burned");
        assertEq(_wei(address(module), temp, rctMarketId, true), 0, "B rct cleared");
        assertEq(_wei(address(module), temp, usd1MarketId, false), 0, "B debt cleared");
    }

    // ───────────────────────── Isolation-mode setup tests, test that the isolation mode is configured correctly ──────────────────────

    /// @notice BTCcx and the RedemptionClaimToken are registered on the live production risk
    ///         override setter as isolation-mode level 3 (SINGLE_COLLATERAL_WITH_STRICT_DEBT),
    ///         each restricted to USD1 debt.
    function test_isolationModeConfiguration() public view {
        _assertSingleCollateralUsd1(assetCXMarketId, ASSETCX_ISO_MARGIN_RATIO, ASSETCX_ISO_LIQ_REWARD);
        _assertSingleCollateralUsd1(rctMarketId, RCT_ISO_MARGIN_RATIO, RCT_ISO_LIQ_REWARD);
    }

    function _assertSingleCollateralUsd1(uint256 isoMarketId, uint256 marginRatio, uint256 liqReward) internal view {
        assertEq(
            uint256(riskOverride.getRiskFeatureByMarketId(isoMarketId)),
            uint256(IDolomiteAccountRiskOverrideSetter.RiskFeature.SINGLE_COLLATERAL_WITH_STRICT_DEBT),
            "risk feature"
        );
        IDolomiteAccountRiskOverrideSetter.SingleCollateralRiskStruct[] memory structs =
            riskOverride.getRiskFeatureForSingleCollateralByMarketId(isoMarketId);
        assertEq(structs.length, 1, "one risk struct");
        assertEq(structs[0].debtMarketIds.length, 1, "one debt market");
        assertEq(structs[0].debtMarketIds[0], usd1MarketId, "debt market = USD1");
        assertEq(structs[0].marginRatioOverride.value, marginRatio, "margin ratio");
        assertEq(structs[0].liquidationRewardOverride.value, liqReward, "liquidation reward");
    }

    /// @notice The sanctioned composition — BTCcx as sole collateral borrowing USD1 — is allowed.
    function test_isolation_allowsUsd1DebtAgainstBTCcx() public {
        _mintAssetCxTo(strategyOperator, COLLATERAL_SUPPLY);
        vm.startPrank(strategyOperator);
        assetCX.approve(DOLOMITE_MARGIN, type(uint256).max);
        _operateSupplyAndBorrow(strategyOperator, 7, assetCXMarketId, COLLATERAL_SUPPLY, usd1MarketId, USD1_BORROW);
        vm.stopPrank();

        assertApproxEqAbs(_wei(strategyOperator, 7, usd1MarketId, false), USD1_BORROW, USD1_DUST, "USD1 borrowed");
        assertEq(_wei(strategyOperator, 7, assetCXMarketId, true), COLLATERAL_SUPPLY, "BTCcx collateral");
    }

    /// @notice Adding a second collateral (WETH) alongside isolation-mode BTCcx is rejected.
    function test_isolation_revertsWhenMixingCollateral() public {
        address weth = dolomite.getMarketTokenAddress(0);
        _mintAssetCxTo(strategyOperator, COLLATERAL_SUPPLY);
        deal(weth, strategyOperator, 1e18);

        vm.startPrank(strategyOperator);
        assetCX.approve(DOLOMITE_MARGIN, type(uint256).max);
        IERC20(weth).approve(DOLOMITE_MARGIN, type(uint256).max);

        IDolomiteStructs.AccountInfo[] memory accounts = new IDolomiteStructs.AccountInfo[](1);
        accounts[0] = IDolomiteStructs.AccountInfo({owner: strategyOperator, number: 8});
        IDolomiteStructs.ActionArgs[] memory actions = new IDolomiteStructs.ActionArgs[](3);
        actions[0] = _deposit(0, assetCXMarketId, COLLATERAL_SUPPLY, strategyOperator);
        actions[1] = _deposit(0, 0, 0.1e18, strategyOperator); // second collateral: WETH (market 0)
        actions[2] = _withdraw(0, usd1MarketId, USD1_BORROW, strategyOperator);

        // The isolation asset (BTCcx) is not the sole collateral, so no single-collateral risk
        // param matches and the live setter reverts.
        vm.expectRevert(
            abi.encodeWithSignature("Error(string)", "AccountRiskOverrideSetter: Could not find risk param")
        );
        dolomite.operate(accounts, actions);
        vm.stopPrank();
    }

    /// @notice Borrowing a non-USD1 asset (WETH) against isolation-mode BTCcx is rejected.
    function test_isolation_revertsWhenBorrowingDisallowedDebt() public {
        _mintAssetCxTo(strategyOperator, COLLATERAL_SUPPLY);

        vm.startPrank(strategyOperator);
        assetCX.approve(DOLOMITE_MARGIN, type(uint256).max);

        IDolomiteStructs.AccountInfo[] memory accounts = new IDolomiteStructs.AccountInfo[](1);
        accounts[0] = IDolomiteStructs.AccountInfo({owner: strategyOperator, number: 9});
        IDolomiteStructs.ActionArgs[] memory actions = new IDolomiteStructs.ActionArgs[](2);
        actions[0] = _deposit(0, assetCXMarketId, COLLATERAL_SUPPLY, strategyOperator);
        actions[1] = _withdraw(0, 0, 0.01e18, strategyOperator); // borrow WETH (market 0), not USD1

        // WETH is not a whitelisted debt for BTCcx, so no single-collateral risk param matches.
        vm.expectRevert(
            abi.encodeWithSignature("Error(string)", "AccountRiskOverrideSetter: Could not find risk param")
        );
        dolomite.operate(accounts, actions);
        vm.stopPrank();
    }

    // ─────────────────────────────── Helpers ──────────────────────────────────

    /// @dev Mints BTCcx (AssetCX) to `to`; the test holds MERCHANT_ROLE so it can mint.
    function _mintAssetCxTo(address to, uint256 amount) internal {
        assetCX.mint(amount);
        assetCX.transfer(to, amount);
    }

    /// @dev True if `ids` contains `id` (the per-position view returns ids unordered).
    function _containsId(uint256[] memory ids, uint256 id) internal pure returns (bool) {
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == id) return true;
        }
        return false;
    }

    /// @dev Signed token balance for a Dolomite account; returns the value when its sign matches
    ///      `wantPositive` (collateral) or `!wantPositive` (debt), else 0.
    function _wei(address owner, uint256 number, uint256 marketId, bool wantPositive) internal view returns (uint256) {
        IDolomiteStructs.Wei memory bal =
            dolomite.getAccountWei(IDolomiteStructs.AccountInfo({owner: owner, number: number}), marketId);
        if (bal.sign == wantPositive) return bal.value;
        return 0;
    }

    /// @dev True if a Dolomite account is collateralized. Dolomite exposes no public health view
    ///      (the core only enforces it internally during `operate`), so this reproduces its check
    ///      using Dolomite's own inputs: margin-premium-adjusted values from
    ///      {IDolomiteMargin.getAdjustedAccountValues} and the effective margin ratio from the live
    ///      risk-override setter ({getAccountRiskOverride}, falling back to the global margin ratio),
    ///      combined via the same formula as BaseLiquidatorProxy._isCollateralized:
    ///      `supplyValue >= borrowValue + borrowValue × ratio`.
    function _isHealthy(address owner, uint256 number) internal view returns (bool) {
        IDolomiteStructs.AccountInfo memory account = IDolomiteStructs.AccountInfo({owner: owner, number: number});
        (IDolomiteStructs.MonetaryValue memory supplyValue, IDolomiteStructs.MonetaryValue memory borrowValue) =
            dolomite.getAdjustedAccountValues(account);
        if (borrowValue.value == 0) return true;

        (IDolomiteStructs.Decimal memory marginRatioOverride,) = riskOverride.getAccountRiskOverride(account);
        uint256 ratio = marginRatioOverride.value == 0 ? dolomite.getMarginRatio().value : marginRatioOverride.value;

        uint256 requiredMargin = borrowValue.value * ratio / 1e18;
        return supplyValue.value >= borrowValue.value + requiredMargin;
    }

    /// @dev Mirrors USD1's live price onto the constant-price test oracle and repoints its market at
    ///      it, so that warping far enough forward to accrue interest does not trip the live
    ///      Chainlink feed's staleness check. The price itself is unchanged at the swap.
    function _freezeUsd1Oracle() internal {
        uint256 live = dolomite.getMarketPrice(usd1MarketId).value;
        oracle.setPrice(USD1, live);
        vm.prank(dolomiteOwner);
        IDolomiteMarginAdminV2(DOLOMITE_MARGIN).ownerSetPriceOracle(usd1MarketId, oracle);
        assertEq(dolomite.getMarketPrice(usd1MarketId).value, live, "usd1 price mirrored");
    }

    /// @dev Warps a day at a time until the module account `number`'s USD1 debt has grown `targetBps`
    ///      above `principal`. USD1 keeps its production interest setter, so this accrues at the live
    ///      rate (~0.94 bps/day at the pinned block); requires {_freezeUsd1Oracle} first.
    function _warpUntilDebtGrows(uint256 number, uint256 principal, uint256 targetBps)
        internal
        returns (uint256 elapsedDays)
    {
        uint256 target = principal + principal * targetBps / 10_000;
        while (_wei(address(module), number, usd1MarketId, false) < target && elapsedDays < 3650) {
            vm.warp(block.timestamp + 1 days);
            ++elapsedDays;
        }
    }

    /// @dev Mints live USD1 to `to` by impersonating the token owner (USD1's `mint` credits the
    ///      caller, so the owner mints and forwards).
    function _mintUsd1(address to, uint256 amount) internal {
        vm.startPrank(USD1_OWNER);
        IUSD1Mintable(USD1).mint(amount);
        usd1.transfer(to, amount);
        vm.stopPrank();
    }

    /// @dev Position owner repays account A's remaining USD1 debt in full (to Par 0) and,
    ///      when `alsoWithdrawCollateral`, withdraws all BTCcx too — emptying the position.
    function _fullyRepayPositionA(bool alsoWithdrawCollateral) internal {
        uint256 debt = _wei(strategyOperator, ACCOUNT_A, usd1MarketId, false);
        _mintUsd1(strategyOperator, debt + USD1_DUST);

        vm.startPrank(strategyOperator);
        usd1.approve(DOLOMITE_MARGIN, type(uint256).max);

        IDolomiteStructs.AccountInfo[] memory accounts = new IDolomiteStructs.AccountInfo[](1);
        accounts[0] = IDolomiteStructs.AccountInfo({owner: strategyOperator, number: ACCOUNT_A});
        IDolomiteStructs.ActionArgs[] memory actions = new IDolomiteStructs.ActionArgs[](alsoWithdrawCollateral ? 2 : 1);
        actions[0] = _depositTargetZero(usd1MarketId, strategyOperator);
        if (alsoWithdrawCollateral) actions[1] = _withdrawTargetZero(assetCXMarketId, strategyOperator);
        dolomite.operate(accounts, actions);
        vm.stopPrank();
    }

    /// @dev Finalizes `id` with a surplus above the temporary debt and asserts the temporary
    ///      position is fully unwound, the module retains nothing, and — because position A has no
    ///      debt left to service — the entire surplus is refunded to the caller.
    function _finalizeWithSurplusExpectFullRefund(uint256 id, uint256 temp) internal {
        uint256 tempDebt = _wei(address(module), temp, usd1MarketId, false);
        uint256 surplus = 1_000e18;
        uint256 provided = tempDebt + surplus;
        _mintUsd1(liquidator, provided);
        vm.startPrank(liquidator);
        usd1.approve(address(module), provided);
        module.finalizeLiquidationAndRepay(id, provided);
        vm.stopPrank();

        assertFalse(module.getLiquidation(id).active, "finalized");
        assertEq(_wei(address(module), temp, usd1MarketId, false), 0, "temp debt cleared");
        assertEq(_wei(address(module), temp, rctMarketId, true), 0, "temp rct withdrawn");
        assertEq(rct.totalSupply(), 0, "rct burned");
        assertEq(rct.balanceOf(address(module)), 0, "module holds no rct");
        assertEq(assetCX.balanceOf(address(module)), 0, "module holds no BTCcx");
        assertApproxEqAbs(usd1.balanceOf(liquidator), surplus, USD1_DUST, "full surplus refunded");
        assertApproxEqAbs(usd1.balanceOf(address(module)), 0, USD1_DUST, "module holds no debt token");
    }

    function _operateSupplyAndBorrow(
        address owner,
        uint256 number,
        uint256 supplyMarketId,
        uint256 supplyAmount,
        uint256 borrowMarketId,
        uint256 borrowAmount
    ) internal {
        IDolomiteStructs.AccountInfo[] memory accounts = new IDolomiteStructs.AccountInfo[](1);
        accounts[0] = IDolomiteStructs.AccountInfo({owner: owner, number: number});

        IDolomiteStructs.ActionArgs[] memory actions = new IDolomiteStructs.ActionArgs[](2);
        actions[0] = _deposit(0, supplyMarketId, supplyAmount, owner);
        actions[1] = _withdraw(0, borrowMarketId, borrowAmount, owner);
        dolomite.operate(accounts, actions);
    }

    function _deposit(uint256 accountId, uint256 marketId, uint256 amount, address from)
        internal
        pure
        returns (IDolomiteStructs.ActionArgs memory)
    {
        return IDolomiteStructs.ActionArgs({
            actionType: IDolomiteStructs.ActionType.Deposit,
            accountId: accountId,
            amount: IDolomiteStructs.AssetAmount({
                sign: true,
                denomination: IDolomiteStructs.AssetDenomination.Wei,
                ref: IDolomiteStructs.AssetReference.Delta,
                value: amount
            }),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: from,
            otherAccountId: 0,
            data: ""
        });
    }

    function _withdraw(uint256 accountId, uint256 marketId, uint256 amount, address to)
        internal
        pure
        returns (IDolomiteStructs.ActionArgs memory)
    {
        return IDolomiteStructs.ActionArgs({
            actionType: IDolomiteStructs.ActionType.Withdraw,
            accountId: accountId,
            amount: IDolomiteStructs.AssetAmount({
                sign: false,
                denomination: IDolomiteStructs.AssetDenomination.Wei,
                ref: IDolomiteStructs.AssetReference.Delta,
                value: amount
            }),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: to,
            otherAccountId: 0,
            data: ""
        });
    }

    /// @dev Deposit action that brings the account's balance in `marketId` exactly to zero
    ///      (Wei/Target 0), pulling the needed tokens from `from` — used to repay a debt in full.
    function _depositTargetZero(uint256 marketId, address from)
        internal
        pure
        returns (IDolomiteStructs.ActionArgs memory)
    {
        return IDolomiteStructs.ActionArgs({
            actionType: IDolomiteStructs.ActionType.Deposit,
            accountId: 0,
            amount: IDolomiteStructs.AssetAmount({
                sign: true,
                denomination: IDolomiteStructs.AssetDenomination.Wei,
                ref: IDolomiteStructs.AssetReference.Target,
                value: 0
            }),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: from,
            otherAccountId: 0,
            data: ""
        });
    }

    /// @dev Withdrawal action that empties the account's balance in `marketId` (Wei/Target 0),
    ///      sending the tokens to `to` — used to withdraw all collateral.
    function _withdrawTargetZero(uint256 marketId, address to)
        internal
        pure
        returns (IDolomiteStructs.ActionArgs memory)
    {
        return IDolomiteStructs.ActionArgs({
            actionType: IDolomiteStructs.ActionType.Withdraw,
            accountId: 0,
            amount: IDolomiteStructs.AssetAmount({
                sign: true,
                denomination: IDolomiteStructs.AssetDenomination.Wei,
                ref: IDolomiteStructs.AssetReference.Target,
                value: 0
            }),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: to,
            otherAccountId: 0,
            data: ""
        });
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /// @dev Lowercase `0x`-prefixed hex of an address, matching how Dolomite's Require formats
    ///      account owners in its revert messages.
    function _toLowerHexString(address account) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 data = bytes20(account);
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i]) >> 4];
            str[3 + i * 2] = alphabet[uint8(data[i]) & 0x0f];
        }
        return string(str);
    }
}
