// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {AlphaEngineUSDCVaultManager} from "src/vault/AlphaEngineUSDCVaultManager.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract USDCVaultInvariantHandler is Test {
    uint256 public constant ACTOR_COUNT = 3;
    uint256 private constant MAX_ACTION_ASSETS = 1_000_000e6;

    MockERC20 public immutable USDC;
    AlphaEngineFundVault public immutable FUND_VAULT;
    AlphaEngineUSDCVaultManager public immutable MANAGER;
    address public immutable FEE_RECIPIENT;
    address public immutable STRATEGY;

    address[ACTOR_COUNT] private _actors;
    uint64[] private _requestIds;

    uint256 public ghostManagedAssets;
    uint256 public ghostDepositedUsdc;
    uint256 public ghostRedeemedUsdc;
    uint256 public ghostDonations;
    uint256 public ghostDeployedUsdc;
    uint256 public ghostCompletedRedemptionAssets;
    uint256 public ghostReportedProfit;
    uint256 public ghostReportedLoss;
    uint256 public ghostShareSupply;
    uint256 public ghostLockedProfit;
    uint256 public ghostLockedRecoveryProfit;
    uint256 public ghostPendingFeeAssets;
    uint256 public ghostLossToRecover;
    uint64 public ghostProfitLockTimestamp;
    uint64 public ghostProfitUnlockTimestamp;
    uint16 public ghostPendingFeeBps;

    uint256 public successfulDeposits;
    uint256 public successfulRequests;
    uint256 public successfulCancellations;
    uint256 public successfulCompletions;
    uint256 public successfulProfitReports;
    uint256 public successfulLossReports;
    uint256 public successfulFeeSettlements;
    uint256 public expectedIlliquidCompletions;

    bool public depositPriceViolation;
    bool public redemptionPriceViolation;
    bool public feeOverchargeViolation;
    bool public feeExactnessViolation;
    bool public feeSettlementPriceViolation;
    bool public failedCompletionMutation;
    bool public lossRecoveryFlowViolation;
    bool public accountingModelViolation;

    constructor(
        MockERC20 usdc,
        AlphaEngineFundVault fundVault,
        AlphaEngineUSDCVaultManager manager,
        address feeRecipient,
        address strategy
    ) {
        USDC = usdc;
        FUND_VAULT = fundVault;
        MANAGER = manager;
        FEE_RECIPIENT = feeRecipient;
        STRATEGY = strategy;

        for (uint256 index = 0; index < ACTOR_COUNT; ++index) {
            address actor = address(uint160(uint256(keccak256(abi.encode("vault actor", index)))));
            _actors[index] = actor;
            vm.prank(actor);
            USDC.approve(address(FUND_VAULT), type(uint256).max);
            vm.prank(actor);
            FUND_VAULT.approve(address(MANAGER), type(uint256).max);
        }
    }

    function deposit(uint256 actorSeed, uint96 rawAssets) public {
        address actor = actorAt(actorSeed);
        uint256 assets = bound(uint256(rawAssets), 1, MAX_ACTION_ASSETS);
        _settleFinishedProfit();
        uint256 lossToRecoverBefore = MANAGER.lossToRecover();
        uint256 supplyBefore = FUND_VAULT.totalSupply();
        uint256 assetsBefore = MANAGER.availableAssets();
        if (supplyBefore != 0 && assetsBefore == 0) return;
        uint256 expectedShares = modelPreviewDeposit(assets);

        USDC.mint(actor, assets);
        vm.prank(actor);
        uint256 shares = MANAGER.deposit(assets, actor, 0);
        if (shares != expectedShares) accountingModelViolation = true;

        ghostManagedAssets += assets;
        ghostDepositedUsdc += assets;
        ghostShareSupply += expectedShares;
        successfulDeposits += 1;
        if (MANAGER.lossToRecover() != lossToRecoverBefore) lossRecoveryFlowViolation = true;

        if (supplyBefore != 0) {
            uint256 left = MANAGER.availableAssets() * supplyBefore;
            uint256 right = assetsBefore * FUND_VAULT.totalSupply();
            if (left < right || left - right >= assetsBefore) depositPriceViolation = true;
        }
        _checkModelParity();
    }

    function requestRedeem(uint256 actorSeed, uint96 rawShares) public {
        address actor = actorAt(actorSeed);
        uint256 balance = FUND_VAULT.balanceOf(actor);
        if (balance == 0) return;

        uint256 shares = bound(uint256(rawShares), 1, balance);
        vm.prank(actor);
        uint64 requestId = MANAGER.requestRedeem(shares, actor, 0);
        _requestIds.push(requestId);
        successfulRequests += 1;
        _checkModelParity();
    }

    function cancelRedeem(uint256 requestSeed) public {
        (uint64 requestId, bool found) = _pendingRequest(requestSeed);
        if (!found) return;
        AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
            MANAGER.getRedemption(requestId);

        vm.prank(request.owner);
        MANAGER.cancelRedeem(requestId);
        successfulCancellations += 1;
        _checkModelParity();
    }

    function completeRedeem(uint256 requestSeed) public {
        (uint64 requestId, bool found) = _pendingRequest(requestSeed);
        if (!found) return;
        _settleFinishedProfit();
        AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
            MANAGER.getRedemption(requestId);

        uint256 remainingProfit = modelRemainingLockedProfit();
        if (request.shares == FUND_VAULT.totalSupply() && remainingProfit != 0) return;

        uint256 assets = modelPreviewRedeem(request.shares);
        if (MANAGER.previewRedeem(request.shares) != assets) accountingModelViolation = true;
        if (USDC.balanceOf(address(FUND_VAULT)) < assets) return;

        uint256 assetsBefore = MANAGER.availableAssets();
        uint256 supplyBefore = FUND_VAULT.totalSupply();
        uint256 lossToRecoverBefore = ghostLossToRecover;
        uint256 completedAssets = MANAGER.completeRedeem(requestId);
        if (completedAssets != assets) accountingModelViolation = true;

        ghostManagedAssets -= assets;
        ghostRedeemedUsdc += assets;
        ghostCompletedRedemptionAssets += assets;
        ghostShareSupply -= request.shares;
        successfulCompletions += 1;

        uint256 supplyAfter = FUND_VAULT.totalSupply();
        uint256 expectedLossToRecover = supplyAfter == 0
            ? 0
            : Math.mulDiv(lossToRecoverBefore, supplyAfter, supplyBefore, Math.Rounding.Ceil);
        if (MANAGER.lossToRecover() != expectedLossToRecover) {
            lossRecoveryFlowViolation = true;
        }
        ghostLossToRecover = expectedLossToRecover;
        if (supplyAfter != 0) {
            uint256 left = MANAGER.availableAssets() * supplyBefore;
            uint256 right = assetsBefore * supplyAfter;
            if (left < right || left - right >= supplyBefore) redemptionPriceViolation = true;
        }
        _checkModelParity();
    }

    function attemptIlliquidCompletion(uint256 requestSeed) public {
        (uint64 requestId, bool found) = _pendingRequest(requestSeed);
        if (!found) return;
        AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
            MANAGER.getRedemption(requestId);
        uint256 remainingProfit = modelRemainingLockedProfit();
        if (request.shares == FUND_VAULT.totalSupply() && remainingProfit != 0) return;

        uint256 assets = modelPreviewRedeem(request.shares);
        if (MANAGER.previewRedeem(request.shares) != assets) accountingModelViolation = true;
        uint256 available = USDC.balanceOf(address(FUND_VAULT));
        if (assets == 0 || available >= assets) return;

        uint256 managedBefore = MANAGER.managedAssets();
        uint256 supplyBefore = FUND_VAULT.totalSupply();
        uint256 escrowBefore = FUND_VAULT.balanceOf(address(FUND_VAULT));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientVaultLiquidity.selector, available, assets
            )
        );
        MANAGER.completeRedeem(requestId);

        if (
            MANAGER.managedAssets() != managedBefore || FUND_VAULT.totalSupply() != supplyBefore
                || FUND_VAULT.balanceOf(address(FUND_VAULT)) != escrowBefore
        ) failedCompletionMutation = true;
        expectedIlliquidCompletions += 1;
        _checkModelParity();
    }

    function reportProfit(uint96 rawProfit) public {
        _settleFinishedProfit();
        if (ghostShareSupply == 0 || modelRemainingLockedProfit() != 0) return;
        uint256 profit = bound(uint256(rawProfit), 1, MAX_ACTION_ASSETS);
        (uint64 epoch, uint64 referenceBlock) = _nextReport();
        uint256 availableBefore = modelAvailableAssets();
        uint256 recoveryProfit = Math.min(profit, ghostLossToRecover);
        uint256 feeableProfit = profit - recoveryProfit;

        MANAGER.reportProfit(
            epoch, referenceBlock, profit, keccak256(abi.encode("invariant profit", epoch, profit))
        );
        ghostManagedAssets += profit;
        ghostReportedProfit += profit;
        ghostLossToRecover -= recoveryProfit;
        ghostLockedProfit = profit;
        ghostLockedRecoveryProfit = recoveryProfit;
        ghostPendingFeeBps = MANAGER.performanceFeeBps();
        ghostPendingFeeAssets = Math.mulDiv(feeableProfit, ghostPendingFeeBps, MANAGER.BPS());
        ghostProfitLockTimestamp = uint64(block.timestamp);
        ghostProfitUnlockTimestamp = uint64(block.timestamp) + MANAGER.vestingPeriod();
        successfulProfitReports += 1;
        if (modelAvailableAssets() != availableBefore) accountingModelViolation = true;
        _checkModelParity();
    }

    function reportLoss(uint96 rawLoss) public {
        _settleFinishedProfit();
        uint256 managed = ghostManagedAssets;
        if (managed == 0) return;
        uint256 loss = bound(uint256(rawLoss), 1, managed);
        (uint64 epoch, uint64 referenceBlock) = _nextReport();
        uint256 feeBalanceBefore = FUND_VAULT.balanceOf(FEE_RECIPIENT);
        uint256 supplyBefore = ghostShareSupply;

        MANAGER.reportLoss(
            epoch, referenceBlock, loss, keccak256(abi.encode("invariant loss", epoch, loss))
        );
        (uint256 feeAssets, uint256 expectedFeeShares) = _applyModelLoss(loss);
        ghostManagedAssets -= loss;
        ghostReportedLoss += loss;
        successfulLossReports += 1;
        uint256 receivedFeeShares = FUND_VAULT.balanceOf(FEE_RECIPIENT) - feeBalanceBefore;
        if (receivedFeeShares != expectedFeeShares) feeExactnessViolation = true;
        if (receivedFeeShares != 0 && MANAGER.previewRedeem(receivedFeeShares) > feeAssets) {
            feeOverchargeViolation = true;
        }
        if (ghostShareSupply != supplyBefore + expectedFeeShares) {
            accountingModelViolation = true;
        }
        if (expectedFeeShares != 0) successfulFeeSettlements += 1;
        _checkModelParity();
    }

    function advanceTime(uint32 rawSeconds) public {
        uint256 elapsed = bound(uint256(rawSeconds), 1, 2 days);
        vm.warp(block.timestamp + elapsed);
        _checkModelParity();
    }

    function settleFinishedProfit() public {
        _settleFinishedProfit();
    }

    function _settleFinishedProfit() private {
        bool shouldSettle = ghostLockedProfit != 0 && modelRemainingLockedProfit() == 0;
        uint256 feeAssets = shouldSettle ? ghostPendingFeeAssets : 0;
        uint256 expectedFeeShares = shouldSettle ? _modelFeeShares(feeAssets) : 0;
        uint256 probeShares = Math.min(ghostShareSupply, 1e18);
        uint256 depositPreviewBefore;
        uint256 redeemPreviewBefore;
        if (shouldSettle && modelAvailableAssets() != 0) {
            depositPreviewBefore = MANAGER.previewDeposit(1e6);
            redeemPreviewBefore = MANAGER.previewRedeem(probeShares);
        }
        uint256 sharesBefore = FUND_VAULT.balanceOf(FEE_RECIPIENT);
        uint256 minted = MANAGER.settleFinishedProfit();
        if (minted != expectedFeeShares) feeExactnessViolation = true;

        if (shouldSettle) {
            ghostLockedProfit = 0;
            ghostLockedRecoveryProfit = 0;
            ghostPendingFeeAssets = 0;
            ghostPendingFeeBps = 0;
            ghostProfitLockTimestamp = 0;
            ghostProfitUnlockTimestamp = 0;
            ghostShareSupply += expectedFeeShares;
        }

        uint256 received = FUND_VAULT.balanceOf(FEE_RECIPIENT) - sharesBefore;
        if (received != expectedFeeShares) feeExactnessViolation = true;
        if (received != 0 && MANAGER.previewRedeem(received) > feeAssets) {
            feeOverchargeViolation = true;
        }
        if (shouldSettle && modelAvailableAssets() != 0) {
            if (
                MANAGER.previewDeposit(1e6) != depositPreviewBefore
                    || MANAGER.previewRedeem(probeShares) != redeemPreviewBefore
            ) feeSettlementPriceViolation = true;
        }
        if (minted != 0) successfulFeeSettlements += 1;
        _checkModelParity();
    }

    function deployLiquidity(uint96 rawAssets) public {
        uint256 available = USDC.balanceOf(address(FUND_VAULT));
        if (available == 0) return;
        uint256 assets = bound(uint256(rawAssets), 1, available);

        vm.prank(address(FUND_VAULT));
        assertTrue(USDC.transfer(STRATEGY, assets));
        ghostDeployedUsdc += assets;
        _checkModelParity();
    }

    function returnLiquidity(uint96 rawAssets) public {
        uint256 deployed = USDC.balanceOf(STRATEGY);
        if (deployed == 0) return;
        uint256 assets = bound(uint256(rawAssets), 1, deployed);

        vm.prank(STRATEGY);
        assertTrue(USDC.transfer(address(FUND_VAULT), assets));
        ghostDeployedUsdc -= assets;
        _checkModelParity();
    }

    function donate(uint96 rawAssets) public {
        uint256 assets = bound(uint256(rawAssets), 1, MAX_ACTION_ASSETS);
        USDC.mint(address(FUND_VAULT), assets);
        ghostDonations += assets;
        _checkModelParity();
    }

    function actorAt(uint256 seed) public view returns (address) {
        return _actors[seed % ACTOR_COUNT];
    }

    function requestCount() external view returns (uint256) {
        return _requestIds.length;
    }

    function requestAt(uint256 index) external view returns (uint64) {
        return _requestIds[index];
    }

    function pendingRedemptionShares() external view returns (uint256 total) {
        uint256 length = _requestIds.length;
        for (uint256 index = 0; index < length; ++index) {
            AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
                MANAGER.getRedemption(_requestIds[index]);
            if (request.status == AlphaEngineUSDCVaultManager.RedemptionStatus.Pending) {
                total += request.shares;
            }
        }
    }

    function trackedShareSupply() external view returns (uint256 total) {
        for (uint256 index = 0; index < ACTOR_COUNT; ++index) {
            total += FUND_VAULT.balanceOf(_actors[index]);
        }
        total += FUND_VAULT.balanceOf(FEE_RECIPIENT);
        total += FUND_VAULT.balanceOf(address(FUND_VAULT));
    }

    function modelRemainingLockedProfit() public view returns (uint256) {
        return _modelRemainingAmount(ghostLockedProfit);
    }

    function modelRemainingLockedRecoveryProfit() public view returns (uint256) {
        uint256 remainingProfit = modelRemainingLockedProfit();
        if (remainingProfit == 0 || ghostLockedRecoveryProfit == 0) return 0;

        uint256 remainingRecovery = Math.mulDiv(
            ghostLockedRecoveryProfit, remainingProfit, ghostLockedProfit, Math.Rounding.Ceil
        );
        return Math.min(remainingRecovery, remainingProfit);
    }

    function modelAvailableAssets() public view returns (uint256) {
        return ghostManagedAssets - modelRemainingLockedProfit();
    }

    function modelEffectiveSupply() public view returns (uint256 supply) {
        supply = ghostShareSupply;
        if (
            ghostLockedProfit == 0 || modelRemainingLockedProfit() != 0
                || ghostPendingFeeAssets == 0
        ) return supply;
        return supply + _modelFeeShares(ghostPendingFeeAssets);
    }

    function modelPreviewDeposit(uint256 assets) public view returns (uint256 shares) {
        uint256 supply = modelEffectiveSupply();
        if (supply == 0) return assets * MANAGER.SHARE_SCALE();
        shares = Math.mulDiv(assets, supply, modelAvailableAssets());
    }

    function modelPreviewRedeem(uint256 shares) public view returns (uint256 assets) {
        uint256 supply = modelEffectiveSupply();
        if (supply == 0) return 0;
        assets = Math.mulDiv(shares, modelAvailableAssets(), supply);
    }

    function _applyModelLoss(uint256 loss)
        private
        returns (uint256 settledFeeAssets, uint256 settledFeeShares)
    {
        uint256 remainingProfit = modelRemainingLockedProfit();
        uint256 remainingRecovery = modelRemainingLockedRecoveryProfit();
        uint256 remainingFeeable = remainingProfit - remainingRecovery;
        uint256 cancelledProfit = Math.min(loss, remainingProfit);
        uint256 cancelledFeeable = Math.min(cancelledProfit, remainingFeeable);
        uint256 cancelledRecovery = cancelledProfit - cancelledFeeable;

        uint256 feeReduction =
            Math.mulDiv(cancelledFeeable, ghostPendingFeeBps, MANAGER.BPS(), Math.Rounding.Ceil);
        ghostPendingFeeAssets -= Math.min(ghostPendingFeeAssets, feeReduction);

        uint256 newLockedRecovery = remainingRecovery - cancelledRecovery;
        uint256 newLockedProfit = remainingProfit - cancelledProfit;
        ghostLockedProfit = newLockedProfit;
        ghostLockedRecoveryProfit = newLockedRecovery;
        ghostLossToRecover += cancelledRecovery + (loss - cancelledProfit);

        if (newLockedProfit == 0) {
            settledFeeAssets = ghostPendingFeeAssets;
            settledFeeShares =
                _modelFeeSharesAt(settledFeeAssets, ghostShareSupply, ghostManagedAssets - loss);
            ghostLockedRecoveryProfit = 0;
            ghostPendingFeeAssets = 0;
            ghostPendingFeeBps = 0;
            ghostProfitLockTimestamp = 0;
            ghostProfitUnlockTimestamp = 0;
            ghostShareSupply += settledFeeShares;
        } else {
            ghostProfitLockTimestamp = uint64(block.timestamp);
        }
    }

    function _modelRemainingAmount(uint256 amount) private view returns (uint256) {
        if (amount == 0 || block.timestamp >= ghostProfitUnlockTimestamp) return 0;
        if (block.timestamp <= ghostProfitLockTimestamp) return amount;

        uint256 remainingTime = ghostProfitUnlockTimestamp - uint64(block.timestamp);
        uint256 lockDuration = ghostProfitUnlockTimestamp - ghostProfitLockTimestamp;
        return Math.mulDiv(amount, remainingTime, lockDuration, Math.Rounding.Ceil);
    }

    function _modelFeeShares(uint256 feeAssets) private view returns (uint256) {
        return _modelFeeSharesAt(feeAssets, ghostShareSupply, ghostManagedAssets);
    }

    function _modelFeeSharesAt(uint256 feeAssets, uint256 supply, uint256 assets)
        private
        pure
        returns (uint256)
    {
        if (feeAssets == 0 || supply == 0 || assets <= feeAssets) return 0;
        return Math.mulDiv(feeAssets, supply, assets - feeAssets);
    }

    function _checkModelParity() private {
        if (
            MANAGER.managedAssets() != ghostManagedAssets
                || MANAGER.lockedProfit() != ghostLockedProfit
                || MANAGER.lockedRecoveryProfit() != ghostLockedRecoveryProfit
                || MANAGER.pendingFeeAssets() != ghostPendingFeeAssets
                || MANAGER.lossToRecover() != ghostLossToRecover
                || MANAGER.profitLockTimestamp() != ghostProfitLockTimestamp
                || MANAGER.profitUnlockTimestamp() != ghostProfitUnlockTimestamp
                || MANAGER.pendingFeeBps() != ghostPendingFeeBps
                || FUND_VAULT.totalSupply() != ghostShareSupply
                || MANAGER.remainingLockedProfit() != modelRemainingLockedProfit()
                || MANAGER.remainingLockedRecoveryProfit() != modelRemainingLockedRecoveryProfit()
                || MANAGER.availableAssets() != modelAvailableAssets()
        ) accountingModelViolation = true;

        uint256 effectiveSupply = modelEffectiveSupply();
        if (effectiveSupply != 0) {
            uint256 probeShares = Math.min(ghostShareSupply, 1e18);
            if (MANAGER.previewRedeem(probeShares) != modelPreviewRedeem(probeShares)) {
                accountingModelViolation = true;
            }
        }
        if (modelAvailableAssets() != 0) {
            if (MANAGER.previewDeposit(1e6) != modelPreviewDeposit(1e6)) {
                accountingModelViolation = true;
            }
        }
    }

    function _pendingRequest(uint256 seed) private view returns (uint64 requestId, bool found) {
        uint256 length = _requestIds.length;
        if (length == 0) return (0, false);

        uint256 start = seed % length;
        for (uint256 offset = 0; offset < length; ++offset) {
            requestId = _requestIds[(start + offset) % length];
            if (
                MANAGER.getRedemption(requestId).status
                    == AlphaEngineUSDCVaultManager.RedemptionStatus.Pending
            ) return (requestId, true);
        }
        return (0, false);
    }

    function _nextReport() private returns (uint64 epoch, uint64 referenceBlock) {
        epoch = MANAGER.reportEpoch() + 1;
        referenceBlock = MANAGER.lastReferenceBlock() + 1;
        if (referenceBlock >= block.number) vm.roll(uint256(referenceBlock) + 1);
    }
}
