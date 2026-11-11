// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetCxMultisigStrategy} from "../../src/strategies/AssetCxMultisigStrategy.sol";
import {ConcreteMerchant} from "../../src/merchant/ConcreteMerchant.sol";
import {IConcreteMerchant} from "../../src/interface/IConcreteMerchant.sol";
import {AssetCX} from "../../src/AssetCX.sol";
import {AssetCxRolesLib} from "../../src/lib/AssetCxRolesLib.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PeripheryRolesLib} from "@concrete-xyz/earn-v2-core/src/periphery/lib/PeripheryRolesLib.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {MultisigStrategy} from "@concrete-xyz/earn-v2-core/src/periphery/strategies/MultisigStrategy.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {PositionAccountingLib} from "@concrete-xyz/earn-v2-core/src/periphery/lib/PositionAccountingLib.sol";

contract MockYieldToken is ERC20 {
    constructor() ERC20("Yield Token", "YLD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC4626Vault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock Vault", "mVAULT") ERC4626(asset_) {}

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
}

contract AssetCxMultisigStrategyTest is Test {
    AssetCxMultisigStrategy private strategy;
    ConcreteMerchant private merchant;
    AssetCX private assetCX;
    MockERC4626Vault private vault;
    MockYieldToken private yieldToken;

    address private admin = address(0xA11CE);
    address private operator = address(0xB0B);
    address private multiSig = address(0xC0FFEE);

    function setUp() public {
        // Deploy AssetCX implementation and proxy
        AssetCX assetCXImplementation = new AssetCX();
        ERC1967Proxy assetCXProxy = new ERC1967Proxy(
            address(assetCXImplementation), abi.encodeCall(AssetCX.initialize, ("Asset CX", "ACX", admin, address(0)))
        );
        assetCX = AssetCX(address(assetCXProxy));
        vault = new MockERC4626Vault(assetCX);
        yieldToken = new MockYieldToken();

        ConcreteMerchant merchantImpl = new ConcreteMerchant();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(merchantImpl),
            abi.encodeCall(ConcreteMerchant.initialize, (admin, assetCX, IERC4626(address(vault)), address(0)))
        );
        merchant = ConcreteMerchant(address(proxy));

        AssetCxMultisigStrategy strategyImpl = new AssetCxMultisigStrategy();
        ERC1967Proxy strategyProxy = new ERC1967Proxy(
            address(strategyImpl),
            abi.encodeCall(
                AssetCxMultisigStrategy.initialize,
                (admin, address(vault), multiSig, 200, 3 days, 1 days, address(0), address(merchant))
            )
        );
        strategy = AssetCxMultisigStrategy(address(strategyProxy));

        vm.startPrank(admin);
        assetCX.grantRole(AssetCxRolesLib.MERCHANT_ROLE, address(merchant));
        merchant.grantRole(merchant.OPERATOR_ROLE(), operator);
        merchant.setYieldTokenWhitelisted(address(yieldToken), true);
        merchant.setVaultYieldConfig(address(vault), address(strategy), multiSig);
        vm.stopPrank();

        vm.prank(multiSig);
        yieldToken.approve(address(strategy), type(uint256).max);
    }

    function test_initialize_setsMerchantAndMultisig() public view {
        assertEq(strategy.getMerchant(), address(merchant));
        assertEq(strategy.getMultiSig(), multiSig);
    }

    function test_initialize_revertsForBadAccountingParams() public {
        AssetCxMultisigStrategy strategyImpl = new AssetCxMultisigStrategy();
        vm.expectRevert(PositionAccountingLib.InvalidAccountingValidityPeriod.selector);
        new ERC1967Proxy(
            address(strategyImpl),
            abi.encodeCall(
                AssetCxMultisigStrategy.initialize,
                (admin, address(vault), multiSig, 100, 1 days, 2 days, address(0), address(merchant))
            )
        );
    }

    function test_initiateMerchantYieldAccrual_transfersTokensToMultisig() public {
        uint256 amount = 1_000e18;
        uint256 expectedNonce = merchant.getNextYieldNonce();

        yieldToken.mint(multiSig, amount);

        vm.expectEmit(true, true, true, true, address(strategy));
        emit AssetCxMultisigStrategy.MerchantYieldAccrued(expectedNonce, address(yieldToken), amount, admin);

        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), amount, expectedNonce);

        assertEq(yieldToken.balanceOf(multiSig), amount);
        assertEq(merchant.pendingYield(expectedNonce), amount);
        assertEq(merchant.yieldTokenForPendingYieldNonce(expectedNonce), address(yieldToken));
        assertEq(merchant.totalPendingYieldByToken(address(yieldToken)), amount);
        assertEq(strategy.getPendingMerchantYield(expectedNonce), amount);
        assertEq(strategy.totalPendingYield(address(yieldToken)), amount);
        assertEq(merchant.getNextYieldNonce(), expectedNonce + 1);
    }

    function test_initiateMerchantYieldAccrual_revertsWhenCallerMissingRole() public {
        yieldToken.mint(multiSig, 100e18);
        uint256 nonce = merchant.getNextYieldNonce();

        vm.expectRevert(MultisigStrategy.NotAdminOrOperator.selector);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), 100e18, nonce);
    }

    function test_initiateMerchantYieldAccrual_revertsWhenPaused() public {
        yieldToken.mint(multiSig, 50e18);
        uint256 nonce = merchant.getNextYieldNonce();

        vm.prank(admin);
        strategy.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), 50e18, nonce);
    }

    function test_initiateMerchantYieldAccrual_revertsWhenAmountZero() public {
        uint256 nonce = merchant.getNextYieldNonce();
        vm.expectRevert(AssetCxMultisigStrategy.InvalidYieldAmount.selector);
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), 0, nonce);
    }

    function test_initiateMerchantYieldAccrual_revertsWhenYieldTokenZero() public {
        uint256 nonce = merchant.getNextYieldNonce();
        vm.expectRevert(AssetCxMultisigStrategy.InvalidYieldAsset.selector);
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(0)), 100e18, nonce);
    }

    function test_initiateMerchantYieldAccrual_revertsWhenTokenNotWhitelisted() public {
        // Spin up a second token but skip whitelisting it on the merchant. The
        // strategy will pull funds and forward to the merchant, which must reject
        // the call because the token is not authorised.
        MockYieldToken otherToken = new MockYieldToken();
        otherToken.mint(multiSig, 100e18);
        vm.prank(multiSig);
        otherToken.approve(address(strategy), type(uint256).max);

        uint256 nonce = merchant.getNextYieldNonce();
        vm.expectRevert(
            abi.encodeWithSelector(IConcreteMerchant.YieldTokenNotWhitelisted.selector, address(otherToken))
        );
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(otherToken)), 100e18, nonce);
    }

    function test_initiateMerchantYieldAccrual_supportsMultipleWhitelistedTokens() public {
        // Authorise a second yield token on the merchant and verify the strategy can
        // forward accruals in either token while sharing a single continuous nonce.
        MockYieldToken otherToken = new MockYieldToken();
        vm.prank(admin);
        merchant.setYieldTokenWhitelisted(address(otherToken), true);

        otherToken.mint(multiSig, 200e18);
        yieldToken.mint(multiSig, 300e18);
        vm.prank(multiSig);
        otherToken.approve(address(strategy), type(uint256).max);

        uint256 firstNonce = merchant.getNextYieldNonce();
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), 300e18, firstNonce);

        uint256 secondNonce = merchant.getNextYieldNonce();
        assertEq(secondNonce, firstNonce + 1, "nonce should be continuous across tokens");

        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(otherToken)), 200e18, secondNonce);

        // Per-token accounting is segregated.
        assertEq(merchant.totalPendingYieldByToken(address(yieldToken)), 300e18);
        assertEq(merchant.totalPendingYieldByToken(address(otherToken)), 200e18);
        // Per-(vault, token) accounting is segregated as well.
        assertEq(merchant.pendingYieldForVaultByToken(address(vault), address(yieldToken)), 300e18);
        assertEq(merchant.pendingYieldForVaultByToken(address(vault), address(otherToken)), 200e18);
        // Each nonce remembers its own token.
        assertEq(merchant.yieldTokenForPendingYieldNonce(firstNonce), address(yieldToken));
        assertEq(merchant.yieldTokenForPendingYieldNonce(secondNonce), address(otherToken));
    }

    function test_initiateMerchantYieldAccrual_usesSequentialNonces() public {
        uint256 amount = 1_000e18;
        yieldToken.mint(multiSig, amount * 2);

        uint256 firstNonce = merchant.getNextYieldNonce();
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), amount, firstNonce);

        uint256 secondNonce = merchant.getNextYieldNonce();
        assertEq(secondNonce, firstNonce + 1);

        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), amount, secondNonce);

        assertEq(merchant.getNextYieldNonce(), secondNonce + 1);
    }

    function test_finalizeMerchantYieldAccrual_success() public {
        uint256 pendingAmount = 900e18;
        uint256 redeemedAmount = 850e18;

        yieldToken.mint(multiSig, pendingAmount);
        uint256 nonce = merchant.getNextYieldNonce();
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), pendingAmount, nonce);

        vm.prank(address(merchant));
        assetCX.mint(redeemedAmount);
        vm.prank(address(merchant));
        assetCX.approve(address(strategy), redeemedAmount);

        vm.expectEmit(true, true, true, true, address(strategy));
        emit AssetCxMultisigStrategy.MerchantYieldFinalized(nonce, address(yieldToken), pendingAmount, redeemedAmount);

        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(vault), nonce, redeemedAmount, bytes32(uint256(1)));

        assertEq(strategy.getPendingMerchantYield(nonce), 0);
        assertEq(strategy.totalPendingYield(address(yieldToken)), 0);
        assertEq(assetCX.balanceOf(multiSig), redeemedAmount);
    }

    function test_finalizeMerchantYieldAccrual_revertsWhenUnauthorized() public {
        uint256 amount = 200e18;
        yieldToken.mint(multiSig, amount);
        uint256 nonce = merchant.getNextYieldNonce();
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), amount, nonce);

        vm.prank(address(merchant));
        assetCX.mint(amount);
        vm.prank(address(merchant));
        assetCX.approve(address(strategy), amount);

        // Grant operator role on strategy so they pass the onlyAdminOrOperator check
        vm.prank(admin);
        strategy.grantRole(PeripheryRolesLib.OPERATOR_ROLE, operator);

        // Now the operator has the role but is not the merchant, so should fail with UnauthorizedMerchant
        vm.expectRevert(abi.encodeWithSelector(AssetCxMultisigStrategy.UnauthorizedMerchant.selector, operator));
        vm.prank(operator);
        strategy.finalizeMerchantYieldAccrual(nonce, amount, address(yieldToken));
    }

    function test_finalizeMerchantYieldAccrual_revertsWhenNoPending() public {
        vm.prank(address(merchant));
        assetCX.mint(100e18);
        vm.prank(address(merchant));
        assetCX.approve(address(strategy), 100e18);

        vm.expectRevert();
        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(vault), 1, 100e18, bytes32(uint256(1)));
    }

    function test_finalizeMerchantYieldAccrual_revertsWhenOperatorMissingRole() public {
        uint256 amount = 400e18;

        yieldToken.mint(multiSig, amount);
        uint256 nonce = merchant.getNextYieldNonce();
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), amount, nonce);

        vm.prank(address(merchant));
        assetCX.mint(amount);
        vm.prank(address(merchant));
        assetCX.approve(address(strategy), amount);

        // Admin has MERCHANT_MANAGER_ROLE (granted in initialize), which is the admin of OPERATOR_ROLE
        vm.startPrank(admin);
        merchant.revokeRole(merchant.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, merchant.OPERATOR_ROLE()
            )
        );
        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(vault), nonce, amount, bytes32(uint256(1)));
    }

    function test_initiateMerchantYieldAccrual_revertsWhenInvalidNonce() public {
        uint256 amount = 1_000e18;
        yieldToken.mint(multiSig, amount);

        uint256 expectedNonce = merchant.getNextYieldNonce();
        uint256 wrongNonce = expectedNonce + 1;

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.InvalidNonce.selector, expectedNonce, wrongNonce));
        vm.prank(admin);
        strategy.initiateMerchantYieldAccrual(IERC20(address(yieldToken)), amount, wrongNonce);
    }
}

