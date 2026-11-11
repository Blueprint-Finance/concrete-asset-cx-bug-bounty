// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC4626Mock} from "@concrete-xyz/earn-v2-core/test/mock/ERC4626Mock.sol";

import {AssetCX} from "../../src/AssetCX.sol";
import {ConcreteMerchant} from "../../src/merchant/ConcreteMerchant.sol";
import {DolomiteLiquidationModule} from "../../src/liquidations/DolomiteLiquidationModule.sol";
import {IDolomiteLiquidationModule} from "../../src/interface/IDolomiteLiquidationModule.sol";

/// @title DolomiteLiquidationModuleTest
/// @notice Unit tests for {DolomiteLiquidationModule}'s configuration validation
///         (`initialize`, `setCollateralRatio`, `setBuffer`) that do not require a
///         live Dolomite fork, since none of that validation touches DolomiteMargin.
contract DolomiteLiquidationModuleTest is Test {
    uint256 internal constant WAD = 1e18;

    address internal admin = makeAddr("admin");
    address internal liquidator = makeAddr("liquidator");
    address internal dolomiteMargin = makeAddr("dolomiteMargin");
    address internal redemptionClaimToken = makeAddr("redemptionClaimToken");
    address internal debtToken = makeAddr("debtToken");

    address internal merchant; // fully initialized ConcreteMerchant, valid collateral token
    address internal moduleImpl; // shared implementation, deployed once so revert tests only need
    // to CREATE the proxy after `vm.expectRevert` (its "next call" check only sees that CREATE)

    function setUp() public {
        merchant = _deployInitializedMerchant();
        moduleImpl = address(new DolomiteLiquidationModule());
    }

    // ─────────────────────────────── initialize() ─────────────────────────────

    function test_initialize_revertsWhenCollateralRatioIsZero() public {
        IDolomiteLiquidationModule.InitParams memory params = _validParams();
        params.collateralRatioWad = 0;
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, 0));
        new ERC1967Proxy(moduleImpl, abi.encodeCall(DolomiteLiquidationModule.initialize, (params)));
    }

    /// @notice A 100% (WAD) collateral ratio leaves the mint with zero margin over the debt it
    ///         backs, so accrued interest alone can push the position below full backing.
    function test_initialize_revertsWhenCollateralRatioEqualsWad() public {
        IDolomiteLiquidationModule.InitParams memory params = _validParams();
        params.collateralRatioWad = WAD;
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, WAD));
        new ERC1967Proxy(moduleImpl, abi.encodeCall(DolomiteLiquidationModule.initialize, (params)));
    }

    function test_initialize_revertsWhenCollateralRatioExceedsWad() public {
        IDolomiteLiquidationModule.InitParams memory params = _validParams();
        params.collateralRatioWad = WAD + 1;
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, WAD + 1));
        new ERC1967Proxy(moduleImpl, abi.encodeCall(DolomiteLiquidationModule.initialize, (params)));
    }

    /// @notice A zero buffer sizes the withdrawn collateral at exactly the oracle value of the
    ///         moved debt, leaving no margin for settlement-window interest and fees.
    function test_initialize_revertsWhenBufferIsZero() public {
        IDolomiteLiquidationModule.InitParams memory params = _validParams();
        params.bufferWad = 0;
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, 0));
        new ERC1967Proxy(moduleImpl, abi.encodeCall(DolomiteLiquidationModule.initialize, (params)));
    }

    function test_initialize_revertsWhenBufferExceedsWad() public {
        IDolomiteLiquidationModule.InitParams memory params = _validParams();
        params.bufferWad = WAD + 1;
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, WAD + 1));
        new ERC1967Proxy(moduleImpl, abi.encodeCall(DolomiteLiquidationModule.initialize, (params)));
    }

    /// @notice An uninitialized merchant proxy's `assetCX()` returns the zero address; the module
    ///         must reject it at initialization instead of silently wiring up a zero collateral token.
    function test_initialize_revertsWhenMerchantAssetCxIsZero() public {
        ConcreteMerchant uninitializedMerchant =
            ConcreteMerchant(address(new ERC1967Proxy(address(new ConcreteMerchant()), "")));

        IDolomiteLiquidationModule.InitParams memory params = _validParams();
        params.merchant = address(uninitializedMerchant);
        vm.expectRevert(IDolomiteLiquidationModule.ZeroAddress.selector);
        new ERC1967Proxy(moduleImpl, abi.encodeCall(DolomiteLiquidationModule.initialize, (params)));
    }

    function test_initialize_succeedsWithValidParams() public {
        IDolomiteLiquidationModule.InitParams memory params = _validParams();
        DolomiteLiquidationModule module = _deployModule(params);

        assertEq(module.collateralRatioWad(), params.collateralRatioWad, "ratio stored");
        assertEq(module.bufferWad(), params.bufferWad, "buffer stored");
        assertEq(module.collateralToken(), address(ConcreteMerchant(merchant).assetCX()), "collateral token stored");
        assertTrue(module.collateralToken() != address(0), "collateral token non-zero");
    }

    // ─────────────────────────────── setCollateralRatio() ─────────────────────

    function test_setCollateralRatio_revertsWhenZero() public {
        DolomiteLiquidationModule module = _deployModule(_validParams());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, 0));
        module.setCollateralRatio(0);
    }

    function test_setCollateralRatio_revertsWhenEqualsWad() public {
        DolomiteLiquidationModule module = _deployModule(_validParams());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, WAD));
        module.setCollateralRatio(WAD);
    }

    function test_setCollateralRatio_revertsWhenAboveWad() public {
        DolomiteLiquidationModule module = _deployModule(_validParams());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, WAD + 1));
        module.setCollateralRatio(WAD + 1);
    }

    function test_setCollateralRatio_succeedsJustBelowWad() public {
        DolomiteLiquidationModule module = _deployModule(_validParams());
        vm.prank(admin);
        module.setCollateralRatio(WAD - 1);
        assertEq(module.collateralRatioWad(), WAD - 1);
    }

    // ─────────────────────────────── setBuffer() ───────────────────────────────

    function test_setBuffer_revertsWhenZero() public {
        DolomiteLiquidationModule module = _deployModule(_validParams());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, 0));
        module.setBuffer(0);
    }

    function test_setBuffer_revertsWhenAboveWad() public {
        DolomiteLiquidationModule module = _deployModule(_validParams());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, WAD + 1));
        module.setBuffer(WAD + 1);
    }

    function test_setBuffer_succeedsWithinRange() public {
        DolomiteLiquidationModule module = _deployModule(_validParams());
        vm.prank(admin);
        module.setBuffer(WAD);
        assertEq(module.bufferWad(), WAD);
    }

    // ─────────────────────────────── setLiquidatableLtv() ──────────────────────

    /// @notice A zero band would let a plain liquidator act on any position, healthy or not.
    function test_setLiquidatableLtv_revertsWhenZero() public {
        DolomiteLiquidationModule module = _deployModule(_validParams());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, 0));
        module.setLiquidatableLtv(0);
    }

    function test_setLiquidatableLtv_revertsWhenAboveWad() public {
        DolomiteLiquidationModule module = _deployModule(_validParams());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDolomiteLiquidationModule.InvalidRatio.selector, WAD + 1));
        module.setLiquidatableLtv(WAD + 1);
    }

    function test_setLiquidatableLtv_succeedsWithinRange() public {
        DolomiteLiquidationModule module = _deployModule(_validParams());
        assertEq(module.liquidatableLtvWad(), 0.8e18, "band stored at initialization");
        vm.prank(admin);
        module.setLiquidatableLtv(0.9e18);
        assertEq(module.liquidatableLtvWad(), 0.9e18);
    }

    // ─────────────────────────────── Helpers ───────────────────────────────────

    function _deployInitializedMerchant() internal returns (address) {
        AssetCX assetCX = AssetCX(
            address(
                new ERC1967Proxy(
                    address(new AssetCX()),
                    abi.encodeCall(AssetCX.initialize, ("AssetCX BTCcx", "BTCcx", admin, address(0)))
                )
            )
        );
        ERC4626Mock vault = new ERC4626Mock(address(assetCX));
        return address(
            new ERC1967Proxy(
                address(new ConcreteMerchant()),
                abi.encodeCall(ConcreteMerchant.initialize, (admin, assetCX, IERC4626(address(vault)), address(0)))
            )
        );
    }

    function _validParams() internal view returns (IDolomiteLiquidationModule.InitParams memory) {
        return IDolomiteLiquidationModule.InitParams({
            admin: admin,
            liquidator: liquidator,
            dolomiteMargin: dolomiteMargin,
            redemptionClaimToken: redemptionClaimToken,
            merchant: merchant,
            debtToken: debtToken,
            collateralRatioWad: 0.98e18,
            bufferWad: 0.05e18,
            liquidatableLtvWad: 0.8e18,
            timelock: address(0)
        });
    }

    function _deployModule(IDolomiteLiquidationModule.InitParams memory params)
        internal
        returns (DolomiteLiquidationModule)
    {
        return DolomiteLiquidationModule(
            address(
                new ERC1967Proxy(
                    address(new DolomiteLiquidationModule()),
                    abi.encodeCall(DolomiteLiquidationModule.initialize, (params))
                )
            )
        );
    }
}
