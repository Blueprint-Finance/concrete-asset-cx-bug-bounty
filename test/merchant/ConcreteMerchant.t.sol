// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626} from "@openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {IERC1967} from "@openzeppelin-contracts/interfaces/IERC1967.sol";
import {ERC1967Utils} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";

import {AssetCX} from "../../src/AssetCX.sol";
import {ConcreteMerchant} from "../../src/merchant/ConcreteMerchant.sol";
import {IConcreteMerchant} from "../../src/interface/IConcreteMerchant.sol";
import {IWhitelistHook} from "../../src/interface/IWhitelistHook.sol";
import {ConcreteMerchantStorageLib} from "../../src/lib/ConcreteMerchantStorageLib.sol";
import {console2} from "forge-std/console2.sol";

contract MockMultisigStrategy {
    using SafeERC20 for IERC20;

    address public multiSig;
    address public vault;
    uint256 private _nextAccountingNonce = 1;
    int256 public lastDiff;
    uint256 public lastAccountingNonce;
    IERC20 public assetToken;
    uint256 public lastFinalizedNonce;

    constructor(address multiSig_, IERC20 assetToken_, address vault_) {
        multiSig = multiSig_;
        assetToken = assetToken_;
        vault = vault_;
    }

    function getMultiSig() external view returns (address) {
        return multiSig;
    }

    function getVault() external view returns (address) {
        return vault;
    }

    function getNextAccountingNonce() external view returns (uint256) {
        return _nextAccountingNonce;
    }

    function adjustTotalAssets(int256 diff, uint256 accountingNonce_) external {
        lastDiff = diff;
        lastAccountingNonce = accountingNonce_;
        _nextAccountingNonce = accountingNonce_ + 1;
    }

    function finalizeMerchantYieldAccrual(
        uint256 nonce,
        uint256 amountInAsset,
        address /* yieldToken */
    )
        external
    {
        assetToken.safeTransferFrom(msg.sender, multiSig, amountInAsset);
        lastDiff = int256(amountInAsset);
        lastAccountingNonce = _nextAccountingNonce;
        lastFinalizedNonce = nonce;
        _nextAccountingNonce = _nextAccountingNonce + 1;
    }

    function approveSpender(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

contract MockYieldToken is ERC20 {
    constructor() ERC20("Yield Token", "YLD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWhitelistHook {
    mapping(address => bool) public userWhitelisted;

    function setUserWhitelisted(address _user) external {
        userWhitelisted[_user] = true;
    }

    function removeUserFromWhitelist(address _user) external {
        userWhitelisted[_user] = false;
    }
}

contract MockAssetCXVault is ERC4626 {
    using SafeERC20 for IERC20;

    mapping(address => mapping(uint256 => uint256)) public userEpochAssets;
    uint256 public payoutBps = 10_000;
    address public hook;

    constructor(IERC20 asset) ERC20("AssetCX Vault", "aACX") ERC4626(asset) {}

    function setUserEpochAssets(address user, uint256 epochID, uint256 assets) external {
        userEpochAssets[user][epochID] = assets;
    }

    function setPayoutBps(uint256 newPayoutBps) external {
        payoutBps = newPayoutBps;
    }

    function setHook(address _hook) external {
        hook = _hook;
    }

    function getHook() external view returns (address) {
        return hook;
    }

    function claimWithdrawal(address user, uint256[] calldata epochIDs) external {
        uint256 totalAssets;
        IERC20 assetToken = IERC20(asset());
        uint256 length = epochIDs.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 epochID = epochIDs[i];
            uint256 assetsForEpoch = userEpochAssets[user][epochID];
            totalAssets += assetsForEpoch;
            userEpochAssets[user][epochID] = 0;
        }

        uint256 payout = totalAssets * payoutBps / 10_000;
        assetToken.safeTransfer(msg.sender, payout);
    }

    function getUserEpochRequestInAssets(address user, uint256 epochID) external view returns (uint256) {
        return userEpochAssets[user][epochID];
    }

    function getUserEpochRequest(address user, uint256 epochID) external view returns (uint256) {
        return userEpochAssets[user][epochID]; // @dev assume 1:1 ratio for this test
    }
}

contract ConcreteMerchantTest is Test {
    AssetCX private assetCX;
    MockAssetCXVault private assetCXVault;
    ConcreteMerchant private merchant;
    MockYieldToken private yieldToken;

    address private admin = address(0xA11CE);
    address private operator = address(0xB0B);
    address private user = address(0xC0FFEE);
    address private yieldMultisigAddress = address(0xFACE);
    MockMultisigStrategy private strategy;

    bytes32 private constant MERCHANT_ROLE = keccak256("MERCHANT_ROLE");

    function setUp() public {
        // Deploy AssetCX implementation and proxy
        AssetCX assetCXImplementation = new AssetCX();
        ERC1967Proxy assetCXProxy = new ERC1967Proxy(
            address(assetCXImplementation), abi.encodeCall(AssetCX.initialize, ("Asset CX", "ACX", admin, address(0)))
        );
        assetCX = AssetCX(address(assetCXProxy));

        assetCXVault = new MockAssetCXVault(assetCX);
        yieldToken = new MockYieldToken();
        strategy = new MockMultisigStrategy(yieldMultisigAddress, assetCX, address(assetCXVault));

        ConcreteMerchant implementation = new ConcreteMerchant();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(ConcreteMerchant.initialize, (admin, assetCX, IERC4626(address(assetCXVault)), address(0)))
        );
        merchant = ConcreteMerchant(address(proxy));

        vm.startPrank(admin);
        assetCX.grantRole(MERCHANT_ROLE, address(merchant));
        merchant.grantRole(merchant.OPERATOR_ROLE(), operator);
        merchant.setYieldTokenWhitelisted(address(yieldToken), true);
        merchant.setVaultYieldConfig(address(assetCXVault), address(strategy), yieldMultisigAddress);
        vm.stopPrank();

        assertTrue(merchant.hasRole(merchant.MERCHANT_MANAGER_ROLE(), admin));
    }

    /**
     * @notice Helper function to mint assetCX directly to a user
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function _mintAssetCXTo(address to, uint256 amount) internal {
        vm.prank(address(merchant));
        assetCX.mint(amount);
        vm.prank(address(merchant));
        assetCX.transfer(to, amount);
    }

    /// @dev Storage offset of the `usedUserAccounts` mapping inside the
    ///      `ConcreteMerchantStorageLib.Storage` struct (the 19th field, 0-indexed 18).
    uint256 private constant _USED_USER_ACCOUNTS_OFFSET = 18;

    function _usedUserAccountsBaseSlot() internal pure returns (bytes32) {
        return bytes32(uint256(ConcreteMerchantStorageLib.storageLocation()) + _USED_USER_ACCOUNTS_OFFSET);
    }

    function _usedUserAccountsSlot(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, _usedUserAccountsBaseSlot()));
    }

    /// @dev Simulates an upgraded proxy that came from a pre-V2 implementation by
    ///      clearing the `usedUserAccounts[account]` flag after the V2 `setUserAccount`
    ///      wrote it. Lets the test reproduce the on-chain state that {reinitializeV2}
    ///      and the defensive flag inside {emergencyMigrateUserAccount} are meant to
    ///      protect against.
    function _clearUsedUserAccountFlag(address account) internal {
        vm.store(address(merchant), _usedUserAccountsSlot(account), bytes32(0));
    }

    /// @dev Storage offsets of the legacy single-token yield slots inside the
    ///      `ConcreteMerchantStorageLib.Storage` struct. Used by the
    ///      {reinitializeV2} tests to simulate proxies carrying live pre-V3 state.
    uint256 private constant _DEPRECATED_YIELD_ASSET_OFFSET = 2;
    uint256 private constant _DEPRECATED_TOTAL_PENDING_YIELD_OFFSET = 4;

    function _deprecatedYieldAssetSlot() internal pure returns (bytes32) {
        return bytes32(uint256(ConcreteMerchantStorageLib.storageLocation()) + _DEPRECATED_YIELD_ASSET_OFFSET);
    }

    function _deprecatedTotalPendingYieldSlot() internal pure returns (bytes32) {
        return bytes32(uint256(ConcreteMerchantStorageLib.storageLocation()) + _DEPRECATED_TOTAL_PENDING_YIELD_OFFSET);
    }

    function _writeDeprecatedYieldAsset(address legacyAsset) internal {
        vm.store(address(merchant), _deprecatedYieldAssetSlot(), bytes32(uint256(uint160(legacyAsset))));
    }

    function _writeDeprecatedTotalPendingYield(uint256 amount) internal {
        vm.store(address(merchant), _deprecatedTotalPendingYieldSlot(), bytes32(amount));
    }

    function test_mintAndDeposit_success() public {
        bytes32 userId = keccak256("user-1");
        uint256 amount = 1_000e18;
        bytes32 txHash = keccak256(bytes("mint-success"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.MintAndDeposit(userId, amount, txHash);

        vm.prank(operator);
        uint256 shares = merchant.mintAndDeposit(userId, amount, txHash);

        assertEq(shares, amount);
        assertEq(assetCX.totalSupply(), amount);
        assertEq(assetCX.balanceOf(address(merchant)), 0);
        assertEq(assetCX.balanceOf(address(assetCXVault)), amount);
        assertEq(assetCXVault.balanceOf(user), amount);
        assertEq(assetCX.allowance(address(merchant), address(assetCXVault)), 0);
        assertEq(merchant.totalMinted(userId), amount);
    }

    function test_mintAndDeposit_usesUserVaultOverride() public {
        bytes32 userId = keccak256("user-override");
        uint256 amount = 750e18;
        MockAssetCXVault otherVault = new MockAssetCXVault(assetCX);
        bytes32 txHash = keccak256(bytes("mint-override"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(admin);
        merchant.setUserVault(userId, IERC4626(address(otherVault)));

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.MintAndDeposit(userId, amount, txHash);

        vm.prank(operator);
        uint256 shares = merchant.mintAndDeposit(userId, amount, txHash);

        assertEq(shares, amount);
        assertEq(address(merchant.userVault(userId)), address(otherVault));
        assertEq(otherVault.balanceOf(user), amount);
        assertEq(assetCXVault.balanceOf(user), 0);
    }

    function test_mintAndDeposit_revertsForUnknownUser() public {
        bytes32 userId = keccak256("missing-user");

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.UnknownUser.selector, userId));
        vm.prank(operator);
        merchant.mintAndDeposit(userId, 1_000e18, keccak256(bytes("mint-unknown")));
    }

    function test_mintAndDeposit_revertsWhenSenderNotOperator() public {
        bytes32 userId = keccak256("user-2");

        vm.startPrank(admin);
        merchant.setUserAccount(userId, user);
        merchant.revokeRole(merchant.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, merchant.OPERATOR_ROLE()
            )
        );
        vm.prank(operator);
        merchant.mintAndDeposit(userId, 1_000e18, keccak256(bytes("mint-not-operator")));
    }

    function test_claimVaultWithdrawal_revertsWhenSenderNotOperator() public {
        vm.startPrank(admin);
        merchant.revokeRole(merchant.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, merchant.OPERATOR_ROLE()
            )
        );
        vm.prank(operator);
        merchant.claimVaultWithdrawal(keccak256("user-claim-forbidden"), 1);
    }

    function test_mintAndDeposit_revertsWhenTxHashReused() public {
        bytes32 userId = keccak256("user-hash-reuse");
        bytes32 txHash = keccak256(bytes("mint-reuse"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.startPrank(operator);
        merchant.mintAndDeposit(userId, 500e18, txHash);
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.TxHashAlreadyUsed.selector, txHash));
        merchant.mintAndDeposit(userId, 100e18, txHash);
        vm.stopPrank();
    }

    function test_mintAndDeposit_revertsWhenTxHashEmpty() public {
        bytes32 userId = keccak256("user-empty-hash");
        uint256 amount = 1_000e18;

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.expectRevert(IConcreteMerchant.InvalidTxHash.selector);
        vm.prank(operator);
        merchant.mintAndDeposit(userId, amount, bytes32(0));
    }

    function test_removeUserVault_success() public {
        bytes32 userId = keccak256("user-remove");

        MockAssetCXVault otherVault = new MockAssetCXVault(assetCX);

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(admin);
        merchant.setUserVault(userId, IERC4626(address(otherVault)));
        assertEq(address(merchant.userVault(userId)), address(otherVault));

        // No deposits yet, so removing vault should succeed
        vm.prank(admin);
        merchant.removeUserVault(userId);
        assertEq(address(merchant.userVault(userId)), address(0));
    }

    function test_removeUserVault_revertsWhenActiveDeposits() public {
        bytes32 userId = keccak256("user-remove-active");
        MockAssetCXVault otherVault = new MockAssetCXVault(assetCX);
        bytes32 txHash = keccak256(bytes("mint-remove-active"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(admin);
        merchant.setUserVault(userId, IERC4626(address(otherVault)));

        // Make a deposit
        vm.prank(operator);
        merchant.mintAndDeposit(userId, 400e18, txHash);

        assertEq(merchant.mintedVaultShares(userId), 400e18);

        // Should revert when trying to remove vault with active deposits
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.UserHasActiveDeposits.selector, userId, 400e18));
        vm.prank(admin);
        merchant.removeUserVault(userId);
    }

    function test_setUserVault_revertsWhenVaultAssetMismatch() public {
        bytes32 userId = keccak256("user-invalid-vault");
        MockAssetCXVault otherVault = new MockAssetCXVault(assetCX);
        MockAssetCXVault invalidVault = new MockAssetCXVault(yieldToken);

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(admin);
        merchant.setUserVault(userId, IERC4626(address(otherVault)));

        vm.expectRevert(IConcreteMerchant.InvalidVaultAsset.selector);
        vm.prank(admin);
        merchant.setUserVault(userId, IERC4626(address(invalidVault)));
    }

    function test_setUserVault_revertsWhenNotManager() public {
        bytes32 userId = keccak256("user-no-manager");
        MockAssetCXVault otherVault = new MockAssetCXVault(assetCX);

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, merchant.MERCHANT_MANAGER_ROLE()
            )
        );
        vm.prank(user);
        merchant.setUserVault(userId, IERC4626(address(otherVault)));
    }

    function test_setUserVault_revertsWhenUserNotRegistered() public {
        bytes32 userId = keccak256("user-not-registered");
        MockAssetCXVault otherVault = new MockAssetCXVault(assetCX);

        // Try to set vault for a user that has not been registered via setUserAccount
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.UnknownUser.selector, userId));
        vm.prank(admin);
        merchant.setUserVault(userId, IERC4626(address(otherVault)));
    }

    function test_initialize_revertsWhenVaultAssetMismatch() public {
        // Create a vault with the wrong asset (yieldToken instead of assetCX)
        MockAssetCXVault mismatchedVault = new MockAssetCXVault(yieldToken);

        ConcreteMerchant implementation = new ConcreteMerchant();

        // Expect revert when initializing with a vault whose asset doesn't match assetCX
        vm.expectRevert(IConcreteMerchant.InvalidVaultAsset.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                ConcreteMerchant.initialize, (admin, assetCX, IERC4626(address(mismatchedVault)), address(0))
            )
        );
    }

    function test_removeUserVault_revertsWhenNotManager() public {
        bytes32 userId = keccak256("user-remove-no-manager");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, merchant.MERCHANT_MANAGER_ROLE()
            )
        );
        vm.prank(user);
        merchant.removeUserVault(userId);
    }

    function test_setUserData_storesTwoAddressesAndRoundTrips() public {
        // Custodian payload: two extra addresses (e.g. a secondary signing key
        // and a beneficiary). The merchant stores the payload as an opaque
        // blob; off-chain integrations decode it back.
        bytes32 userId = keccak256("user-custodian");
        address signingKey = address(0xBEEF);
        address beneficiary = address(0xCAFE);
        bytes memory payload = abi.encode(signingKey, beneficiary);

        vm.expectEmit(true, false, false, true, address(merchant));
        emit IConcreteMerchant.UserDataSet(userId, payload);

        vm.prank(admin);
        merchant.setUserData(userId, payload);

        bytes memory stored = merchant.userData(userId);
        assertEq(stored, payload, "round-tripped bytes mismatch");

        (address decodedSigningKey, address decodedBeneficiary) = abi.decode(stored, (address, address));
        assertEq(decodedSigningKey, signingKey, "signing key not preserved");
        assertEq(decodedBeneficiary, beneficiary, "beneficiary not preserved");
    }

    function test_setUserData_overwritesPreviousPayload() public {
        bytes32 userId = keccak256("user-custodian-overwrite");
        bytes memory first = abi.encode(address(0x1111), address(0x2222));
        bytes memory second = abi.encode(address(0x3333), address(0x4444));

        vm.startPrank(admin);
        merchant.setUserData(userId, first);
        merchant.setUserData(userId, second);
        vm.stopPrank();

        assertEq(merchant.userData(userId), second, "stale payload not overwritten");
    }

    function test_setUserData_revertsWhenNotManager() public {
        bytes32 userId = keccak256("user-custodian-no-manager");
        bytes memory payload = abi.encode(address(0xAAAA), address(0xBBBB));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, merchant.MERCHANT_MANAGER_ROLE()
            )
        );
        vm.prank(user);
        merchant.setUserData(userId, payload);
    }

    function test_setUserAccount_revertsWhenNotManager() public {
        bytes32 userId = keccak256("user-3");
        address outsider = address(0xD1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, merchant.MERCHANT_MANAGER_ROLE()
            )
        );
        vm.prank(outsider);
        merchant.setUserAccount(userId, user);
    }

    function test_setUserAccount_revertsWhenActiveDeposits() public {
        bytes32 userId = keccak256("user-account-active");
        address newUser = address(0xD2);
        bytes32 txHash = keccak256(bytes("mint-account-active"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        // Make a deposit
        vm.prank(operator);
        merchant.mintAndDeposit(userId, 500e18, txHash);

        assertEq(merchant.mintedVaultShares(userId), 500e18);

        // Should revert when trying to change account with active deposits
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.UserHasActiveDeposits.selector, userId, 500e18));
        vm.prank(admin);
        merchant.setUserAccount(userId, newUser);
    }

    function test_setUserAccount_marksAccountAsUsed() public {
        bytes32 userId = keccak256("user-account-marks-used");

        assertFalse(merchant.isUserAccountUsed(user));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        assertTrue(merchant.isUserAccountUsed(user));
        assertEq(merchant.getUserAccount(userId), user);
    }

    function test_setUserAccount_revertsWhenAccountAlreadyUsedByOtherUser() public {
        bytes32 firstUserId = keccak256("user-account-collision-first");
        bytes32 secondUserId = keccak256("user-account-collision-second");

        vm.prank(admin);
        merchant.setUserAccount(firstUserId, user);

        // A second userId trying to claim the same on-chain address must revert.
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.UserAccountAlreadyUsed.selector, user));
        vm.prank(admin);
        merchant.setUserAccount(secondUserId, user);

        // First binding is untouched.
        assertEq(merchant.getUserAccount(firstUserId), user);
        assertEq(merchant.getUserAccount(secondUserId), address(0));
        assertTrue(merchant.isUserAccountUsed(user));
    }

    function test_setUserAccount_idempotentWhenSameAddressRebound() public {
        bytes32 userId = keccak256("user-account-same-rebind");

        vm.prank(admin);
        merchant.setUserAccount(userId, user);
        assertTrue(merchant.isUserAccountUsed(user));

        // Re-binding the same address to the same userId is idempotent: the
        // rotation first clears the existing flag, then re-sets it.
        vm.prank(admin);
        merchant.setUserAccount(userId, user);
        assertEq(merchant.getUserAccount(userId), user);
        assertTrue(merchant.isUserAccountUsed(user));
    }

    function test_setUserAccount_oldAddressIsFreedAfterRotation() public {
        bytes32 userId = keccak256("user-account-rotation");
        address rotatedUser = address(0xD3);

        vm.prank(admin);
        merchant.setUserAccount(userId, user);
        assertTrue(merchant.isUserAccountUsed(user));

        // No deposits yet, so rotation to a fresh address is allowed.
        vm.prank(admin);
        merchant.setUserAccount(userId, rotatedUser);
        assertEq(merchant.getUserAccount(userId), rotatedUser);
        assertTrue(merchant.isUserAccountUsed(rotatedUser));
        // The previously-bound address is freed and can now be reused.
        assertFalse(merchant.isUserAccountUsed(user));

        // Reassigning the freed address to another userId now succeeds.
        bytes32 otherUserId = keccak256("user-account-rotation-other");
        vm.prank(admin);
        merchant.setUserAccount(otherUserId, user);
        assertEq(merchant.getUserAccount(otherUserId), user);
        assertTrue(merchant.isUserAccountUsed(user));
    }

    function test_setUserAccount_failedRotationDoesNotFreeOldAddress() public {
        bytes32 userId = keccak256("user-account-failed-rotation");
        bytes32 otherUserId = keccak256("user-account-failed-rotation-other");
        address otherUser = address(0xD4);

        vm.startPrank(admin);
        merchant.setUserAccount(userId, user);
        merchant.setUserAccount(otherUserId, otherUser);
        vm.stopPrank();

        // Attempting to rotate `userId` onto an already-bound address must revert
        // AND leave the original binding untouched (including the used-flag).
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.UserAccountAlreadyUsed.selector, otherUser));
        vm.prank(admin);
        merchant.setUserAccount(userId, otherUser);

        assertEq(merchant.getUserAccount(userId), user);
        assertTrue(merchant.isUserAccountUsed(user), "old address must stay flagged on failed rotation");
        assertTrue(merchant.isUserAccountUsed(otherUser));
    }

    function test_isUserAccountUsed_initiallyFalseForUnknownAddress() public view {
        assertFalse(merchant.isUserAccountUsed(address(0xDEAD)));
        assertFalse(merchant.isUserAccountUsed(user));
    }

    function test_setUserVault_revertsWhenActiveDeposits() public {
        bytes32 userId = keccak256("user-vault-active");
        MockAssetCXVault otherVault = new MockAssetCXVault(assetCX);
        bytes32 txHash = keccak256(bytes("mint-vault-active"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        // Make a deposit to the default vault
        vm.prank(operator);
        merchant.mintAndDeposit(userId, 300e18, txHash);

        assertEq(merchant.mintedVaultShares(userId), 300e18);

        // Should revert when trying to set a different vault with active deposits
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.UserHasActiveDeposits.selector, userId, 300e18));
        vm.prank(admin);
        merchant.setUserVault(userId, IERC4626(address(otherVault)));
    }

    function test_claimVaultWithdrawal_success() public {
        bytes32 userId = keccak256("user-claim");
        uint256 amount = 1_000e18;
        uint256 epochID = 1;
        bytes32 depositTxHash = keccak256(bytes("claim-success-deposit"));
        bytes32 finalizeTxHash = keccak256(bytes("claim-success-finalize"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.MintAndDeposit(userId, amount, depositTxHash);
        vm.prank(operator);
        merchant.mintAndDeposit(userId, amount, depositTxHash);

        assetCXVault.setUserEpochAssets(user, epochID, 600e18);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.PendingQCRedemption(userId, epochID, 600e18, 600e18, 600e18);

        vm.prank(operator);
        uint256 claimed = merchant.claimVaultWithdrawal(userId, epochID);

        assertEq(claimed, 600e18);
        assertEq(assetCX.balanceOf(address(merchant)), 0);
        assertEq(assetCXVault.getUserEpochRequestInAssets(user, epochID), 0);
        assertEq(merchant.pendingQCRedemption(userId), 600e18);
        assertEq(merchant.totalPendingQCRedemption(), 600e18);
        assertEq(merchant.totalBurned(userId), 600e18);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.QCRedemptionFinalized(userId, 200e18, 400e18, 400e18, finalizeTxHash);

        vm.prank(operator);
        merchant.finalizeQCRedemption(userId, 200e18, finalizeTxHash);

        assertEq(merchant.pendingQCRedemption(userId), 400e18);
        assertEq(merchant.totalPendingQCRedemption(), 400e18);
    }

    function test_claimVaultWithdrawal_revertsOnMismatch() public {
        bytes32 userId = keccak256("user-claim-mismatch");
        uint256 amount = 1_000e18;
        uint256 epochID = 7;
        bytes32 depositTxHash = keccak256(bytes("claim-mismatch-deposit"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(operator);
        merchant.mintAndDeposit(userId, amount, depositTxHash);

        assetCXVault.setUserEpochAssets(user, epochID, 500e18);
        assetCXVault.setPayoutBps(8_000); // pay out only 80%

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.ClaimAmountMismatch.selector, 500e18, 400e18));
        merchant.claimVaultWithdrawal(userId, epochID);
    }

    function test_finalizeQCRedemption_revertsWhenInsufficient() public {
        bytes32 userId = keccak256("user-finalize-insufficient");
        uint256 amount = 1_000e18;
        uint256 epochID = 9;
        bytes32 depositTxHash = keccak256(bytes("finalize-insufficient-deposit"));
        bytes32 finalizeTxHash1 = keccak256(bytes("finalize-insufficient-1"));
        bytes32 finalizeTxHash2 = keccak256(bytes("finalize-insufficient-2"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(operator);
        merchant.mintAndDeposit(userId, amount, depositTxHash);

        assetCXVault.setUserEpochAssets(user, epochID, 300e18);

        vm.prank(operator);
        merchant.claimVaultWithdrawal(userId, epochID);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.WrongRedemptionAmount.selector, 0, 300e18));
        merchant.finalizeQCRedemption(userId, 0, finalizeTxHash1);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.WrongRedemptionAmount.selector, 400e18, 300e18));
        merchant.finalizeQCRedemption(userId, 400e18, finalizeTxHash2);
    }

    function test_finalizeQCRedemption_revertsWhenTxHashReused() public {
        bytes32 userId = keccak256("user-finalize-reuse");
        uint256 amount = 1_000e18;
        uint256 epochID = 3;
        bytes32 depositTxHash = keccak256(bytes("finalize-reuse-deposit"));
        bytes32 finalizeTxHash = keccak256(bytes("finalize-reuse-finalize"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(operator);
        merchant.mintAndDeposit(userId, amount, depositTxHash);

        assetCXVault.setUserEpochAssets(user, epochID, 600e18);

        vm.prank(operator);
        merchant.claimVaultWithdrawal(userId, epochID);

        vm.startPrank(operator);
        merchant.finalizeQCRedemption(userId, 400e18, finalizeTxHash);
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.TxHashAlreadyUsed.selector, finalizeTxHash));
        merchant.finalizeQCRedemption(userId, 100e18, finalizeTxHash);
        vm.stopPrank();
    }

    function test_finalizeQCRedemption_revertsWhenTxHashEmpty() public {
        bytes32 userId = keccak256("user-finalize-empty-hash");
        uint256 amount = 1_000e18;
        uint256 epochID = 1;
        bytes32 depositTxHash = keccak256(bytes("finalize-empty-deposit"));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(operator);
        merchant.mintAndDeposit(userId, amount, depositTxHash);

        assetCXVault.setUserEpochAssets(user, epochID, amount);

        vm.prank(operator);
        merchant.claimVaultWithdrawal(userId, epochID);

        vm.expectRevert(IConcreteMerchant.InvalidTxHash.selector);
        vm.prank(operator);
        merchant.finalizeQCRedemption(userId, amount, bytes32(0));
    }

    function test_setVaultYieldConfig_revertsWhenInvalid() public {
        vm.expectRevert(IConcreteMerchant.InvalidAddress.selector);
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(0), address(strategy), yieldMultisigAddress);

        vm.expectRevert(IConcreteMerchant.InvalidAddress.selector);
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(assetCXVault), address(0), yieldMultisigAddress);

        vm.expectRevert(IConcreteMerchant.InvalidAddress.selector);
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(assetCXVault), address(strategy), address(0));
    }

    function test_setVaultYieldConfig_revertsWhenNotManager() public {
        address outsider = address(0x55);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, merchant.MERCHANT_MANAGER_ROLE()
            )
        );
        vm.prank(outsider);
        merchant.setVaultYieldConfig(address(assetCXVault), address(strategy), yieldMultisigAddress);
    }

    function test_setVaultYieldConfig_revertsWhenStrategyVaultMismatch() public {
        // Create a different vault
        MockAssetCXVault otherVault = new MockAssetCXVault(assetCX);

        // Create a strategy associated with the other vault
        MockMultisigStrategy otherStrategy =
            new MockMultisigStrategy(yieldMultisigAddress, assetCX, address(otherVault));

        // Try to set vault yield config with assetCXVault but strategy is associated with otherVault
        vm.expectRevert(
            abi.encodeWithSelector(
                IConcreteMerchant.StrategyVaultMismatch.selector, address(otherVault), address(assetCXVault)
            )
        );
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(assetCXVault), address(otherStrategy), yieldMultisigAddress);

        // Should succeed when using the correct vault
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(otherVault), address(otherStrategy), yieldMultisigAddress);

        assertEq(merchant.vaultYieldStrategy(address(otherVault)), address(otherStrategy));
    }

    /*//////////////////////////////////////////////////////////////
                  YIELD TOKEN WHITELIST (MULTI-TOKEN MGMT)
    //////////////////////////////////////////////////////////////*/

    function test_initialize_leavesWhitelistEmpty() public {
        // A fresh deployment must NOT auto-whitelist anything. Operators are expected
        // to populate the whitelist via {setYieldTokenWhitelisted}; the test fixture
        // does so in setUp, so to assert the bare init behaviour we spin up a brand
        // new proxy here.
        ConcreteMerchant impl = new ConcreteMerchant();
        ERC1967Proxy bareProxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(ConcreteMerchant.initialize, (admin, assetCX, IERC4626(address(assetCXVault)), address(0)))
        );
        ConcreteMerchant bare = ConcreteMerchant(address(bareProxy));

        assertFalse(bare.isYieldTokenWhitelisted(address(yieldToken)));
        assertEq(bare.getWhitelistedYieldTokens().length, 0);
        assertEq(bare.getWhitelistedYieldTokens().length, 0);
    }

    function test_setup_whitelistsYieldToken() public view {
        // The shared test fixture explicitly whitelists `yieldToken` post-init so the
        // rest of the suite can immediately exercise yield-flow tests. Lock that
        // ordering down so a regression in setUp surfaces here rather than in some
        // unrelated test downstream.
        assertTrue(merchant.isYieldTokenWhitelisted(address(yieldToken)));
        assertEq(merchant.getWhitelistedYieldTokens().length, 1);
        address[] memory whitelist = merchant.getWhitelistedYieldTokens();
        assertEq(whitelist.length, 1);
        assertEq(whitelist[0], address(yieldToken));
    }

    function test_setYieldTokenWhitelisted_addsToList() public {
        MockYieldToken extraToken = new MockYieldToken();
        vm.prank(admin);
        merchant.setYieldTokenWhitelisted(address(extraToken), true);

        assertTrue(merchant.isYieldTokenWhitelisted(address(extraToken)));
        assertEq(merchant.getWhitelistedYieldTokens().length, 2);
        address[] memory whitelist = merchant.getWhitelistedYieldTokens();
        assertEq(whitelist.length, 2);
        // The order is implementation-defined (push semantics), but membership is
        // observable via both axes.
        assertTrue(
            (whitelist[0] == address(yieldToken) && whitelist[1] == address(extraToken))
                || (whitelist[1] == address(yieldToken) && whitelist[0] == address(extraToken))
        );
    }

    function test_setYieldTokenWhitelisted_removesViaSwapAndPop() public {
        // Whitelist three tokens, then remove the middle one and confirm the list
        // remains dense (no stale entry) and membership is updated.
        MockYieldToken t2 = new MockYieldToken();
        MockYieldToken t3 = new MockYieldToken();
        vm.startPrank(admin);
        merchant.setYieldTokenWhitelisted(address(t2), true);
        merchant.setYieldTokenWhitelisted(address(t3), true);
        merchant.setYieldTokenWhitelisted(address(t2), false);
        vm.stopPrank();

        assertFalse(merchant.isYieldTokenWhitelisted(address(t2)));
        assertTrue(merchant.isYieldTokenWhitelisted(address(t3)));
        assertEq(merchant.getWhitelistedYieldTokens().length, 2);

        address[] memory whitelist = merchant.getWhitelistedYieldTokens();
        for (uint256 i = 0; i < whitelist.length; i++) {
            assertTrue(whitelist[i] != address(t2), "removed token should not appear");
        }
    }

    function test_setYieldTokenWhitelisted_revertsWhenZeroAddress() public {
        vm.expectRevert(IConcreteMerchant.InvalidAddress.selector);
        vm.prank(admin);
        merchant.setYieldTokenWhitelisted(address(0), true);
    }

    function test_setYieldTokenWhitelisted_revertsWhenAddingAlreadyWhitelisted() public {
        // `yieldToken` is auto-whitelisted at construction; re-adding must surface
        // the duplicate-add error so governance proposals don't silently no-op.
        vm.expectRevert(
            abi.encodeWithSelector(IConcreteMerchant.YieldTokenAlreadyWhitelisted.selector, address(yieldToken))
        );
        vm.prank(admin);
        merchant.setYieldTokenWhitelisted(address(yieldToken), true);
    }

    function test_setYieldTokenWhitelisted_revertsWhenRemovingNonWhitelisted() public {
        MockYieldToken ghost = new MockYieldToken();
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.YieldTokenNotWhitelisted.selector, address(ghost)));
        vm.prank(admin);
        merchant.setYieldTokenWhitelisted(address(ghost), false);
    }

    function test_setYieldTokenWhitelisted_revertsWhenCapReached() public {
        // The seed yield asset already occupies slot 0, so we fill the remaining 9 and
        // then expect the 10th additional add (i.e. the 11th overall) to revert.
        uint256 cap = merchant.MAX_WHITELISTED_YIELD_TOKENS();
        for (uint256 i = 0; i < cap - 1; i++) {
            MockYieldToken t = new MockYieldToken();
            vm.prank(admin);
            merchant.setYieldTokenWhitelisted(address(t), true);
        }
        assertEq(merchant.getWhitelistedYieldTokens().length, cap);

        MockYieldToken overflowToken = new MockYieldToken();
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.YieldTokenWhitelistFull.selector, cap));
        vm.prank(admin);
        merchant.setYieldTokenWhitelisted(address(overflowToken), true);
    }

    function test_setYieldTokenWhitelisted_revertsWhenRemovingTokenWithPending() public {
        // Open an accrual against the seeded yield token, then attempt to revoke it.
        // The invariant guard must keep the token whitelisted until pending drains.
        uint256 amount = 100e18;
        uint256 nonce = merchant.getNextYieldNonce();
        yieldToken.mint(address(strategy), amount);
        strategy.approveSpender(yieldToken, address(merchant), amount);
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, nonce);

        vm.expectRevert(
            abi.encodeWithSelector(IConcreteMerchant.PendingYieldForToken.selector, address(yieldToken), amount)
        );
        vm.prank(admin);
        merchant.setYieldTokenWhitelisted(address(yieldToken), false);

        // After finalize, the de-whitelist succeeds.
        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), nonce, amount, keccak256(bytes("dewhitelist-after-drain")));
        vm.prank(admin);
        merchant.setYieldTokenWhitelisted(address(yieldToken), false);
        assertFalse(merchant.isYieldTokenWhitelisted(address(yieldToken)));
    }

    function test_setVaultYieldConfig_iteratesAcrossMultipleTokens() public {
        // Whitelist a second yield token and open accruals against BOTH tokens for the
        // same vault. The pending guard must report the offending token (whichever is
        // hit first in the enumeration) rather than silently accept the config change.
        MockYieldToken otherToken = new MockYieldToken();
        vm.prank(admin);
        merchant.setYieldTokenWhitelisted(address(otherToken), true);

        // Accrual #1 in the seeded yieldToken.
        uint256 nonce1 = merchant.getNextYieldNonce();
        yieldToken.mint(address(strategy), 100e18);
        strategy.approveSpender(yieldToken, address(merchant), 100e18);
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), 100e18, nonce1);

        // Accrual #2 in the newly whitelisted otherToken.
        uint256 nonce2 = merchant.getNextYieldNonce();
        otherToken.mint(address(strategy), 50e18);
        strategy.approveSpender(IERC20(address(otherToken)), address(merchant), 50e18);
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(otherToken), 50e18, nonce2);

        MockMultisigStrategy newStrategy =
            new MockMultisigStrategy(yieldMultisigAddress, assetCX, address(assetCXVault));

        // The whitelist enumeration order is implementation-defined (push order with
        // swap-and-pop semantics) so we don't pin a specific token in the revert; we
        // just assert SOME token causes the guard to fire.
        vm.expectRevert();
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(assetCXVault), address(newStrategy), yieldMultisigAddress);

        // Finalize the first token's accrual; the guard should still revert because
        // the second token still has pending.
        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), nonce1, 100e18, keccak256(bytes("iter-finalize-1")));
        vm.expectRevert(
            abi.encodeWithSelector(
                IConcreteMerchant.PendingYieldForVault.selector, address(assetCXVault), address(otherToken), 50e18
            )
        );
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(assetCXVault), address(newStrategy), yieldMultisigAddress);

        // Finalize the second token's accrual. Now the config change must succeed.
        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), nonce2, 50e18, keccak256(bytes("iter-finalize-2")));
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(assetCXVault), address(newStrategy), yieldMultisigAddress);
        assertEq(merchant.vaultYieldStrategy(address(assetCXVault)), address(newStrategy));
    }

    function test_setVaultYieldConfig_revertsWhenPendingYield() public {
        uint256 amount = 500e18;
        uint256 nonce = merchant.getNextYieldNonce();

        // Mint yield tokens and initiate yield accrual
        yieldToken.mint(address(strategy), amount);
        strategy.approveSpender(yieldToken, address(merchant), amount);

        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, nonce);

        // Per-token / per-(vault, token) pending is the source of truth for the guard.
        assertEq(merchant.pendingYieldForVaultByToken(address(assetCXVault), address(yieldToken)), amount);

        // Create a new strategy for the same vault
        MockMultisigStrategy newStrategy =
            new MockMultisigStrategy(yieldMultisigAddress, assetCX, address(assetCXVault));

        // The guard iterates the whitelist and surfaces the first token with pending.
        vm.expectRevert(
            abi.encodeWithSelector(
                IConcreteMerchant.PendingYieldForVault.selector, address(assetCXVault), address(yieldToken), amount
            )
        );
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(assetCXVault), address(newStrategy), yieldMultisigAddress);

        // Finalize the yield accrual
        bytes32 txHash = keccak256(bytes("yield-finalize-pending-test"));
        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), nonce, amount, txHash);

        // Verify per-token pending is now zero for both axes.
        assertEq(merchant.pendingYieldForVaultByToken(address(assetCXVault), address(yieldToken)), 0);
        assertEq(merchant.totalPendingYieldByToken(address(yieldToken)), 0);

        // Now the config change should succeed
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(assetCXVault), address(newStrategy), yieldMultisigAddress);

        assertEq(merchant.vaultYieldStrategy(address(assetCXVault)), address(newStrategy));
    }

    function test_initiateYieldAccrual_success() public {
        uint256 amount = 500e18;
        uint256 nonce = merchant.getNextYieldNonce();

        yieldToken.mint(address(strategy), amount);
        strategy.approveSpender(yieldToken, address(merchant), amount);

        // Three indexed topics: nonce, yieldToken, vault. Match all topics + data.
        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.PendingYieldAccrual(
            nonce, address(yieldToken), address(assetCXVault), amount, amount, amount
        );

        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, nonce);

        assertEq(yieldToken.balanceOf(yieldMultisigAddress), amount);
        assertEq(merchant.pendingYield(nonce), amount);
        assertEq(merchant.totalPendingYieldByToken(address(yieldToken)), amount);
        assertEq(merchant.pendingYieldForVaultByToken(address(assetCXVault), address(yieldToken)), amount);
        assertEq(merchant.yieldTokenForPendingYieldNonce(nonce), address(yieldToken));
    }

    function test_initiateYieldAccrual_revertsWhenNonceAlreadyPending() public {
        uint256 amount = 500e18;
        uint256 nonce = merchant.getNextYieldNonce();

        yieldToken.mint(address(strategy), amount * 2);
        strategy.approveSpender(yieldToken, address(merchant), amount * 2);

        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, nonce);

        assertEq(yieldToken.balanceOf(yieldMultisigAddress), amount);

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.YieldNonceAlreadyPending.selector, nonce));
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, nonce);
    }

    function test_initiateYieldAccrual_revertsWhenConfigMissing() public {
        ConcreteMerchant implementation = new ConcreteMerchant();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(ConcreteMerchant.initialize, (admin, assetCX, IERC4626(address(assetCXVault)), address(0)))
        );
        ConcreteMerchant otherMerchant = ConcreteMerchant(address(proxy));

        vm.startPrank(admin);
        assetCX.grantRole(MERCHANT_ROLE, address(otherMerchant));
        otherMerchant.grantRole(otherMerchant.OPERATOR_ROLE(), operator);
        // Note: vault yield config is not set, so it should fail
        vm.stopPrank();

        yieldToken.mint(address(strategy), 100e18);
        strategy.approveSpender(yieldToken, address(otherMerchant), 100e18);

        uint256 nonce = otherMerchant.getNextYieldNonce();
        vm.expectRevert(IConcreteMerchant.YieldConfigNotSet.selector);
        vm.prank(address(strategy));
        otherMerchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), 100e18, nonce);
    }

    function test_initiateYieldAccrual_revertsWhenNonceNotSequential() public {
        uint256 amount = 500e18;
        yieldToken.mint(address(strategy), amount * 3);
        strategy.approveSpender(yieldToken, address(merchant), amount * 3);

        // Test 1: Use the correct first nonce
        uint256 firstNonce = merchant.getNextYieldNonce();
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, firstNonce);

        // Test 2: Try to reuse the same nonce (should fail with YieldNonceAlreadyPending)
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.YieldNonceAlreadyPending.selector, firstNonce));
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, firstNonce);

        // Test 3: Try to skip a nonce (use nonce + 2 instead of nonce + 1) - should fail with InvalidNonce
        uint256 expectedNextNonce = merchant.getNextYieldNonce();
        uint256 skippedNonce = expectedNextNonce + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IConcreteMerchant.InvalidNonce.selector, expectedNextNonce, skippedNonce)
        );
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, skippedNonce);

        // Test 4: Use the correct second nonce
        uint256 secondNonce = merchant.getNextYieldNonce();
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, secondNonce);

        // Test 5: Finalize the first nonce
        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), firstNonce, amount, keccak256(bytes("finalize-1")));

        // Test 6: Try to reuse the finalized nonce - should fail with InvalidNonce (not YieldNonceAlreadyPending)
        uint256 currentExpectedNonce = merchant.getNextYieldNonce();
        vm.expectRevert(
            abi.encodeWithSelector(IConcreteMerchant.InvalidNonce.selector, currentExpectedNonce, firstNonce)
        );
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, firstNonce);

        // Test 7: Use the correct third nonce
        uint256 thirdNonce = merchant.getNextYieldNonce();
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, thirdNonce);

        assertEq(merchant.pendingYield(secondNonce), amount);
        assertEq(merchant.pendingYield(thirdNonce), amount);
        assertEq(merchant.totalPendingYieldByToken(address(yieldToken)), amount * 2);
        // Nonce sequence stays continuous regardless of which token is being accrued.
        assertEq(merchant.getNextYieldNonce(), thirdNonce + 1);
    }

    function test_finalizeYieldAccrual_success() public {
        uint256 amount = 750e18;
        uint256 nonce = merchant.getNextYieldNonce();
        bytes32 txHash = keccak256(bytes("yield-finalize-success"));

        yieldToken.mint(address(strategy), amount);
        strategy.approveSpender(yieldToken, address(merchant), amount);

        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, nonce);

        assertEq(merchant.pendingYield(nonce), amount);
        assertEq(merchant.totalPendingYieldByToken(address(yieldToken)), amount);

        assertEq(merchant.pendingYieldForVaultByToken(address(assetCXVault), address(yieldToken)), amount);
        assertEq(assetCX.balanceOf(yieldMultisigAddress), 0);

        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.YieldAccrualFinalized(
            nonce, address(yieldToken), address(assetCXVault), amount, amount, txHash
        );

        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), nonce, amount, txHash);

        assertEq(merchant.pendingYield(nonce), 0);
        assertEq(merchant.yieldTokenForPendingYieldNonce(nonce), address(0));
        assertEq(merchant.totalPendingYieldByToken(address(yieldToken)), 0);
        assertEq(assetCX.balanceOf(yieldMultisigAddress), amount);
        assertEq(merchant.pendingYieldForVaultByToken(address(assetCXVault), address(yieldToken)), 0);
        assertEq(strategy.lastDiff(), int256(amount));
        assertEq(strategy.lastAccountingNonce(), 1);
        assertEq(strategy.getNextAccountingNonce(), 2);
    }

    function test_finalizeYieldAccrual_allowsDifferentRedeemedAmount() public {
        uint256 pendingAmount = 400e18;
        uint256 redeemedAmount = 350e18;
        uint256 nonce = merchant.getNextYieldNonce();
        bytes32 txHash = keccak256(bytes("yield-finalize-diff"));

        yieldToken.mint(address(strategy), pendingAmount);
        strategy.approveSpender(yieldToken, address(merchant), pendingAmount);

        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), pendingAmount, nonce);

        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.YieldAccrualFinalized(
            nonce, address(yieldToken), address(assetCXVault), pendingAmount, redeemedAmount, txHash
        );

        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), nonce, redeemedAmount, txHash);

        assertEq(merchant.pendingYield(nonce), 0);
        assertEq(merchant.totalPendingYieldByToken(address(yieldToken)), 0);
        assertEq(assetCX.balanceOf(yieldMultisigAddress), redeemedAmount);
        assertEq(strategy.lastDiff(), int256(redeemedAmount));
        assertEq(strategy.lastAccountingNonce(), 1);
        assertEq(strategy.getNextAccountingNonce(), 2);
    }

    function test_finalizeYieldAccrual_revertsWhenNoPending() public {
        bytes32 txHash = keccak256(bytes("yield-finalize-no-pending"));
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.NoPendingYieldForNonce.selector, 99));
        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), 99, 100e18, txHash);
    }

    function test_finalizeQCRedemption_revertsWhenSenderNotOperator() public {
        vm.startPrank(admin);
        merchant.revokeRole(merchant.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, merchant.OPERATOR_ROLE()
            )
        );
        vm.prank(operator);
        merchant.finalizeQCRedemption(keccak256("user-finalize-forbidden"), 100, keccak256("tx"));
    }

    function test_finalizeYieldAccrual_revertsWhenSenderNotOperator() public {
        bytes32 txHash = keccak256(bytes("yield-finalize-not-operator"));
        vm.startPrank(admin);
        merchant.revokeRole(merchant.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, merchant.OPERATOR_ROLE()
            )
        );
        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), 1, 100e18, txHash);
    }

    function test_finalizeYieldAccrual_revertsWhenTxHashReused() public {
        uint256 amount = 500e18;
        uint256 nonce = merchant.getNextYieldNonce();
        bytes32 txHash = keccak256(bytes("yield-finalize-reuse"));

        yieldToken.mint(address(strategy), amount);
        strategy.approveSpender(yieldToken, address(merchant), amount);

        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, nonce);

        vm.startPrank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), nonce, amount, txHash);
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.TxHashAlreadyUsed.selector, txHash));
        merchant.finalizeYieldAccrual(address(assetCXVault), nonce, amount, txHash);
        vm.stopPrank();
    }

    function test_finalizeYieldAccrual_revertsWhenTxHashEmpty() public {
        uint256 amount = 500e18;
        uint256 nonce = merchant.getNextYieldNonce();

        yieldToken.mint(address(strategy), amount);
        strategy.approveSpender(yieldToken, address(merchant), amount);

        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), amount, nonce);

        vm.expectRevert(IConcreteMerchant.InvalidTxHash.selector);
        vm.prank(operator);
        merchant.finalizeYieldAccrual(address(assetCXVault), nonce, amount, bytes32(0));
    }

    function test_redeem_success() public {
        address receiver = address(0x1234);
        uint256 amount = 500e18;

        // Mint assetCX directly to the user
        _mintAssetCXTo(user, amount);

        // User needs to approve the merchant to transfer tokens
        vm.prank(user);
        assetCX.approve(address(merchant), amount);

        uint256 totalSupplyBefore = assetCX.totalSupply();
        uint256 userBalanceBefore = assetCX.balanceOf(user);
        assertEq(merchant.pendingAssetCxRedemption(receiver), 0);
        assertGt(userBalanceBefore, 0);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.AssetCxRedemption(receiver, amount, amount);

        vm.prank(user);
        merchant.redeem(amount, receiver);

        assertEq(assetCX.totalSupply(), totalSupplyBefore - amount);
        assertEq(assetCX.balanceOf(user), userBalanceBefore - amount);
        assertEq(assetCX.balanceOf(address(merchant)), 0);
        assertEq(merchant.pendingAssetCxRedemption(receiver), amount);
    }

    function test_redeem_additive() public {
        address receiver = address(0x5678);
        uint256 firstAmount = 300e18;
        uint256 secondAmount = 200e18;

        // Mint assetCX directly to the user
        _mintAssetCXTo(user, firstAmount + secondAmount);

        vm.prank(user);
        assetCX.approve(address(merchant), firstAmount + secondAmount);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.AssetCxRedemption(receiver, firstAmount, firstAmount);
        vm.prank(user);
        merchant.redeem(firstAmount, receiver);

        assertEq(merchant.pendingAssetCxRedemption(receiver), firstAmount);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.AssetCxRedemption(receiver, secondAmount, firstAmount + secondAmount);
        vm.prank(user);
        merchant.redeem(secondAmount, receiver);

        assertEq(merchant.pendingAssetCxRedemption(receiver), firstAmount + secondAmount);
    }

    function test_redeem_multipleReceivers() public {
        address receiver1 = address(0x1111);
        address receiver2 = address(0x2222);
        uint256 amount1 = 400e18;
        uint256 amount2 = 300e18;

        // Mint assetCX directly to the user
        _mintAssetCXTo(user, amount1 + amount2);

        vm.prank(user);
        assetCX.approve(address(merchant), amount1 + amount2);

        vm.prank(user);
        merchant.redeem(amount1, receiver1);

        vm.prank(user);
        merchant.redeem(amount2, receiver2);

        assertEq(merchant.pendingAssetCxRedemption(receiver1), amount1);
        assertEq(merchant.pendingAssetCxRedemption(receiver2), amount2);
    }

    function test_redeem_revertsWhenAmountZero() public {
        address receiver = address(0x9999);

        vm.expectRevert(IConcreteMerchant.InvalidAmount.selector);
        vm.prank(user);
        merchant.redeem(0, receiver);
    }

    function test_redeem_revertsWhenReceiverZero() public {
        uint256 amount = 100e18;

        // Mint assetCX directly to the user
        _mintAssetCXTo(user, amount);

        vm.prank(user);
        assetCX.approve(address(merchant), amount);

        vm.expectRevert(IConcreteMerchant.InvalidAddress.selector);
        vm.prank(user);
        merchant.redeem(amount, address(0));
    }

    function test_redeem_revertsWhenInsufficientBalance() public {
        address receiver = address(0x8888);
        uint256 amount = 1000e18;

        vm.prank(user);
        assetCX.approve(address(merchant), amount);

        vm.expectRevert();
        vm.prank(user);
        merchant.redeem(amount, receiver);
    }

    function test_finalizeAssetCxRedemption_success() public {
        address receiver = address(0xABCD);
        uint256 redeemAmount = 600e18;
        uint256 finalizeAmount = 400e18;
        bytes32 txHash = keccak256(bytes("finalize-success"));

        // Mint assetCX directly to the user
        _mintAssetCXTo(user, redeemAmount);

        vm.prank(user);
        assetCX.approve(address(merchant), redeemAmount);

        vm.prank(user);
        merchant.redeem(redeemAmount, receiver);

        assertEq(merchant.pendingAssetCxRedemption(receiver), redeemAmount);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.AssetCxRedemptionFinalized(
            receiver, finalizeAmount, redeemAmount - finalizeAmount, txHash
        );

        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(receiver, finalizeAmount, txHash);

        assertEq(merchant.pendingAssetCxRedemption(receiver), redeemAmount - finalizeAmount);
    }

    function test_finalizeAssetCxRedemption_multipleFinalizations() public {
        address receiver = address(0xEF01);
        uint256 redeemAmount = 1000e18;
        uint256 firstFinalize = 300e18;
        uint256 secondFinalize = 200e18;
        bytes32 firstTxHash = keccak256(bytes("finalize-multi-1"));
        bytes32 secondTxHash = keccak256(bytes("finalize-multi-2"));

        // Mint assetCX directly to the user
        _mintAssetCXTo(user, redeemAmount);

        vm.prank(user);
        assetCX.approve(address(merchant), redeemAmount);

        vm.prank(user);
        merchant.redeem(redeemAmount, receiver);

        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(receiver, firstFinalize, firstTxHash);

        assertEq(merchant.pendingAssetCxRedemption(receiver), redeemAmount - firstFinalize);

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.AssetCxRedemptionFinalized(
            receiver, secondFinalize, redeemAmount - firstFinalize - secondFinalize, secondTxHash
        );

        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(receiver, secondFinalize, secondTxHash);

        assertEq(merchant.pendingAssetCxRedemption(receiver), redeemAmount - firstFinalize - secondFinalize);
    }

    function test_finalizeAssetCxRedemption_revertsWhenAmountZero() public {
        address receiver = address(0x0001);
        bytes32 txHash = keccak256(bytes("finalize-zero-amount"));

        vm.expectRevert(IConcreteMerchant.InvalidAmount.selector);
        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(receiver, 0, txHash);
    }

    function test_finalizeAssetCxRedemption_revertsWhenReceiverZero() public {
        bytes32 txHash = keccak256(bytes("finalize-zero-receiver"));

        vm.expectRevert(IConcreteMerchant.InvalidAddress.selector);
        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(address(0), 100e18, txHash);
    }

    function test_finalizeAssetCxRedemption_revertsWhenInsufficientPending() public {
        address receiver = address(0x0002);
        uint256 redeemAmount = 500e18;
        uint256 finalizeAmount = 600e18;
        bytes32 txHash = keccak256(bytes("finalize-insufficient"));

        // Mint assetCX directly to the user
        _mintAssetCXTo(user, redeemAmount);

        vm.prank(user);
        assetCX.approve(address(merchant), redeemAmount);

        vm.prank(user);
        merchant.redeem(redeemAmount, receiver);

        vm.expectRevert(
            abi.encodeWithSelector(IConcreteMerchant.WrongRedemptionAmount.selector, finalizeAmount, redeemAmount)
        );
        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(receiver, finalizeAmount, txHash);
    }

    function test_finalizeAssetCxRedemption_revertsWhenSenderNotOperator() public {
        address receiver = address(0x0003);
        uint256 amount = 100e18;
        bytes32 txHash = keccak256(bytes("finalize-not-operator"));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, merchant.OPERATOR_ROLE()
            )
        );
        vm.prank(user);
        merchant.finalizeAssetCxRedemption(receiver, amount, txHash);
    }

    function test_finalizeAssetCxRedemption_revertsWhenOperatorRevoked() public {
        address receiver = address(0x0004);
        uint256 amount = 100e18;
        bytes32 txHash = keccak256(bytes("finalize-revoked"));

        vm.startPrank(admin);
        merchant.revokeRole(merchant.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, merchant.OPERATOR_ROLE()
            )
        );
        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(receiver, amount, txHash);
    }

    function test_finalizeAssetCxRedemption_revertsWhenTxHashReused() public {
        address receiver = address(0x0005);
        uint256 redeemAmount = 500e18;
        uint256 finalizeAmount = 300e18;
        bytes32 txHash = keccak256(bytes("finalize-reuse"));

        // Mint assetCX directly to the user
        _mintAssetCXTo(user, redeemAmount);

        vm.prank(user);
        assetCX.approve(address(merchant), redeemAmount);

        vm.prank(user);
        merchant.redeem(redeemAmount, receiver);

        vm.startPrank(operator);
        merchant.finalizeAssetCxRedemption(receiver, finalizeAmount, txHash);
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.TxHashAlreadyUsed.selector, txHash));
        merchant.finalizeAssetCxRedemption(receiver, 100e18, txHash);
        vm.stopPrank();
    }

    function test_finalizeAssetCxRedemption_revertsWhenTxHashEmpty() public {
        address receiver = address(0x0006);
        uint256 redeemAmount = 500e18;
        uint256 finalizeAmount = 300e18;

        // Mint assetCX directly to the user
        _mintAssetCXTo(user, redeemAmount);

        vm.prank(user);
        assetCX.approve(address(merchant), redeemAmount);

        vm.prank(user);
        merchant.redeem(redeemAmount, receiver);

        vm.expectRevert(IConcreteMerchant.InvalidTxHash.selector);
        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(receiver, finalizeAmount, bytes32(0));
    }

    function test_redeem_and_finalize_completeFlow() public {
        address receiver = address(0xFFFF);
        uint256 totalRedeem = 1000e18;
        uint256 firstRedeem = 400e18;
        uint256 secondRedeem = 300e18;
        uint256 thirdRedeem = 300e18;
        uint256 firstFinalize = 500e18;
        uint256 secondFinalize = 300e18;

        // Mint assetCX directly to the user
        _mintAssetCXTo(user, totalRedeem);

        vm.prank(user);
        assetCX.approve(address(merchant), totalRedeem);

        // Multiple redemptions
        vm.prank(user);
        merchant.redeem(firstRedeem, receiver);
        assertEq(merchant.pendingAssetCxRedemption(receiver), firstRedeem);

        vm.prank(user);
        merchant.redeem(secondRedeem, receiver);
        assertEq(merchant.pendingAssetCxRedemption(receiver), firstRedeem + secondRedeem);

        vm.prank(user);
        merchant.redeem(thirdRedeem, receiver);
        assertEq(merchant.pendingAssetCxRedemption(receiver), totalRedeem);

        // Finalize redemptions
        bytes32 firstTxHash = keccak256(bytes("complete-flow-1"));
        bytes32 secondTxHash = keccak256(bytes("complete-flow-2"));
        bytes32 thirdTxHash = keccak256(bytes("complete-flow-3"));

        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(receiver, firstFinalize, firstTxHash);
        assertEq(merchant.pendingAssetCxRedemption(receiver), totalRedeem - firstFinalize);

        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(receiver, secondFinalize, secondTxHash);
        assertEq(merchant.pendingAssetCxRedemption(receiver), totalRedeem - firstFinalize - secondFinalize);

        // Finalize remaining
        uint256 remaining = totalRedeem - firstFinalize - secondFinalize;
        vm.prank(operator);
        merchant.finalizeAssetCxRedemption(receiver, remaining, thirdTxHash);
        assertEq(merchant.pendingAssetCxRedemption(receiver), 0);
    }

    function test_emergencyMigrateUserAccount_success() public {
        bytes32 userId = keccak256("user-emergency-migrate");
        address newUser = address(0x1111);
        bytes32 txHash = keccak256(bytes("emergency-migrate-deposit"));
        uint256 depositAmount = 500e18;

        MockWhitelistHook whitelistHook = new MockWhitelistHook();
        assetCXVault.setHook(address(whitelistHook));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        // Make a deposit
        vm.prank(operator);
        merchant.mintAndDeposit(userId, depositAmount, txHash);

        assertEq(merchant.mintedVaultShares(userId), depositAmount);
        assertEq(assetCXVault.balanceOf(user), depositAmount);

        // User approves merchant to transfer their vault shares
        vm.prank(user);
        IERC20(address(assetCXVault)).approve(address(merchant), depositAmount);

        // Admin performs emergency migration
        vm.expectEmit(true, true, true, true, address(merchant));
        emit IConcreteMerchant.EmergencyUserAccountMigrated(userId, user, newUser, depositAmount);

        vm.prank(admin);
        merchant.emergencyMigrateUserAccount(userId, newUser);

        // Verify shares were transferred
        assertEq(assetCXVault.balanceOf(user), 0);
        assertEq(assetCXVault.balanceOf(newUser), depositAmount);

        // Verify user account was updated
        assertEq(merchant.getUserAccount(userId), newUser);

        // Verify whitelist status
        assertTrue(whitelistHook.userWhitelisted(newUser));
        assertFalse(whitelistHook.userWhitelisted(user));

        // =========================================
        // Verify operations work for new account
        // =========================================

        // Verify merchant accounting remains consistent
        assertEq(merchant.totalMinted(userId), depositAmount);
        assertEq(merchant.mintedVaultShares(userId), depositAmount);
        assertEq(merchant.totalBurned(userId), 0);
        assertEq(merchant.pendingQCRedemption(userId), 0);

        // Simulate vault withdrawal request - set epoch assets for NEW user
        uint256 epochID = 1;
        uint256 withdrawAmount = 200e18;
        assetCXVault.setUserEpochAssets(newUser, epochID, withdrawAmount);

        // Claim vault withdrawal should work with new account
        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.PendingQCRedemption(userId, epochID, withdrawAmount, withdrawAmount, withdrawAmount);

        vm.prank(operator);
        uint256 claimed = merchant.claimVaultWithdrawal(userId, epochID);

        // Verify claim worked
        assertEq(claimed, withdrawAmount);
        assertEq(merchant.pendingQCRedemption(userId), withdrawAmount);
        assertEq(merchant.totalPendingQCRedemption(), withdrawAmount);
        assertEq(merchant.totalBurned(userId), withdrawAmount);
        assertEq(merchant.mintedVaultShares(userId), depositAmount - withdrawAmount);

        // Finalize QC redemption
        bytes32 finalizeTxHash = keccak256(bytes("emergency-finalize-qc"));
        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.QCRedemptionFinalized(userId, withdrawAmount, 0, 0, finalizeTxHash);

        vm.prank(operator);
        merchant.finalizeQCRedemption(userId, withdrawAmount, finalizeTxHash);

        // Verify finalization worked
        assertEq(merchant.pendingQCRedemption(userId), 0);
        assertEq(merchant.totalPendingQCRedemption(), 0);

        // Verify final accounting state is consistent
        assertEq(merchant.totalMinted(userId), depositAmount);
        assertEq(merchant.totalBurned(userId), withdrawAmount);
        assertEq(merchant.mintedVaultShares(userId), depositAmount - withdrawAmount);
    }

    function test_emergencyMigrateUserAccount_revertsWhenNotAdmin() public {
        bytes32 userId = keccak256("user-emergency-not-admin");
        address newUser = address(0x2222);

        MockWhitelistHook whitelistHook = new MockWhitelistHook();
        assetCXVault.setHook(address(whitelistHook));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, merchant.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(operator);
        merchant.emergencyMigrateUserAccount(userId, newUser);
    }

    function test_emergencyMigrateUserAccount_revertsWhenNoDeposits() public {
        bytes32 userId = keccak256("user-emergency-no-deposits");
        address newUser = address(0x3333);

        MockWhitelistHook whitelistHook = new MockWhitelistHook();
        assetCXVault.setHook(address(whitelistHook));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        // No deposits made, should revert with InvalidAmount
        vm.expectRevert(IConcreteMerchant.InvalidAmount.selector);
        vm.prank(admin);
        merchant.emergencyMigrateUserAccount(userId, newUser);
    }

    function test_emergencyMigrateUserAccount_revertsWhenUnknownUser() public {
        bytes32 userId = keccak256("user-emergency-unknown");
        address newUser = address(0x4444);

        MockWhitelistHook whitelistHook = new MockWhitelistHook();
        assetCXVault.setHook(address(whitelistHook));

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.UnknownUser.selector, userId));
        vm.prank(admin);
        merchant.emergencyMigrateUserAccount(userId, newUser);
    }

    function test_emergencyMigrateUserAccount_revertsWhenNewAddressZero() public {
        bytes32 userId = keccak256("user-emergency-zero");

        MockWhitelistHook whitelistHook = new MockWhitelistHook();
        assetCXVault.setHook(address(whitelistHook));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.expectRevert(IConcreteMerchant.InvalidAddress.selector);
        vm.prank(admin);
        merchant.emergencyMigrateUserAccount(userId, address(0));
    }

    function test_emergencyMigrateUserAccount_revertsWhenInsufficientBalance() public {
        bytes32 userId = keccak256("user-emergency-insufficient");
        address newUser = address(0x5555);
        bytes32 txHash = keccak256(bytes("emergency-insufficient-deposit"));
        uint256 depositAmount = 500e18;

        MockWhitelistHook whitelistHook = new MockWhitelistHook();
        assetCXVault.setHook(address(whitelistHook));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        // Make a deposit
        vm.prank(operator);
        merchant.mintAndDeposit(userId, depositAmount, txHash);

        // User transfers some shares away (simulating an external transfer)
        vm.prank(user);
        IERC20(address(assetCXVault)).transfer(address(0xDEAD), 100e18);

        assertEq(assetCXVault.balanceOf(user), 400e18);

        // Should revert because user doesn't have enough shares
        vm.expectRevert(
            abi.encodeWithSelector(IConcreteMerchant.InsufficientShareBalance.selector, depositAmount, 400e18)
        );
        vm.prank(admin);
        merchant.emergencyMigrateUserAccount(userId, newUser);
    }

    function test_emergencyMigrateUserAccount_revertsWhenNewAccountAlreadyUsed() public {
        bytes32 userId = keccak256("user-emergency-collision-victim");
        bytes32 otherUserId = keccak256("user-emergency-collision-other");
        address otherUser = address(0x6666);
        bytes32 txHash = keccak256(bytes("emergency-collision-deposit"));
        uint256 depositAmount = 500e18;

        MockWhitelistHook whitelistHook = new MockWhitelistHook();
        assetCXVault.setHook(address(whitelistHook));

        vm.startPrank(admin);
        merchant.setUserAccount(userId, user);
        // Bind `otherUser` to a different userId so it is flagged in `usedUserAccounts`.
        merchant.setUserAccount(otherUserId, otherUser);
        vm.stopPrank();

        vm.prank(operator);
        merchant.mintAndDeposit(userId, depositAmount, txHash);

        vm.prank(user);
        IERC20(address(assetCXVault)).approve(address(merchant), depositAmount);

        // Cannot migrate `userId` to `otherUser` because that address is already claimed.
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.UserAccountAlreadyUsed.selector, otherUser));
        vm.prank(admin);
        merchant.emergencyMigrateUserAccount(userId, otherUser);

        // State must be untouched on the failed migration path.
        assertEq(merchant.getUserAccount(userId), user);
        assertEq(merchant.getUserAccount(otherUserId), otherUser);
    }

    function test_emergencyMigrateUserAccount_marksNewAccountAsUsedOldStaysMarked() public {
        bytes32 userId = keccak256("user-emergency-mark-used");
        address newUser = address(0x7777);
        bytes32 txHash = keccak256(bytes("emergency-mark-used-deposit"));
        uint256 depositAmount = 500e18;

        MockWhitelistHook whitelistHook = new MockWhitelistHook();
        assetCXVault.setHook(address(whitelistHook));

        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(operator);
        merchant.mintAndDeposit(userId, depositAmount, txHash);

        vm.prank(user);
        IERC20(address(assetCXVault)).approve(address(merchant), depositAmount);

        assertTrue(merchant.isUserAccountUsed(user));
        assertFalse(merchant.isUserAccountUsed(newUser));

        vm.prank(admin);
        merchant.emergencyMigrateUserAccount(userId, newUser);

        assertTrue(merchant.isUserAccountUsed(newUser), "new account must be flagged");
        assertTrue(merchant.isUserAccountUsed(user), "rotated-out account must stay flagged");

        // The rotated-out address cannot be reclaimed by any other userId.
        bytes32 otherUserId = keccak256("user-emergency-mark-used-other");
        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.UserAccountAlreadyUsed.selector, user));
        vm.prank(admin);
        merchant.setUserAccount(otherUserId, user);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_initialize_grantsPauserRoleToAdmin() public view {
        assertTrue(merchant.hasRole(merchant.PAUSER_ROLE(), admin), "admin should hold PAUSER_ROLE at init");
        assertFalse(merchant.paused(), "merchant should start unpaused");
    }

    function test_pause_emitsEventAndSetsState() public {
        vm.expectEmit(true, true, true, true, address(merchant));
        emit PausableUpgradeable.Paused(admin);

        vm.prank(admin);
        merchant.pause();

        assertTrue(merchant.paused(), "merchant not paused");
    }

    function test_pause_blocksMintAndDeposit() public {
        bytes32 userId = keccak256("user-paused-mint");
        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(admin);
        merchant.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(operator);
        merchant.mintAndDeposit(userId, 1e18, keccak256("blocked-mint"));
    }

    function test_pause_blocksRedeem() public {
        address receiver = address(0xBEEF);
        _mintAssetCXTo(user, 100e18);

        vm.prank(user);
        assetCX.approve(address(merchant), 100e18);

        vm.prank(admin);
        merchant.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        merchant.redeem(100e18, receiver);
    }

    function test_pause_blocksInitiateYieldAccrual() public {
        vm.prank(admin);
        merchant.pause();

        // `whenNotPaused` is the first modifier — reverts before any of the
        // configured-strategy / nonce checks fire, so we don't need to set
        // up a realistic call.
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(address(strategy));
        merchant.initiateYieldAccrual(address(assetCXVault), address(yieldToken), 1e18, 0);
    }

    function test_pause_doesNotBlockAdminConfig() public {
        // Locks in the deliberate design choice: admin / configuration
        // surface stays reachable while paused so operators can remediate
        // before unpausing. If anyone ever sprinkles `whenNotPaused` onto a
        // setter this test will (and should) fail.
        vm.prank(admin);
        merchant.pause();

        bytes32 userId = keccak256("user-config-while-paused");

        vm.prank(admin);
        merchant.setUserAccount(userId, user);
        assertEq(merchant.getUserAccount(userId), user, "setUserAccount blocked by pause");

        // setVaultYieldConfig (a different MERCHANT_MANAGER_ROLE setter)
        // also remains callable.
        MockMultisigStrategy altStrategy =
            new MockMultisigStrategy(yieldMultisigAddress, assetCX, address(assetCXVault));
        vm.prank(admin);
        merchant.setVaultYieldConfig(address(assetCXVault), address(altStrategy), yieldMultisigAddress);
        assertEq(
            merchant.vaultYieldStrategy(address(assetCXVault)),
            address(altStrategy),
            "setVaultYieldConfig blocked by pause"
        );
    }

    function test_pause_revertsWhenNotPauser() public {
        bytes32 pauserRole = merchant.PAUSER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, pauserRole)
        );
        vm.prank(user);
        merchant.pause();
    }

    function test_unpause_restoresFlow() public {
        // No timelock is wired in this fixture (`address(0)` at init), so
        // `afterDelay` on `unpause()` no-ops — exactly what we want for a
        // unit-level round-trip test. Timelock-gated unpause behaviour is
        // covered in test/timelock/TimelockIntegration.t.sol.
        vm.prank(admin);
        merchant.pause();
        assertTrue(merchant.paused(), "fixture: should be paused");

        vm.expectEmit(true, true, true, true, address(merchant));
        emit PausableUpgradeable.Unpaused(admin);

        vm.prank(admin);
        merchant.unpause();

        assertFalse(merchant.paused(), "merchant should be unpaused");

        // User-facing flow (`mintAndDeposit`) functional again.
        bytes32 userId = keccak256("user-after-unpause");
        vm.prank(admin);
        merchant.setUserAccount(userId, user);

        vm.prank(operator);
        uint256 shares = merchant.mintAndDeposit(userId, 100e18, keccak256("post-unpause"));
        assertEq(shares, 100e18, "mintAndDeposit should succeed after unpause");
    }

    function test_unpause_revertsWhenNotPauser() public {
        vm.prank(admin);
        merchant.pause();

        bytes32 pauserRole = merchant.PAUSER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, pauserRole)
        );
        vm.prank(user);
        merchant.unpause();
    }

    function test_unpause_revertsWhenNotPaused() public {
        // `_unpause()` is itself `whenPaused` — calling on an unpaused
        // contract surfaces OZ's `ExpectedPause` error.
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        vm.prank(admin);
        merchant.unpause();
    }

    function test_grantPauserRole_byAdmin() public {
        address freshPauser = address(0xAA);
        bytes32 pauserRole = merchant.PAUSER_ROLE();

        vm.prank(admin);
        merchant.grantRole(pauserRole, freshPauser);

        assertTrue(merchant.hasRole(pauserRole, freshPauser), "PAUSER_ROLE not granted");

        // Newly-onboarded pauser can pause immediately — no extra ceremony.
        vm.prank(freshPauser);
        merchant.pause();
        assertTrue(merchant.paused(), "fresh pauser unable to pause");
    }

    /*//////////////////////////////////////////////////////////////
                    V3 ROLE ENUMERABILITY MIGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC-7201 root of OZ's `AccessControlEnumerable` storage, whose `_roleMembers`
    ///      mapping sits at offset 0. Mirrored here because the extension keeps the slot private.
    bytes32 private constant _AC_ENUMERABLE_STORAGE_LOCATION =
        0xc1f6fe24621ce81ec5827caf0253cadb74709b061630e6b55e82371705932000;

    function _roleMembersSetSlot(bytes32 role) internal pure returns (bytes32) {
        return keccak256(abi.encode(role, _AC_ENUMERABLE_STORAGE_LOCATION));
    }

    /// @dev Reproduces a proxy upgraded from a non-enumerable implementation: `hasRole` keeps
    ///      reporting every pre-upgrade holder while the enumerable membership set reads empty.
    ///      Wipes the `EnumerableSet.AddressSet` behind `_roleMembers[role]` — the `_values`
    ///      length slot and its elements, plus the `_positions` entry of each listed member.
    ///      Self-verifying: a wrong layout assumption fails here instead of silently passing.
    function _clearEnumerableRoleMembers(bytes32 role, address[] memory members) internal {
        bytes32 setSlot = _roleMembersSetSlot(role);
        uint256 length = uint256(vm.load(address(merchant), setSlot));
        bytes32 elementsSlot = keccak256(abi.encode(setSlot));
        for (uint256 i = 0; i < length; ++i) {
            vm.store(address(merchant), bytes32(uint256(elementsSlot) + i), bytes32(0));
        }
        vm.store(address(merchant), setSlot, bytes32(0));

        bytes32 positionsSlot = bytes32(uint256(setSlot) + 1);
        for (uint256 i = 0; i < members.length; ++i) {
            vm.store(
                address(merchant),
                keccak256(abi.encode(bytes32(uint256(uint160(members[i]))), positionsSlot)),
                bytes32(0)
            );
            assertTrue(merchant.hasRole(role, members[i]), "helper: member must still hold the role");
        }

        assertEq(merchant.getRoleMemberCount(role), 0, "helper: membership set not cleared");
    }

    /// @dev Strips enumerable membership for every role the fixture granted, leaving the proxy in
    ///      the exact shape a live non-enumerable deployment has right after the implementation
    ///      swap but before {reinitializeV3} runs.
    function _simulateNonEnumerableProxy() internal {
        address[] memory adminOnly = new address[](1);
        adminOnly[0] = admin;
        address[] memory operatorOnly = new address[](1);
        operatorOnly[0] = operator;

        _clearEnumerableRoleMembers(merchant.DEFAULT_ADMIN_ROLE(), adminOnly);
        _clearEnumerableRoleMembers(merchant.MERCHANT_MANAGER_ROLE(), adminOnly);
        _clearEnumerableRoleMembers(merchant.PAUSER_ROLE(), adminOnly);
        _clearEnumerableRoleMembers(merchant.OPERATOR_ROLE(), operatorOnly);
    }

    function _members(address account) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = account;
    }

    function _members(address first, address second) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = first;
        list[1] = second;
    }

    function _noMembers() internal pure returns (address[] memory) {
        return new address[](0);
    }

    /// @dev Throw-away addresses that hold `DEFAULT_ADMIN_ROLE` only for the few internal calls it
    ///      takes to drop and re-enter the calling admin.
    address private constant TEMP_ADMIN_A = address(0x7E5701);
    address private constant TEMP_ADMIN_B = address(0x7E5702);

    /// @dev Runs the migration with the holder lists the fixture's proxy would produce when
    ///      reconstructed from its `RoleGranted`/`RoleRevoked` event history.
    function _reinitializeV3AsAdmin() internal {
        vm.prank(admin);
        merchant.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(admin), _members(operator), _members(admin));
    }

    function test_initialize_populatesEnumerableMembership() public view {
        // Fresh deployments need no migration at all: `initialize` and `grantRole` both route
        // through the enumerable `_grantRole` override.
        assertEq(merchant.getRoleMemberCount(merchant.DEFAULT_ADMIN_ROLE()), 1, "admin not enumerated");
        assertEq(merchant.getRoleMemberCount(merchant.MERCHANT_MANAGER_ROLE()), 1, "manager not enumerated");
        assertEq(merchant.getRoleMemberCount(merchant.PAUSER_ROLE()), 1, "pauser not enumerated");
        assertEq(merchant.getRoleMemberCount(merchant.OPERATOR_ROLE()), 1, "operator not enumerated");
        assertEq(merchant.getRoleMember(merchant.DEFAULT_ADMIN_ROLE(), 0), admin, "wrong admin enumerated");
        assertEq(merchant.getRoleMember(merchant.OPERATOR_ROLE(), 0), operator, "wrong operator enumerated");
    }

    function test_reinitializeV3_backfillsRoleMembers() public {
        _simulateNonEnumerableProxy();

        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();
        bytes32 managerRole = merchant.MERCHANT_MANAGER_ROLE();
        bytes32 operatorRole = merchant.OPERATOR_ROLE();
        bytes32 pauserRole = merchant.PAUSER_ROLE();

        // One event per role, in the order the migration seeds them: the three operational roles
        // inside the re-entry loop, then the admin role once its exit assertion has held.
        vm.expectEmit(true, false, false, true, address(merchant));
        emit IConcreteMerchant.RoleMembershipBackfilled(managerRole, 1);
        vm.expectEmit(true, false, false, true, address(merchant));
        emit IConcreteMerchant.RoleMembershipBackfilled(operatorRole, 1);
        vm.expectEmit(true, false, false, true, address(merchant));
        emit IConcreteMerchant.RoleMembershipBackfilled(pauserRole, 1);
        vm.expectEmit(true, false, false, true, address(merchant));
        emit IConcreteMerchant.RoleMembershipBackfilled(adminRole, 1);

        _reinitializeV3AsAdmin();

        // Neither stand-in may outlive the call that created it.
        assertFalse(merchant.hasRole(adminRole, TEMP_ADMIN_A), "temp admin A survived the migration");
        assertFalse(merchant.hasRole(adminRole, TEMP_ADMIN_B), "temp admin B survived the migration");

        assertEq(merchant.getRoleMemberCount(merchant.DEFAULT_ADMIN_ROLE()), 1, "admin not back-filled");
        assertEq(merchant.getRoleMemberCount(merchant.MERCHANT_MANAGER_ROLE()), 1, "manager not back-filled");
        assertEq(merchant.getRoleMemberCount(merchant.PAUSER_ROLE()), 1, "pauser not back-filled");
        assertEq(merchant.getRoleMemberCount(merchant.OPERATOR_ROLE()), 1, "operator not back-filled");

        assertEq(merchant.getRoleMembers(merchant.DEFAULT_ADMIN_ROLE())[0], admin, "wrong admin enumerated");
        assertEq(merchant.getRoleMembers(merchant.OPERATOR_ROLE())[0], operator, "wrong operator enumerated");

        // Authorization is unchanged — the migration only repaired bookkeeping.
        assertTrue(merchant.hasRole(merchant.DEFAULT_ADMIN_ROLE(), admin), "admin lost DEFAULT_ADMIN_ROLE");
        assertTrue(merchant.hasRole(merchant.OPERATOR_ROLE(), operator), "operator lost OPERATOR_ROLE");

        // And the operator hot path still works, so nothing was left half-revoked.
        bytes32 userId = keccak256("user-after-v3");
        vm.prank(admin);
        merchant.setUserAccount(userId, user);
        vm.prank(operator);
        assertEq(merchant.mintAndDeposit(userId, 10e18, keccak256("post-v3")), 10e18, "operator path broken");
    }

    function test_reinitializeV3_backfillsMultipleMembersPerRole() public {
        // The realistic shape: a role with several holders, all granted before the proxy became
        // enumerable.
        address secondOperator = address(0xB0B2);
        address thirdOperator = address(0xB0B3);
        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();
        bytes32 operatorRole = merchant.OPERATOR_ROLE();

        vm.startPrank(admin);
        merchant.grantRole(operatorRole, secondOperator);
        merchant.grantRole(operatorRole, thirdOperator);
        vm.stopPrank();

        address[] memory operators = new address[](3);
        operators[0] = operator;
        operators[1] = secondOperator;
        operators[2] = thirdOperator;

        _clearEnumerableRoleMembers(adminRole, _members(admin));
        _clearEnumerableRoleMembers(operatorRole, operators);
        _clearEnumerableRoleMembers(merchant.MERCHANT_MANAGER_ROLE(), _members(admin));
        _clearEnumerableRoleMembers(merchant.PAUSER_ROLE(), _members(admin));

        vm.expectEmit(true, false, false, true, address(merchant));
        emit IConcreteMerchant.RoleMembershipBackfilled(operatorRole, 3);

        vm.prank(admin);
        merchant.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(admin), operators, _members(admin));

        assertEq(merchant.getRoleMemberCount(adminRole), 1, "admin not back-filled");
        assertEq(merchant.getRoleMemberCount(operatorRole), 3, "all operators not back-filled");

        address[] memory enumeratedOperators = merchant.getRoleMembers(operatorRole);
        assertEq(enumeratedOperators[0], operator, "operator 1 missing");
        assertEq(enumeratedOperators[1], secondOperator, "operator 2 missing");
        assertEq(enumeratedOperators[2], thirdOperator, "operator 3 missing");
    }

    function test_reinitializeV3_isUnaffectedByLastAdminGuard() public {
        // The last-admin guard in `_revokeRole` is unconditional, so the migration satisfies it
        // with two stand-in admins rather than being exempted from it. Same storage state, two
        // outcomes: the operational path fails closed while the backfill still succeeds.
        _simulateNonEnumerableProxy();

        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(IConcreteMerchant.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        merchant.revokeRole(adminRole, admin);

        _reinitializeV3AsAdmin();

        assertEq(merchant.getRoleMemberCount(adminRole), 1, "sole admin not re-entered");
        assertEq(merchant.getRoleMember(adminRole, 0), admin, "enumerated admin is not the original");
        assertTrue(merchant.hasRole(adminRole, admin), "sole admin lost the role");
    }

    function test_reinitializeV3_leavesLastAdminGuardIntact() public {
        // The migration must not loosen the guard on its way through: once it has run, the sole
        // admin is still protected on the operational path.
        _simulateNonEnumerableProxy();
        _reinitializeV3AsAdmin();

        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(IConcreteMerchant.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        merchant.revokeRole(adminRole, admin);

        vm.expectRevert(IConcreteMerchant.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        merchant.renounceRole(adminRole, admin);

        assertTrue(merchant.hasRole(adminRole, admin), "admin must survive both attempts");
    }

    function test_reinitializeV3_revertsOnZeroTempAdmin() public {
        _simulateNonEnumerableProxy();

        vm.expectRevert(IConcreteMerchant.InvalidAddress.selector);
        vm.prank(admin);
        merchant.reinitializeV3(address(0), TEMP_ADMIN_B, _members(admin), _members(operator), _members(admin));

        vm.expectRevert(IConcreteMerchant.InvalidAddress.selector);
        vm.prank(admin);
        merchant.reinitializeV3(TEMP_ADMIN_A, address(0), _members(admin), _members(operator), _members(admin));
    }

    function test_reinitializeV3_revertsOnDegenerateTempAdmins() public {
        // A stand-in that already holds the role, the caller naming itself, or a repeated stand-in
        // is rejected up front, before any grant or revoke runs.
        address secondAdmin = address(0xA11CE2);
        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        merchant.grantRole(adminRole, secondAdmin);
        _simulateNonEnumerableProxy();
        _clearEnumerableRoleMembers(adminRole, _members(secondAdmin));

        address[] memory managers = _members(admin);
        address[] memory operators = _members(operator);
        address[] memory pausers = _members(admin);

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.InvalidTempAdmin.selector, TEMP_ADMIN_A));
        vm.prank(admin);
        merchant.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_A, managers, operators, pausers);

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.InvalidTempAdmin.selector, admin));
        vm.prank(admin);
        merchant.reinitializeV3(admin, TEMP_ADMIN_B, managers, operators, pausers);

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.InvalidTempAdmin.selector, admin));
        vm.prank(admin);
        merchant.reinitializeV3(TEMP_ADMIN_A, admin, managers, operators, pausers);

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.InvalidTempAdmin.selector, secondAdmin));
        vm.prank(admin);
        merchant.reinitializeV3(secondAdmin, TEMP_ADMIN_B, managers, operators, pausers);

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.InvalidTempAdmin.selector, secondAdmin));
        vm.prank(admin);
        merchant.reinitializeV3(TEMP_ADMIN_A, secondAdmin, managers, operators, pausers);

        // A rejected attempt must leave the migration still runnable.
        _reinitializeV3AsAdmin();
        assertEq(merchant.getRoleMemberCount(adminRole), 1, "admin not back-filled");
        assertTrue(merchant.hasRole(adminRole, secondAdmin), "co-admin must keep its role");
    }

    function test_reinitializeV3_cannotRevokeEnumeratedCoAdmin() public {
        // Upgrade without the bundled call, then grant a co-admin through the enumerable
        // implementation: the co-admin is enumerated while the original admin is not. Passing the
        // co-admin as a stand-in used to make its grant a no-op and its revoke real, letting the
        // migration pass its exit assertion with the co-admin removed.
        _simulateNonEnumerableProxy();
        address coAdmin = address(0xA11CE2);
        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        merchant.grantRole(adminRole, coAdmin);
        assertEq(merchant.getRoleMemberCount(adminRole), 1, "co-admin should be enumerated");

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.InvalidTempAdmin.selector, coAdmin));
        vm.prank(admin);
        merchant.reinitializeV3(coAdmin, TEMP_ADMIN_B, _members(admin), _members(operator), _members(admin));

        vm.expectRevert(abi.encodeWithSelector(IConcreteMerchant.InvalidTempAdmin.selector, coAdmin));
        vm.prank(admin);
        merchant.reinitializeV3(TEMP_ADMIN_A, coAdmin, _members(admin), _members(operator), _members(admin));

        assertTrue(merchant.hasRole(adminRole, coAdmin), "co-admin must keep its role");
    }

    function test_reinitializeV3_cannotDetectOmittedCoAdmin() public {
        // Documents the residual limitation: the caller is the only admin the migration enumerates,
        // so a co-admin keeps its role while staying unenumerated and the exit assertion cannot see
        // the difference. `reinitializer(3)` is one-shot, so there is no second chance to repair it.
        address secondAdmin = address(0xA11CE2);
        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        merchant.grantRole(adminRole, secondAdmin);
        _simulateNonEnumerableProxy();
        _clearEnumerableRoleMembers(adminRole, _members(secondAdmin));

        _reinitializeV3AsAdmin();

        assertEq(merchant.getRoleMemberCount(adminRole), 1, "only the caller should be enumerated");
        assertTrue(merchant.hasRole(adminRole, secondAdmin), "omitted admin must keep its role");
    }

    function test_reinitializeV3_toleratesDuplicateEntries() public {
        _simulateNonEnumerableProxy();

        bytes32 operatorRole = merchant.OPERATOR_ROLE();

        vm.prank(admin);
        merchant.reinitializeV3(
            TEMP_ADMIN_A, TEMP_ADMIN_B, _members(admin), _members(operator, operator), _members(admin)
        );

        assertEq(merchant.getRoleMemberCount(operatorRole), 1, "duplicate entry double-counted");
    }

    function test_reinitializeV3_allowsEmptyListForUnusedRole() public {
        _simulateNonEnumerableProxy();

        bytes32 pauserRole = merchant.PAUSER_ROLE();

        // Pausers deliberately omitted: the role keeps its holder, it just stays unenumerated.
        vm.prank(admin);
        merchant.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(admin), _members(operator), _noMembers());

        assertEq(merchant.getRoleMemberCount(pauserRole), 0, "omitted role must stay unenumerated");
        assertTrue(merchant.hasRole(pauserRole, admin), "omitted role must keep its holder");
    }

    function test_reinitializeV3_revertsOnNonHolder() public {
        _simulateNonEnumerableProxy();

        // A single typo'd address must abort the whole upgrade: re-entering a non-holder would be
        // a real privilege grant rather than a bookkeeping repair.
        address stranger = address(0xBAD);
        bytes32 operatorRole = merchant.OPERATOR_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IConcreteMerchant.NotACurrentRoleHolder.selector, operatorRole, stranger)
        );
        vm.prank(admin);
        merchant.reinitializeV3(
            TEMP_ADMIN_A, TEMP_ADMIN_B, _members(admin), _members(operator, stranger), _members(admin)
        );

        assertFalse(merchant.hasRole(operatorRole, stranger), "typo must never grant a live role");
    }

    function test_reinitializeV3_revertsOnZeroAddressEntry() public {
        _simulateNonEnumerableProxy();

        bytes32 pauserRole = merchant.PAUSER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IConcreteMerchant.NotACurrentRoleHolder.selector, pauserRole, address(0))
        );
        vm.prank(admin);
        merchant.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(admin), _members(operator), _members(address(0)));
    }

    function test_reinitializeV3_revertsWhenNotAdmin() public {
        address stranger = address(0xDEAD);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        vm.prank(stranger);
        merchant.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(admin), _members(operator), _members(admin));

        // The failed call must not bump the initializable version — admin can still migrate.
        _reinitializeV3AsAdmin();
    }

    function test_reinitializeV3_revertsOnSecondCall() public {
        _reinitializeV3AsAdmin();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(admin);
        merchant.reinitializeV3(TEMP_ADMIN_A, TEMP_ADMIN_B, _members(admin), _members(operator), _members(admin));
    }

    function test_upgradeToAndCall_runsReinitializeV3Atomically() public {
        // ── Arrange: shape the proxy like a live non-enumerable deployment.
        _simulateNonEnumerableProxy();

        // ── Act: the implementation swap and the whole backfill land in one transaction, so the
        // admin is never unprivileged and the stand-in admins are never reachable from outside.
        ConcreteMerchant newImpl = new ConcreteMerchant();
        bytes memory migrateCalldata = abi.encodeCall(
            ConcreteMerchant.reinitializeV3,
            (TEMP_ADMIN_A, TEMP_ADMIN_B, _members(admin), _members(operator), _members(admin))
        );

        vm.expectEmit(true, true, false, true, address(merchant));
        emit IConcreteMerchant.MerchantUpgradeAuthorized(address(newImpl), admin);
        vm.expectEmit(true, false, false, false, address(merchant));
        emit IERC1967.Upgraded(address(newImpl));
        vm.expectEmit(true, false, false, true, address(merchant));
        emit IConcreteMerchant.RoleMembershipBackfilled(merchant.DEFAULT_ADMIN_ROLE(), 1);
        vm.expectEmit(false, false, false, true, address(merchant));
        emit Initializable.Initialized(3);

        vm.prank(admin);
        merchant.upgradeToAndCall(address(newImpl), migrateCalldata);

        // ── Assert: implementation swapped, membership seeded, admin intact.
        address implAfter = address(uint160(uint256(vm.load(address(merchant), ERC1967Utils.IMPLEMENTATION_SLOT))));
        assertEq(implAfter, address(newImpl), "implementation slot not switched");

        assertEq(merchant.getRoleMemberCount(merchant.DEFAULT_ADMIN_ROLE()), 1, "admin not back-filled");
        assertEq(merchant.getRoleMemberCount(merchant.OPERATOR_ROLE()), 1, "operator not back-filled");
        assertTrue(merchant.hasRole(merchant.DEFAULT_ADMIN_ROLE(), admin), "admin lost DEFAULT_ADMIN_ROLE");

        // The admin can still authorize a further upgrade — i.e. the proxy was never orphaned.
        ConcreteMerchant followUpImpl = new ConcreteMerchant();
        vm.prank(admin);
        merchant.upgradeToAndCall(address(followUpImpl), "");
    }

    /*//////////////////////////////////////////////////////////////
                        LAST-ADMIN GUARD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_revokeRole_failsClosedWhenMembershipUnknown() public {
        // The dangerous case. On a proxy upgraded from a non-enumerable implementation the
        // tracked count is 0 while `hasRole` still reports the admin, so a naive `count == 1`
        // check would wave through removal of the genuinely last admin and brick upgrades.
        _simulateNonEnumerableProxy();

        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();
        assertEq(merchant.getRoleMemberCount(adminRole), 0, "precondition: membership must be unknown");
        assertTrue(merchant.hasRole(adminRole, admin), "precondition: admin must still hold the role");

        vm.expectRevert(IConcreteMerchant.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        merchant.revokeRole(adminRole, admin);

        assertTrue(merchant.hasRole(adminRole, admin), "admin must survive a fail-closed revoke");
    }

    function test_revokeRole_revertsOnLastAdmin() public {
        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();
        assertEq(merchant.getRoleMemberCount(adminRole), 1, "precondition: fixture has one admin");

        vm.expectRevert(IConcreteMerchant.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        merchant.revokeRole(adminRole, admin);
    }

    function test_renounceRole_revertsOnLastAdmin() public {
        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();
        assertEq(merchant.getRoleMemberCount(adminRole), 1, "precondition: fixture has one admin");

        vm.expectRevert(IConcreteMerchant.CannotRemoveLastRoleAdmin.selector);
        vm.prank(admin);
        merchant.renounceRole(adminRole, admin);
    }

    function test_revokeRole_succeedsOnceASecondAdminExists() public {
        bytes32 adminRole = merchant.DEFAULT_ADMIN_ROLE();
        address secondAdmin = address(0xA2);

        vm.prank(admin);
        merchant.grantRole(adminRole, secondAdmin);
        assertEq(merchant.getRoleMemberCount(adminRole), 2, "second admin not enumerated");

        // Rotation is now safe in either direction: the outgoing admin can be removed by the
        // incoming one without ever passing through a zero-admin state.
        vm.prank(secondAdmin);
        merchant.revokeRole(adminRole, admin);

        assertFalse(merchant.hasRole(adminRole, admin), "outgoing admin not removed");
        assertEq(merchant.getRoleMemberCount(adminRole), 1, "membership set not updated on revoke");
        assertEq(merchant.getRoleMember(adminRole, 0), secondAdmin, "wrong surviving admin");
    }

    function test_revokeRole_leavesNonAdminRolesUnguarded() public {
        // The guard is scoped to `DEFAULT_ADMIN_ROLE`; operational roles can still be emptied.
        bytes32 operatorRole = merchant.OPERATOR_ROLE();

        vm.prank(admin);
        merchant.revokeRole(operatorRole, operator);

        assertFalse(merchant.hasRole(operatorRole, operator), "operator not revoked");
        assertEq(merchant.getRoleMemberCount(operatorRole), 0, "membership set not updated on revoke");
    }

    function test_renounceRole_leavesNonAdminRolesUnguarded() public {
        bytes32 pauserRole = merchant.PAUSER_ROLE();

        vm.prank(admin);
        merchant.renounceRole(pauserRole, admin);

        assertFalse(merchant.hasRole(pauserRole, admin), "pauser not renounced");
        assertEq(merchant.getRoleMemberCount(pauserRole), 0, "membership set not updated on renounce");
    }

    function test_revokeRole_revertsWhenNotRoleAdmin() public {
        bytes32 operatorRole = merchant.OPERATOR_ROLE();
        bytes32 managerRole = merchant.MERCHANT_MANAGER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, managerRole)
        );
        vm.prank(user);
        merchant.revokeRole(operatorRole, operator);
    }

    function test_logStorageSlot() external pure {
        bytes32 computed = keccak256(abi.encode(uint256(keccak256("concrete.storage.ConcreteMerchant")) - 1))
            & ~bytes32(uint256(0xff));

        console2.log("ConcreteMerchantStorageLocation declared:");
        console2.logBytes32(ConcreteMerchantStorageLib.storageLocation());
        console2.log("ConcreteMerchantStorageLocation computed:");
        console2.logBytes32(computed);
    }
}

