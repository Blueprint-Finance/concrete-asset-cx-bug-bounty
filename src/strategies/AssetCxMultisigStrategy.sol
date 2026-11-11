// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {MultisigStrategy} from "@concrete-xyz/earn-v2-core/src/periphery/strategies/MultisigStrategy.sol";
import {
    MultisigStrategyStorageLib as MultisigStrategyStorage
} from "@concrete-xyz/earn-v2-core/src/periphery/lib/MultisigStrategyStorageLib.sol";
import {
    BaseStrategyStorageLib as BaseStrategyStorage
} from "@concrete-xyz/earn-v2-core/src/periphery/lib/BaseStrategyStorageLib.sol";
import {ConcreteMerchant} from "../merchant/ConcreteMerchant.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {AssetCxMultisigStrategyStorageLib} from "../lib/AssetCxMultisigStrategyStorageLib.sol";
import {ContractIdEncoding} from "@concrete-xyz/earn-v2-core/src/lib/ContractIdEncoding.sol";

/**
 * @title AssetCxMultisigStrategy
 * @notice Multisig strategy tailored for AssetCX that can directly report yield to the ConcreteMerchant
 */
contract AssetCxMultisigStrategy is MultisigStrategy {
    using SafeERC20 for IERC20;

    event MerchantUpdated(address indexed previousMerchant, address indexed newMerchant);
    /// @notice Emitted when this strategy initiates a yield accrual against the merchant.
    /// @param nonce      The merchant-assigned continuous nonce for the accrual.
    /// @param yieldToken The ERC-20 of the yield paid in this accrual.
    /// @param amount     The amount (in `yieldToken` units) routed through the merchant.
    /// @param caller     The admin/operator that submitted the accrual.
    event MerchantYieldAccrued(
        uint256 indexed nonce, address indexed yieldToken, uint256 amount, address indexed caller
    );
    /// @notice Emitted when the merchant calls back to finalize a previously initiated accrual.
    /// @param nonce         The accrual nonce being finalized.
    /// @param yieldToken    The yield token being finalized.
    /// @param pendingAmount Amount that was pending (in `yieldToken` units).
    /// @param amountInAsset Settled amount denominated in the vault's asset (assetCX).
    event MerchantYieldFinalized(
        uint256 indexed nonce, address indexed yieldToken, uint256 pendingAmount, uint256 amountInAsset
    );

    error InvalidMerchantAddress();
    error InvalidYieldAsset();
    error InvalidYieldAmount();
    error UnauthorizedMerchant(address caller);
    error UnknownYieldNonce(uint256 nonce);

    function FLAVOUR() public pure virtual override returns (uint256) {
        return 7; // AssetCx multisig strategy
    }

    function ID() public pure virtual override(MultisigStrategy) returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 7, 0);
    }

    /**
     * @dev Constructor that disables initializers
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the strategy and configures the merchant integration
     */
    function initialize(
        address admin,
        address vault_,
        address multiSig_,
        uint64 maxAccountingChangeThreshold_,
        uint64 accountingValidityPeriod_,
        uint64 cooldownPeriod_,
        address timelock_,
        address merchant_
    ) external initializer {
        __AssetCxMultisigStrategy_init(
            admin,
            vault_,
            multiSig_,
            maxAccountingChangeThreshold_,
            accountingValidityPeriod_,
            cooldownPeriod_,
            timelock_,
            merchant_
        );
    }

    /**
     * @notice Returns the configured ConcreteMerchant address
     */
    function getMerchant() external view returns (address) {
        return address(AssetCxMultisigStrategyStorageLib.fetch().merchant);
    }

    function getPendingMerchantYield(uint256 nonce) external view returns (uint256) {
        return AssetCxMultisigStrategyStorageLib.fetch().pendingYieldByNonce[nonce];
    }

    /// @notice Returns the total outstanding pending yield denominated in `token`.
    function totalPendingYield(address token) external view returns (uint256) {
        return AssetCxMultisigStrategyStorageLib.fetch().totalPendingYieldByToken[token];
    }

    /**
     * @notice Returns the vault address this strategy is associated with
     */
    function getVault() external view override returns (address) {
        BaseStrategyStorage.BaseStrategyStorage storage baseStrategyStorage = BaseStrategyStorage.fetch();
        return baseStrategyStorage.vault;
    }

    /**
     * @notice Initiates a yield accrual cycle with the ConcreteMerchant contract.
     * @dev Pulls `amountInYieldToken` of the caller-selected `yieldToken` from the
     *      strategy multisig, forwards it to the merchant.
     *
     * @param yieldToken         The ERC-20 paid as yield. Must be whitelisted by the merchant.
     * @param amountInYieldToken The amount measured in `yieldToken`.
     * @param nonce              The merchant nonce that uniquely identifies the accrual.
     */
    function initiateMerchantYieldAccrual(IERC20 yieldToken, uint256 amountInYieldToken, uint256 nonce)
        external
        whenNotPaused
        onlyAdminOrOperator
    {
        if (amountInYieldToken == 0) revert InvalidYieldAmount();
        if (address(yieldToken) == address(0)) revert InvalidYieldAsset();

        AssetCxMultisigStrategyStorageLib.Storage storage $ = AssetCxMultisigStrategyStorageLib.fetch();
        ConcreteMerchant merchant_ = $.merchant;

        BaseStrategyStorage.BaseStrategyStorage storage baseStrategyStorage = BaseStrategyStorage.fetch();
        address vault = baseStrategyStorage.vault;

        $.pendingYieldByNonce[nonce] = amountInYieldToken;
        $.totalPendingYieldByToken[address(yieldToken)] += amountInYieldToken;

        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();
        address multiSig = multisigStrategyStorage.multiSig;
        yieldToken.safeTransferFrom(multiSig, address(this), amountInYieldToken);

        yieldToken.forceApprove(address(merchant_), amountInYieldToken);
        merchant_.initiateYieldAccrual(vault, address(yieldToken), amountInYieldToken, nonce);
        yieldToken.forceApprove(address(merchant_), 0);

        emit MerchantYieldAccrued(nonce, address(yieldToken), amountInYieldToken, msg.sender);
    }

    /**
     * @notice Finalizes a previously initiated merchant yield accrual.
     * @param nonce         The accounting nonce used during initiation
     * @param amountInAsset The amount of asset tokens being finalized
     * @param yieldToken    The ERC-20 originally accrued for `nonce`, replayed from
     *                      the merchant's per-nonce record.
     */
    function finalizeMerchantYieldAccrual(uint256 nonce, uint256 amountInAsset, address yieldToken)
        external
        whenNotPaused
    {
        if (amountInAsset == 0) revert InvalidYieldAmount();

        AssetCxMultisigStrategyStorageLib.Storage storage $ = AssetCxMultisigStrategyStorageLib.fetch();
        if (msg.sender != address($.merchant)) {
            revert UnauthorizedMerchant(msg.sender);
        }

        uint256 pendingAmount = $.pendingYieldByNonce[nonce];
        if (pendingAmount == 0) {
            revert UnknownYieldNonce(nonce);
        }
        $.pendingYieldByNonce[nonce] = 0;
        $.totalPendingYieldByToken[yieldToken] -= pendingAmount;

        BaseStrategyStorage.BaseStrategyStorage storage baseStrategyStorage = BaseStrategyStorage.fetch();
        IERC20 assetToken = IERC20(baseStrategyStorage.asset);

        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();
        address multiSig = multisigStrategyStorage.multiSig;

        assetToken.safeTransferFrom(msg.sender, multiSig, amountInAsset);

        emit MerchantYieldFinalized(nonce, yieldToken, pendingAmount, amountInAsset);
    }

    function _setMerchant(address merchant_) internal {
        if (merchant_ == address(0)) revert InvalidMerchantAddress();
        AssetCxMultisigStrategyStorageLib.Storage storage $ = AssetCxMultisigStrategyStorageLib.fetch();
        address previous = address($.merchant);
        $.merchant = ConcreteMerchant(merchant_);
        emit MerchantUpdated(previous, merchant_);
    }

    function __AssetCxMultisigStrategy_init(
        address admin,
        address vault_,
        address multiSig_,
        uint64 maxAccountingChangeThreshold_,
        uint64 accountingValidityPeriod_,
        uint64 cooldownPeriod_,
        address timelock_,
        address merchant_
    ) internal onlyInitializing {
        __MultisigStrategy_init(
            admin,
            vault_,
            multiSig_,
            maxAccountingChangeThreshold_,
            accountingValidityPeriod_,
            cooldownPeriod_,
            timelock_
        );

        _setMerchant(merchant_);
    }
}

