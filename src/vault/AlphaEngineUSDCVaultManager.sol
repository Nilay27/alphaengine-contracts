// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAlphaEngineFundVault} from "../interfaces/IAlphaEngineFundVault.sol";

/// @notice Immediate USDC deposits, asynchronous redemptions, and daily P&L accounting.
contract AlphaEngineUSDCVaultManager is Ownable2Step, Pausable, ReentrancyGuard {
    uint256 public constant SHARE_SCALE = 1e12;
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 2000;
    uint16 public constant BPS = 10_000;

    enum RedemptionStatus {
        None,
        Pending,
        Completed,
        Cancelled
    }

    struct RedemptionRequest {
        address owner;
        address receiver;
        uint256 shares;
        uint256 minAssets;
        RedemptionStatus status;
    }

    IERC20 public immutable USDC;
    IAlphaEngineFundVault public immutable FUND_VAULT;

    address public navReporter;
    address public feeRecipient;

    uint256 public managedAssets;
    uint256 public lockedProfit;
    uint256 public lockedRecoveryProfit;
    uint256 public pendingFeeAssets;
    uint256 public lossToRecover;

    uint64 public profitLockTimestamp;
    uint64 public profitUnlockTimestamp;
    uint64 public vestingPeriod;
    uint64 public reportEpoch;
    uint64 public lastReferenceBlock;
    uint64 public nextRedemptionId;
    uint16 public performanceFeeBps;
    uint16 public pendingFeeBps;

    mapping(uint64 requestId => RedemptionRequest request) private _redemptions;

    error ZeroAddress();
    error InvalidContract(address account);
    error InvalidFundVaultAsset(address expected, address actual);
    error InvalidPerformanceFee(uint16 feeBps);
    error InvalidVestingPeriod(uint64 period);
    error UnauthorizedNAVReporter(address caller);
    error ZeroAssets();
    error ZeroShares();
    error ZeroReportHash();
    error InsufficientShares(uint256 shares, uint256 minimum);
    error InsufficientAssets(uint256 assets, uint256 minimum);
    error InsolventVault();
    error ProfitStillVesting(uint256 remainingProfit);
    error ActiveFeePending(uint256 feeAssets);
    error InvalidReportEpoch(uint64 expected, uint64 actual);
    error InvalidReferenceBlock(uint64 previousBlock, uint64 suppliedBlock);
    error FutureReferenceBlock(uint64 suppliedBlock, uint256 currentBlock);
    error LossExceedsManagedAssets(uint256 loss, uint256 managedAssets);
    error RedemptionNotFound(uint64 requestId);
    error InvalidRedemptionStatus(uint64 requestId, RedemptionStatus status);
    error UnauthorizedRedemptionOwner(address caller, address owner);
    error InsufficientVaultLiquidity(uint256 available, uint256 required);
    error FinalRedemptionWhileProfitLocked(uint256 remainingProfit);

    event NAVReporterUpdated(address indexed oldReporter, address indexed newReporter);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event PerformanceFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event VestingPeriodUpdated(uint64 oldPeriod, uint64 newPeriod);
    event Deposit(address indexed payer, address indexed receiver, uint256 assets, uint256 shares);
    event RedemptionRequested(
        uint64 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 minAssets
    );
    event RedemptionCancelled(uint64 indexed requestId, address indexed owner, uint256 shares);
    event RedemptionCompleted(
        uint64 indexed requestId, address indexed receiver, uint256 shares, uint256 assets
    );
    event ProfitReported(
        uint64 indexed epoch,
        uint64 indexed referenceBlock,
        uint256 profit,
        uint256 recoveryProfit,
        uint256 pendingFeeAssets,
        bytes32 reportHash
    );
    event LossReported(
        uint64 indexed epoch,
        uint64 indexed referenceBlock,
        uint256 loss,
        uint256 cancelledLockedProfit,
        bytes32 reportHash
    );
    event PerformanceFeeMinted(address indexed recipient, uint256 feeAssets, uint256 shares);

    modifier onlyNavReporter() {
        _checkNavReporter();
        _;
    }

    function _checkNavReporter() private view {
        if (msg.sender != navReporter) revert UnauthorizedNAVReporter(msg.sender);
    }

    constructor(
        address owner_,
        IERC20 usdc_,
        IAlphaEngineFundVault fundVault_,
        address navReporter_,
        address feeRecipient_,
        uint64 vestingPeriod_,
        uint16 performanceFeeBps_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) || address(usdc_) == address(0)
                || address(fundVault_) == address(0) || navReporter_ == address(0)
                || feeRecipient_ == address(0)
        ) revert ZeroAddress();
        if (address(usdc_).code.length == 0) revert InvalidContract(address(usdc_));
        if (address(fundVault_).code.length == 0) revert InvalidContract(address(fundVault_));

        address vaultAsset = fundVault_.usdc();
        if (vaultAsset != address(usdc_)) {
            revert InvalidFundVaultAsset(address(usdc_), vaultAsset);
        }
        if (vestingPeriod_ == 0) revert InvalidVestingPeriod(vestingPeriod_);
        if (performanceFeeBps_ > MAX_PERFORMANCE_FEE_BPS) {
            revert InvalidPerformanceFee(performanceFeeBps_);
        }

        USDC = usdc_;
        FUND_VAULT = fundVault_;
        navReporter = navReporter_;
        feeRecipient = feeRecipient_;
        vestingPeriod = vestingPeriod_;
        performanceFeeBps = performanceFeeBps_;
        nextRedemptionId = 1;
        _pause();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setNavReporter(address newReporter) external onlyOwner {
        if (newReporter == address(0)) revert ZeroAddress();
        address oldReporter = navReporter;
        navReporter = newReporter;
        emit NAVReporterUpdated(oldReporter, newReporter);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        if (pendingFeeAssets != 0) revert ActiveFeePending(pendingFeeAssets);
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    function setPerformanceFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PERFORMANCE_FEE_BPS) {
            revert InvalidPerformanceFee(newFeeBps);
        }
        uint16 oldFeeBps = performanceFeeBps;
        performanceFeeBps = newFeeBps;
        emit PerformanceFeeUpdated(oldFeeBps, newFeeBps);
    }

    function setVestingPeriod(uint64 newPeriod) external onlyOwner {
        if (newPeriod == 0) revert InvalidVestingPeriod(newPeriod);
        uint256 remainingProfit = remainingLockedProfit();
        if (remainingProfit != 0) revert ProfitStillVesting(remainingProfit);
        _settleFinishedProfit();

        uint64 oldPeriod = vestingPeriod;
        vestingPeriod = newPeriod;
        emit VestingPeriodUpdated(oldPeriod, newPeriod);
    }

    function deposit(uint256 assets, address receiver, uint256 minShares)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAssets();
        if (receiver == address(0)) revert ZeroAddress();

        _settleFinishedProfit();
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert InsufficientShares(shares, minShares);

        managedAssets += assets;
        FUND_VAULT.settleDeposit(msg.sender, receiver, assets, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function requestRedeem(uint256 shares, address receiver, uint256 minAssets)
        external
        whenNotPaused
        nonReentrant
        returns (uint64 requestId)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        requestId = nextRedemptionId;
        nextRedemptionId = requestId + 1;
        _redemptions[requestId] = RedemptionRequest({
            owner: msg.sender,
            receiver: receiver,
            shares: shares,
            minAssets: minAssets,
            status: RedemptionStatus.Pending
        });

        FUND_VAULT.lockRedemptionShares(msg.sender, shares);
        emit RedemptionRequested(requestId, msg.sender, receiver, shares, minAssets);
    }

    function cancelRedeem(uint64 requestId) external nonReentrant {
        RedemptionRequest storage request = _redemption(requestId);
        if (request.status != RedemptionStatus.Pending) {
            revert InvalidRedemptionStatus(requestId, request.status);
        }
        if (msg.sender != request.owner) {
            revert UnauthorizedRedemptionOwner(msg.sender, request.owner);
        }

        request.status = RedemptionStatus.Cancelled;
        FUND_VAULT.releaseRedemptionShares(request.owner, request.shares);
        emit RedemptionCancelled(requestId, request.owner, request.shares);
    }

    function completeRedeem(uint64 requestId) external nonReentrant returns (uint256 assets) {
        RedemptionRequest storage request = _redemption(requestId);
        if (request.status != RedemptionStatus.Pending) {
            revert InvalidRedemptionStatus(requestId, request.status);
        }

        _settleFinishedProfit();
        uint256 remainingProfit = remainingLockedProfit();
        if (request.shares == FUND_VAULT.totalSupply() && remainingProfit != 0) {
            revert FinalRedemptionWhileProfitLocked(remainingProfit);
        }
        assets = previewRedeem(request.shares);
        if (assets < request.minAssets) {
            revert InsufficientAssets(assets, request.minAssets);
        }

        uint256 available = USDC.balanceOf(address(FUND_VAULT));
        if (available < assets) revert InsufficientVaultLiquidity(available, assets);

        uint256 supplyBefore = FUND_VAULT.totalSupply();
        request.status = RedemptionStatus.Completed;
        managedAssets -= assets;
        if (lossToRecover != 0) {
            uint256 remainingSupply = supplyBefore - request.shares;
            lossToRecover = remainingSupply == 0
                ? 0
                : Math.mulDiv(lossToRecover, remainingSupply, supplyBefore, Math.Rounding.Ceil);
        }
        FUND_VAULT.settleRedemption(request.receiver, request.shares, assets);
        emit RedemptionCompleted(requestId, request.receiver, request.shares, assets);
    }

    function reportProfit(
        uint64 expectedEpoch,
        uint64 referenceBlock,
        uint256 profit,
        bytes32 reportHash
    ) external onlyNavReporter whenNotPaused nonReentrant {
        if (profit == 0) revert ZeroAssets();
        if (FUND_VAULT.totalSupply() == 0) revert ZeroShares();
        _validateReport(expectedEpoch, referenceBlock, reportHash);
        _settleFinishedProfit();

        uint256 remainingProfit = remainingLockedProfit();
        if (remainingProfit != 0) revert ProfitStillVesting(remainingProfit);

        uint256 recoveryProfit = Math.min(profit, lossToRecover);
        lossToRecover -= recoveryProfit;
        uint256 feeableProfit = profit - recoveryProfit;

        managedAssets += profit;
        lockedProfit = profit;
        lockedRecoveryProfit = recoveryProfit;
        pendingFeeAssets = Math.mulDiv(feeableProfit, performanceFeeBps, BPS);
        pendingFeeBps = performanceFeeBps;
        profitLockTimestamp = uint64(block.timestamp);
        profitUnlockTimestamp = uint64(block.timestamp) + vestingPeriod;

        _recordReport(expectedEpoch, referenceBlock);
        emit ProfitReported(
            expectedEpoch, referenceBlock, profit, recoveryProfit, pendingFeeAssets, reportHash
        );
    }

    function reportLoss(
        uint64 expectedEpoch,
        uint64 referenceBlock,
        uint256 loss,
        bytes32 reportHash
    ) external onlyNavReporter whenNotPaused nonReentrant {
        if (loss == 0) revert ZeroAssets();
        if (loss > managedAssets) revert LossExceedsManagedAssets(loss, managedAssets);
        _validateReport(expectedEpoch, referenceBlock, reportHash);
        _settleFinishedProfit();

        uint256 remainingProfit = remainingLockedProfit();
        uint256 remainingRecovery = remainingLockedRecoveryProfit();
        uint256 remainingFeeable = remainingProfit - remainingRecovery;
        uint256 cancelledProfit = Math.min(loss, remainingProfit);
        uint256 cancelledFeeable = Math.min(cancelledProfit, remainingFeeable);
        uint256 cancelledRecovery = cancelledProfit - cancelledFeeable;

        uint256 feeReduction = Math.mulDiv(cancelledFeeable, pendingFeeBps, BPS, Math.Rounding.Ceil);
        pendingFeeAssets -= Math.min(pendingFeeAssets, feeReduction);

        uint256 newRecovery = remainingRecovery - cancelledRecovery;
        uint256 newLockedProfit = remainingProfit - cancelledProfit;
        lockedProfit = newLockedProfit;
        lockedRecoveryProfit = newRecovery;
        lossToRecover += cancelledRecovery + (loss - cancelledProfit);
        managedAssets -= loss;

        if (newLockedProfit == 0) {
            profitLockTimestamp = 0;
            profitUnlockTimestamp = 0;
            pendingFeeAssets = 0;
            pendingFeeBps = 0;
        } else {
            profitLockTimestamp = uint64(block.timestamp);
        }

        _recordReport(expectedEpoch, referenceBlock);
        emit LossReported(expectedEpoch, referenceBlock, loss, cancelledProfit, reportHash);
    }

    function settleFinishedProfit() external nonReentrant returns (uint256 feeShares) {
        feeShares = _settleFinishedProfit();
    }

    function previewDeposit(uint256 assets) public view returns (uint256 shares) {
        uint256 supply = _supplyAfterFinishedFee();
        if (supply == 0) return assets * SHARE_SCALE;

        uint256 assetsForShares = availableAssets();
        if (assetsForShares == 0) revert InsolventVault();
        shares = Math.mulDiv(assets, supply, assetsForShares);
    }

    function previewRedeem(uint256 shares) public view returns (uint256 assets) {
        uint256 supply = _supplyAfterFinishedFee();
        if (supply == 0) return 0;
        assets = Math.mulDiv(shares, availableAssets(), supply);
    }

    function availableAssets() public view returns (uint256) {
        return managedAssets - remainingLockedProfit();
    }

    function remainingLockedProfit() public view returns (uint256) {
        return _remainingAmount(lockedProfit);
    }

    function remainingLockedRecoveryProfit() public view returns (uint256) {
        uint256 remainingProfit = remainingLockedProfit();
        if (remainingProfit == 0 || lockedRecoveryProfit == 0) return 0;

        uint256 remainingRecovery =
            Math.mulDiv(lockedRecoveryProfit, remainingProfit, lockedProfit, Math.Rounding.Ceil);
        return Math.min(remainingRecovery, remainingProfit);
    }

    function getRedemption(uint64 requestId)
        external
        view
        returns (RedemptionRequest memory request)
    {
        request = _redemption(requestId);
    }

    function _remainingAmount(uint256 amount) private view returns (uint256) {
        if (amount == 0 || block.timestamp >= profitUnlockTimestamp) return 0;
        if (block.timestamp <= profitLockTimestamp) return amount;

        uint256 remainingTime = profitUnlockTimestamp - uint64(block.timestamp);
        uint256 lockDuration = profitUnlockTimestamp - profitLockTimestamp;
        return Math.mulDiv(amount, remainingTime, lockDuration);
    }

    function _settleFinishedProfit() private returns (uint256 feeShares) {
        if (lockedProfit == 0 || remainingLockedProfit() != 0) return 0;

        uint256 feeAssets = pendingFeeAssets;
        lockedProfit = 0;
        lockedRecoveryProfit = 0;
        pendingFeeAssets = 0;
        pendingFeeBps = 0;
        profitLockTimestamp = 0;
        profitUnlockTimestamp = 0;

        if (feeAssets == 0) return 0;
        feeShares = _feeShares(feeAssets, FUND_VAULT.totalSupply());
        if (feeShares == 0) return 0;

        FUND_VAULT.mintFeeShares(feeRecipient, feeShares);
        emit PerformanceFeeMinted(feeRecipient, feeAssets, feeShares);
    }

    function _supplyAfterFinishedFee() private view returns (uint256 supply) {
        supply = FUND_VAULT.totalSupply();
        if (lockedProfit == 0 || remainingLockedProfit() != 0 || pendingFeeAssets == 0) {
            return supply;
        }
        return supply + _feeShares(pendingFeeAssets, supply);
    }

    function _feeShares(uint256 feeAssets, uint256 supply) private view returns (uint256) {
        if (feeAssets == 0 || supply == 0) return 0;
        if (managedAssets <= feeAssets) return 0;
        return Math.mulDiv(feeAssets, supply, managedAssets - feeAssets);
    }

    function _validateReport(uint64 expectedEpoch, uint64 referenceBlock, bytes32 reportHash)
        private
        view
    {
        uint64 requiredEpoch = reportEpoch + 1;
        if (expectedEpoch != requiredEpoch) {
            revert InvalidReportEpoch(requiredEpoch, expectedEpoch);
        }
        if (referenceBlock <= lastReferenceBlock) {
            revert InvalidReferenceBlock(lastReferenceBlock, referenceBlock);
        }
        if (referenceBlock >= block.number) {
            revert FutureReferenceBlock(referenceBlock, block.number);
        }
        if (reportHash == bytes32(0)) revert ZeroReportHash();
    }

    function _recordReport(uint64 epoch, uint64 referenceBlock) private {
        reportEpoch = epoch;
        lastReferenceBlock = referenceBlock;
    }

    function _redemption(uint64 requestId)
        private
        view
        returns (RedemptionRequest storage request)
    {
        request = _redemptions[requestId];
        if (request.status == RedemptionStatus.None) revert RedemptionNotFound(requestId);
    }
}
