// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RedemptionClaimToken} from "../src/liquidations/RedemptionClaimToken.sol";
import {IRedemptionClaimToken} from "../src/interface/IRedemptionClaimToken.sol";
import {AssetCxRolesLib} from "../src/lib/AssetCxRolesLib.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";

contract RedemptionClaimTokenTest is Test {
    RedemptionClaimToken public token;

    address public admin = address(0x1);
    address public liquidator = address(0x2);
    address public merchant = address(0x3); // whitelisted holder
    address public dolomite = address(0x4); // whitelisted holder
    address public user = address(0x5); // NOT whitelisted

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant LIQUIDATION_MODULE_ROLE = keccak256("LIQUIDATION_MODULE_ROLE");
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);

    function setUp() public {
        token = _deploy("Redemption Claim BTCcx-USD1", "rBTCcx-USD1", 18);

        vm.startPrank(admin);
        // LIQUIDATION_MODULE_ROLE is granted post-deploy (the module is deployed with the token
        // as a dependency, then permissioned here).
        token.grantRole(LIQUIDATION_MODULE_ROLE, liquidator);
        // Whitelist the closed-ecosystem endpoints. The liquidator (module) must be
        // whitelisted since it now mints/burns against its own balance.
        token.addToWhitelist(liquidator);
        token.addToWhitelist(merchant);
        token.addToWhitelist(dolomite);
        vm.stopPrank();
    }

    function _deploy(string memory name_, string memory symbol_, uint8 decimals_)
        internal
        returns (RedemptionClaimToken)
    {
        RedemptionClaimToken impl = new RedemptionClaimToken();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RedemptionClaimToken.initialize, (name_, symbol_, admin, decimals_, address(0)))
        );
        return RedemptionClaimToken(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_metadataAndRoles() public view {
        assertEq(token.name(), "Redemption Claim BTCcx-USD1");
        assertEq(token.symbol(), "rBTCcx-USD1");
        assertEq(token.decimals(), 18);

        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(token.hasRole(WHITELIST_MANAGER_ROLE, admin));
        assertTrue(token.hasRole(PAUSER_ROLE, admin));
        assertTrue(token.hasRole(LIQUIDATION_MODULE_ROLE, liquidator));
        assertFalse(token.hasRole(LIQUIDATION_MODULE_ROLE, admin));
        assertFalse(token.paused());

        (address tl, bool active) = token.getTimelock();
        assertEq(tl, address(0));
        assertFalse(active);
    }

    function test_initialize_customDecimals() public {
        RedemptionClaimToken t = _deploy("r", "r", 6);
        assertEq(t.decimals(), 6);
    }

    function test_initialize_revertsWhenDecimalsZero() public {
        RedemptionClaimToken impl = new RedemptionClaimToken();
        vm.expectRevert(IRedemptionClaimToken.ZeroDecimals.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(RedemptionClaimToken.initialize, ("x", "x", admin, 0, address(0)))
        );
    }

    function test_initialize_revertsWhenAdminZero() public {
        RedemptionClaimToken impl = new RedemptionClaimToken();
        vm.expectRevert(IRedemptionClaimToken.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(RedemptionClaimToken.initialize, ("r", "r", address(0), 0, address(0)))
        );
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        token.initialize("x", "x", admin, 0, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        MINT / BURN
    //////////////////////////////////////////////////////////////*/

    function test_mint_success() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), liquidator, 1000e18);

        vm.prank(liquidator);
        token.mint(1000e18);

        assertEq(token.balanceOf(liquidator), 1000e18);
        assertEq(token.totalSupply(), 1000e18);
    }

    function test_mint_revertsWhenNotLiquidator() public {
        vm.prank(admin);
        vm.expectRevert();
        token.mint(1000e18);

        vm.prank(user);
        vm.expectRevert();
        token.mint(1000e18);
    }

    function test_mint_revertsWhenCallerNotWhitelisted() public {
        // A liquidator that is not on the transfer whitelist cannot receive its own mint.
        vm.prank(admin);
        token.grantRole(LIQUIDATION_MODULE_ROLE, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionClaimToken.NotWhitelisted.selector, user));
        token.mint(1000e18);
    }

    function test_burn_success() public {
        vm.prank(liquidator);
        token.mint(1000e18);

        vm.expectEmit(true, true, true, true);
        emit Transfer(liquidator, address(0), 400e18);

        vm.prank(liquidator);
        token.burn(400e18);

        assertEq(token.balanceOf(liquidator), 600e18);
        assertEq(token.totalSupply(), 600e18);
    }

    function test_burn_revertsWhenNotLiquidator() public {
        vm.prank(liquidator);
        token.mint(1000e18);

        vm.prank(user);
        vm.expectRevert();
        token.burn(100e18);
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER WHITELIST
    //////////////////////////////////////////////////////////////*/

    function test_transfer_betweenWhitelisted() public {
        vm.prank(liquidator);
        token.mint(1000e18);

        vm.prank(liquidator);
        token.transfer(dolomite, 250e18);

        assertEq(token.balanceOf(dolomite), 250e18);
        assertEq(token.balanceOf(liquidator), 750e18);
    }

    function test_transfer_revertsWhenRecipientNotWhitelisted() public {
        vm.prank(liquidator);
        token.mint(1000e18);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionClaimToken.NotWhitelisted.selector, user));
        token.transfer(user, 1);
    }

    function test_transfer_revertsWhenSenderDelisted() public {
        vm.prank(liquidator);
        token.mint(1000e18);

        // Liquidator is removed from the whitelist while still holding a balance.
        vm.prank(admin);
        token.removeFromWhitelist(liquidator);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionClaimToken.NotWhitelisted.selector, liquidator));
        token.transfer(dolomite, 1);
    }

    /*//////////////////////////////////////////////////////////////
                        WHITELIST MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_addToWhitelist_success() public {
        assertFalse(token.isWhitelisted(user));

        vm.expectEmit(true, true, true, true);
        emit WhitelistAdded(user);

        vm.prank(admin);
        token.addToWhitelist(user);

        assertTrue(token.isWhitelisted(user));
    }

    function test_addToWhitelist_revertsWhenNotManager() public {
        vm.prank(user);
        vm.expectRevert();
        token.addToWhitelist(user);
    }

    function test_addToWhitelist_revertsWhenZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IRedemptionClaimToken.ZeroAddress.selector);
        token.addToWhitelist(address(0));
    }

    function test_addToWhitelist_revertsWhenAlreadyPresent() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionClaimToken.AlreadyWhitelisted.selector, merchant));
        token.addToWhitelist(merchant);
    }

    function test_removeFromWhitelist_success() public {
        vm.expectEmit(true, true, true, true);
        emit WhitelistRemoved(merchant);

        vm.prank(admin);
        token.removeFromWhitelist(merchant);

        assertFalse(token.isWhitelisted(merchant));
    }

    function test_removeFromWhitelist_revertsWhenNotPresent() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionClaimToken.NotInWhitelist.selector, user));
        token.removeFromWhitelist(user);
    }

    function test_whitelist_views() public view {
        assertEq(token.whitelistLength(), 3);
        address[] memory wl = token.getWhitelist();
        assertEq(wl.length, 3);
        assertTrue(token.isWhitelisted(liquidator));
        assertTrue(token.isWhitelisted(merchant));
        assertTrue(token.isWhitelisted(dolomite));
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_blocksMintBurnTransfer() public {
        vm.prank(liquidator);
        token.mint(1000e18);

        vm.prank(admin);
        token.pause();
        assertTrue(token.paused());

        vm.prank(liquidator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.mint(1);

        vm.prank(liquidator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.burn(1);

        vm.prank(liquidator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.transfer(dolomite, 1);
    }

    function test_pause_revertsWhenNotPauser() public {
        vm.prank(user);
        vm.expectRevert();
        token.pause();
    }

    function test_unpause_restoresFlow() public {
        // No timelock is wired in this fixture (`address(0)` at init), so the
        // `afterDelay` on `unpause()` no-ops.
        vm.prank(admin);
        token.pause();

        vm.prank(admin);
        token.unpause();
        assertFalse(token.paused());

        vm.prank(liquidator);
        token.mint(1000e18);
        assertEq(token.balanceOf(liquidator), 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                        UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_upgrade_preservesState() public {
        vm.prank(liquidator);
        token.mint(5000e18);

        RedemptionClaimToken v2 = new RedemptionClaimToken();
        vm.prank(admin);
        token.upgradeToAndCall(address(v2), "");

        assertEq(token.balanceOf(liquidator), 5000e18);
        assertEq(token.decimals(), 18);
        assertTrue(token.isWhitelisted(merchant));
        assertTrue(token.hasRole(LIQUIDATION_MODULE_ROLE, liquidator));
    }

    function test_upgrade_revertsWhenNotAdmin() public {
        RedemptionClaimToken v2 = new RedemptionClaimToken();

        vm.prank(user);
        vm.expectRevert();
        token.upgradeToAndCall(address(v2), "");

        vm.prank(liquidator);
        vm.expectRevert();
        token.upgradeToAndCall(address(v2), "");
    }

    /*//////////////////////////////////////////////////////////////
                        LAST ADMIN PROTECTION
    //////////////////////////////////////////////////////////////*/

    function test_revokeRole_allowsRemovingAdminWhileAnotherRemains_butBlocksLast() public {
        address secondAdmin = address(0x6);

        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, secondAdmin);
        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 2);

        // With two admins, removing one succeeds.
        vm.prank(secondAdmin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);

        // Removing the last remaining admin reverts.
        vm.prank(secondAdmin);
        vm.expectRevert(IRedemptionClaimToken.CannotRemoveLastRoleAdmin.selector);
        token.revokeRole(DEFAULT_ADMIN_ROLE, secondAdmin);

        vm.prank(secondAdmin);
        vm.expectRevert(IRedemptionClaimToken.CannotRemoveLastRoleAdmin.selector);
        token.renounceRole(DEFAULT_ADMIN_ROLE, secondAdmin);

        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, secondAdmin));
    }
}
