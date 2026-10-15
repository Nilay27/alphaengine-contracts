// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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

    mapping(address => uint256) public ghostShares;
    mapping(address => uint256) public ghostExternalFunding;
    mapping(address => uint256) public ghostCashReceived;
    // Economic ownership differs from actual recipient cash when the owner names another receiver.
    mapping(address => uint256) public ghostPaidOnBehalfOfOwner;
    mapping(uint64 => bytes32) public ghostRequestBinding;
    mapping(uint64 => AlphaEngineUSDCVaultManager.RedemptionStatus) public ghostRequestStatus;
    mapping(address => uint256) public ghostPendingShares;
    address private constant SECOND_FEE_RECIPIENT = address(0xFEE2);
    uint256[ACTOR_COUNT] public cohortPrincipal;
    bool public feeCohortActive;
    bool public feeCohortViolation;
    bool public earnedFeeErasureViolation;
    uint256 public fundedCohorts;
    uint256 public cohortSettlements;
    uint256 public ghostFundedProfit;
    uint256 public ghostFundedLoss;
    uint256 public shareTransfers;
    uint256 public governanceTransitions;
    uint256 public rejectedActions;
    uint256 public roundTrips;
    uint256 public residualRequests;
    uint256 public drainedRequests;
    bool public actorLedgerViolation;
    bool public incomingRoundingLossViolation;
    bool public roundTripGainViolation;
    bool public roundTripLossViolation;
    uint256 public largestRoundTripLoss;
    uint256[32] public scenarioRuns;
    bool public actorEntitlementViolation;
    uint256 public dailyExitProgress;

    uint256 public ghostManagedAssets;
    uint256 public ghostDepositedUsdc;
    uint256 public ghostRedeemedUsdc;
    uint256 public ghostProtocolResidual;
    uint256 public ghostDonations;
    uint256 public ghostDeployedUsdc;
    uint256 public ghostCompletedRedemptionAssets;
    uint256 public ghostReportedProfit;
    uint256 public ghostReportedLoss;
    uint256 public ghostShareSupply;
    uint256 public ghostLockedProfit;
    uint256 public ghostLockedRecoveryProfit;
    uint256 public ghostLossToRecover;
    uint64 public ghostProfitLockTimestamp;
    uint64 public ghostProfitUnlockTimestamp;

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
    uint256 private _trancheFeeAssets;
    uint256 private _trancheFeeShares;

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
        if (supplyBefore != 0 && assetsBefore == 0) {
            bytes32 beforeState = lifecycleStateHash();
            vm.expectRevert(
                MANAGER.paused()
                    ? Pausable.EnforcedPause.selector
                    : AlphaEngineUSDCVaultManager.InsolventVault.selector
            );
            vm.prank(actor);
            MANAGER.deposit(assets, actor, 0);
            assertEq(lifecycleStateHash(), beforeState);
            ++rejectedActions;
            return;
        }
        uint256 expectedShares = modelPreviewDeposit(assets);
        uint256 expectedSupply = supplyBefore + expectedShares;
        if (
            MANAGER.paused() || FUND_VAULT.paused() || expectedShares == 0
                || expectedSupply < MANAGER.MIN_SHARE_SUPPLY()
        ) {
            bytes32 beforeState = lifecycleStateHash();
            if (MANAGER.paused()) {
                vm.expectRevert(Pausable.EnforcedPause.selector);
            } else if (expectedShares == 0) {
                vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroShares.selector);
            } else if (expectedSupply < MANAGER.MIN_SHARE_SUPPLY()) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        AlphaEngineUSDCVaultManager.InsufficientShareSupply.selector,
                        expectedSupply,
                        MANAGER.MIN_SHARE_SUPPLY()
                    )
                );
            } else {
                vm.expectRevert(Pausable.EnforcedPause.selector);
            }
            vm.prank(actor);
            MANAGER.deposit(assets, actor, 0);
            assertEq(lifecycleStateHash(), beforeState);
            ++rejectedActions;
            return;
        }

        USDC.mint(actor, assets);
        vm.prank(actor);
        uint256 shares = MANAGER.deposit(assets, actor, 0);
        if (shares != expectedShares) accountingModelViolation = true;

        feeCohortActive = false; // Fee-burden oracle isolates holders present before the profit tranche.
        ghostShares[actor] += shares;
        ghostExternalFunding[actor] += assets;
        // FV-01: cross-multiplication bounds loss in ASSET units, not in shares.
        uint256 pricingSupply = supplyBefore + MANAGER.SHARE_SCALE();
        uint256 pricingAssets = assetsBefore + 1;
        if (assets * pricingSupply > shares * pricingAssets + pricingSupply) {
            incomingRoundingLossViolation = true;
        }
        ghostManagedAssets += assets;
        ghostDepositedUsdc += assets;
        ghostShareSupply += expectedShares;
        successfulDeposits += 1;
        if (MANAGER.lossToRecover() != lossToRecoverBefore) lossRecoveryFlowViolation = true;

        if (supplyBefore != 0) {
            uint256 left = (MANAGER.availableAssets() + 1) * pricingSupply;
            uint256 right = pricingAssets * (FUND_VAULT.totalSupply() + MANAGER.SHARE_SCALE());
            if (left < right || left - right >= pricingAssets) depositPriceViolation = true;
        }
        _checkModelParity();
    }

    function requestRedeem(uint256 actorSeed, uint96 rawShares) public {
        address actor = actorAt(actorSeed);
        uint256 balance = FUND_VAULT.balanceOf(actor);
        if (balance == 0) return;

        uint256 shares = bound(uint256(rawShares), 1, balance);
        _request(actor, actor, shares, 0);
    }

    function cancelRedeem(uint256 requestSeed) public {
        (uint64 requestId, bool found) = _pendingRequest(requestSeed);
        if (!found) return;
        AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
            MANAGER.getRedemption(requestId);

        vm.prank(request.owner);
        MANAGER.cancelRedeem(requestId);
        ghostShares[address(FUND_VAULT)] -= request.shares;
        ghostShares[request.owner] += request.shares;
        ghostPendingShares[request.owner] -= request.shares;
        ghostRequestStatus[requestId] = AlphaEngineUSDCVaultManager.RedemptionStatus.Cancelled;
        _checkRequestParity(requestId);
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
        uint256 remainingSupply = FUND_VAULT.totalSupply() - request.shares;
        if (remainingSupply != 0 && remainingSupply < MANAGER.MIN_SHARE_SUPPLY()) {
            bytes32 beforeState = lifecycleStateHash();
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineUSDCVaultManager.InsufficientShareSupply.selector,
                    remainingSupply,
                    MANAGER.MIN_SHARE_SUPPLY()
                )
            );
            MANAGER.completeRedeem(requestId);
            assertEq(lifecycleStateHash(), beforeState);
            ++rejectedActions;
            return;
        }
        if (request.shares == FUND_VAULT.totalSupply() && remainingProfit != 0) return;

        uint256 assets = modelPreviewRedeem(request.shares);
        if (MANAGER.previewRedeem(request.shares) != assets) accountingModelViolation = true;
        if (assets < request.minAssets) {
            bytes32 beforeState = lifecycleStateHash();
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineUSDCVaultManager.InsufficientAssets.selector,
                    assets,
                    request.minAssets
                )
            );
            MANAGER.completeRedeem(requestId);
            assertEq(lifecycleStateHash(), beforeState);
            ++rejectedActions;
            return;
        }
        uint256 residual = remainingSupply == 0 ? ghostManagedAssets - assets : 0;
        if (USDC.balanceOf(address(FUND_VAULT)) < assets + residual) return;

        uint256 assetsBefore = MANAGER.availableAssets();
        uint256 supplyBefore = FUND_VAULT.totalSupply();
        uint256 lossToRecoverBefore = ghostLossToRecover;
        uint256 completedAssets = MANAGER.completeRedeem(requestId);
        if (completedAssets != assets) accountingModelViolation = true;

        ghostShares[address(FUND_VAULT)] -= request.shares;
        ghostPendingShares[request.owner] -= request.shares;
        ghostCashReceived[request.receiver] += assets;
        ghostPaidOnBehalfOfOwner[request.owner] += assets;
        ghostRequestStatus[requestId] = AlphaEngineUSDCVaultManager.RedemptionStatus.Completed;
        _checkRequestParity(requestId);
        ghostManagedAssets -= assets + residual;
        ghostProtocolResidual += residual;
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
            uint256 pricingSupply = supplyBefore + MANAGER.SHARE_SCALE();
            uint256 left = (MANAGER.availableAssets() + 1) * pricingSupply;
            uint256 right = (assetsBefore + 1) * (supplyAfter + MANAGER.SHARE_SCALE());
            if (left < right || left - right >= pricingSupply) redemptionPriceViolation = true;
        }
        _checkModelParity();
    }

    function attemptIlliquidCompletion(uint256 requestSeed) public {
        (uint64 requestId, bool found) = _pendingRequest(requestSeed);
        if (!found) return;
        AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
            MANAGER.getRedemption(requestId);
        uint256 remainingSupply = FUND_VAULT.totalSupply() - request.shares;
        if (remainingSupply != 0 && remainingSupply < MANAGER.MIN_SHARE_SUPPLY()) {
            attemptGuardedCompletion(requestSeed);
            return;
        }
        uint256 remainingProfit = modelRemainingLockedProfit();
        if (request.shares == FUND_VAULT.totalSupply() && remainingProfit != 0) return;

        uint256 assets = modelPreviewRedeem(request.shares);
        if (MANAGER.previewRedeem(request.shares) != assets) accountingModelViolation = true;
        uint256 available = USDC.balanceOf(address(FUND_VAULT));
        uint256 required = remainingSupply == 0 ? ghostManagedAssets : assets;
        if (required == 0 || available >= required || assets < request.minAssets) return;

        uint256 managedBefore = MANAGER.managedAssets();
        uint256 supplyBefore = FUND_VAULT.totalSupply();
        uint256 escrowBefore = FUND_VAULT.balanceOf(address(FUND_VAULT));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientVaultLiquidity.selector, available, required
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
        uint256 feeAssets =
            Math.mulDiv(profit - recoveryProfit, MANAGER.performanceFeeBps(), 10_000);
        uint256 feeShares = Math.mulDiv(feeAssets, ghostShareSupply + 1e12, availableBefore + 1);
        if (MANAGER.paused() || (feeAssets != 0 && feeShares == 0)) {
            address reporter = MANAGER.navReporter();
            bytes32 beforeState = lifecycleStateHash();
            vm.expectRevert(
                MANAGER.paused()
                    ? Pausable.EnforcedPause.selector
                    : AlphaEngineUSDCVaultManager.ZeroShares.selector
            );
            vm.prank(reporter);
            MANAGER.reportProfit(epoch, referenceBlock, profit, keccak256("rejected profit"));
            assertEq(lifecycleStateHash(), beforeState);
            ++rejectedActions;
            return;
        }
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            cohortPrincipal[i] =
                ghostPaidOnBehalfOfOwner[_actors[i]] + modelPreviewRedeem(ownedShares(_actors[i]));
        }
        feeCohortActive = true;
        ++fundedCohorts;
        USDC.mint(address(FUND_VAULT), profit);
        ghostFundedProfit += profit;
        address recipient = MANAGER.feeRecipient();
        uint256 beforeShares = FUND_VAULT.balanceOf(recipient);
        vm.prank(MANAGER.navReporter());
        MANAGER.reportProfit(
            epoch, referenceBlock, profit, keccak256(abi.encode("invariant profit", epoch, profit))
        );
        uint256 received = FUND_VAULT.balanceOf(recipient) - beforeShares;
        if (received != feeShares) feeExactnessViolation = true;
        // Fee value at the current recognized price, before subsequent vesting gain.
        uint256 feeValue = Math.mulDiv(
            received, availableBefore + feeAssets + 1, ghostShareSupply + received + 1e12
        );
        if (feeValue > feeAssets) feeOverchargeViolation = true;
        if (feeValue + 1 < feeAssets) earnedFeeErasureViolation = true;
        ghostShares[recipient] += received;
        ghostShareSupply += feeShares;
        if (feeShares != 0) ++successfulFeeSettlements;
        _trancheFeeAssets = feeAssets;
        _trancheFeeShares = feeShares;
        ghostManagedAssets += profit;
        ghostReportedProfit += profit;
        ghostLossToRecover -= recoveryProfit;
        ghostLockedProfit = profit - feeAssets;
        ghostLockedRecoveryProfit = recoveryProfit;
        ghostProfitLockTimestamp = uint64(block.timestamp);
        ghostProfitUnlockTimestamp = uint64(block.timestamp) + MANAGER.vestingPeriod();
        ++successfulProfitReports;
        if (modelAvailableAssets() != availableBefore + feeAssets) accountingModelViolation = true;
        _checkModelParity();
    }

    function reportLoss(uint96 rawLoss) public {
        _settleFinishedProfit();
        uint256 managed = ghostManagedAssets;
        if (managed == 0) return;
        uint256 loss = bound(uint256(rawLoss), 1, managed);
        (uint64 epoch, uint64 referenceBlock) = _nextReport();
        uint256 feeBalanceBefore = FUND_VAULT.balanceOf(MANAGER.feeRecipient());
        uint256 supplyBefore = ghostShareSupply;

        if (MANAGER.paused()) {
            address reporter = MANAGER.navReporter();
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(reporter);
            MANAGER.reportLoss(epoch, referenceBlock, loss, keccak256("paused loss"));
            ++rejectedActions;
            return;
        }
        uint256 idleLoss = Math.min(loss, USDC.balanceOf(address(FUND_VAULT)));
        feeCohortActive = false; // A real recognized loss may legitimately reduce principal.
        vm.prank(address(FUND_VAULT));
        assertTrue(USDC.transfer(address(0x1055), idleLoss));
        uint256 deployedLoss = loss - idleLoss;
        if (deployedLoss != 0) {
            vm.prank(STRATEGY);
            assertTrue(USDC.transfer(address(0x1055), deployedLoss));
            ghostDeployedUsdc -= deployedLoss;
        }
        ghostFundedLoss += loss;
        vm.prank(MANAGER.navReporter());
        MANAGER.reportLoss(
            epoch, referenceBlock, loss, keccak256(abi.encode("invariant loss", epoch, loss))
        );
        _applyModelLoss(loss);
        _trancheFeeAssets = 0; // Real losses legitimately reduce already-issued treasury shares.
        _trancheFeeShares = 0;
        ghostManagedAssets -= loss;
        ghostReportedLoss += loss;
        successfulLossReports += 1;
        if (
            FUND_VAULT.balanceOf(MANAGER.feeRecipient()) != feeBalanceBefore
                || ghostShareSupply != supplyBefore
        ) {
            feeExactnessViolation = true;
        }
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
        uint256 probeShares = Math.min(ghostShareSupply, 1e18);
        uint256 depositPreviewBefore;
        uint256 redeemPreviewBefore;
        if (shouldSettle && modelAvailableAssets() != 0) {
            depositPreviewBefore = MANAGER.previewDeposit(1e6);
            redeemPreviewBefore = MANAGER.previewRedeem(probeShares);
        }
        uint256 sharesBefore = FUND_VAULT.balanceOf(MANAGER.feeRecipient());
        uint256 minted = MANAGER.settleFinishedProfit();
        if (minted != 0 || FUND_VAULT.balanceOf(MANAGER.feeRecipient()) != sharesBefore) {
            feeExactnessViolation = true;
        }
        if (shouldSettle) {
            if (feeCohortActive) ++cohortSettlements;
            if (modelPreviewRedeem(_trancheFeeShares) + 1 < _trancheFeeAssets) {
                earnedFeeErasureViolation = true;
            }
            ghostLockedProfit = 0;
            ghostLockedRecoveryProfit = 0;
            ghostProfitLockTimestamp = 0;
            ghostProfitUnlockTimestamp = 0;
            _trancheFeeAssets = 0;
            _trancheFeeShares = 0;
        }
        if (shouldSettle && modelAvailableAssets() != 0) {
            if (
                MANAGER.previewDeposit(1e6) != depositPreviewBefore
                    || MANAGER.previewRedeem(probeShares) != redeemPreviewBefore
            ) feeSettlementPriceViolation = true;
        }
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

    /// @notice FV-16/FV-17/FV-25: vary ownership, receiver, minima and request ordering.
    function requestWithMinimum(uint256 actorSeed, uint96 rawShares, uint8 minimumMode) public {
        address actor = actorAt(actorSeed);
        uint256 balance = FUND_VAULT.balanceOf(actor);
        if (balance == 0) return;
        uint256 shares = bound(uint256(rawShares), 1, balance);
        uint256 quoted = MANAGER.previewRedeem(shares);
        uint256 minimum = minimumMode % 3 == 0 ? 0 : quoted + (minimumMode % 3 == 1 ? 0 : 1);
        _request(actor, actorAt(actorSeed % ACTOR_COUNT + 1), shares, minimum);
    }

    /// @notice FV-01: deliberately leave tiny residual supply; random absolute shares almost never do.
    function requestResidualExit(uint256 actorSeed, uint8 residualSeed) public {
        address actor = actorAt(actorSeed);
        uint256[5] memory residuals = [uint256(1), 2, 1e12 - 1, 1e12, 1e18];
        uint256 balance = FUND_VAULT.balanceOf(actor);
        uint256 residual = residuals[residualSeed % residuals.length];
        if (balance <= residual) return;
        _request(actor, actor, balance - residual, 0);
        ++residualRequests;
    }

    function _request(address actor, address receiver, uint256 shares, uint256 minimum) private {
        if (MANAGER.paused() || FUND_VAULT.paused()) {
            bytes32 beforeState = lifecycleStateHash();
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(actor);
            MANAGER.requestRedeem(shares, receiver, minimum);
            assertEq(lifecycleStateHash(), beforeState);
            ++rejectedActions;
            return;
        }
        vm.prank(actor);
        uint64 id = MANAGER.requestRedeem(shares, receiver, minimum);
        _requestIds.push(id);
        ghostShares[actor] -= shares;
        ghostShares[address(FUND_VAULT)] += shares;
        ghostRequestBinding[id] = keccak256(abi.encode(actor, receiver, shares, minimum));
        ghostRequestStatus[id] = AlphaEngineUSDCVaultManager.RedemptionStatus.Pending;
        ghostPendingShares[actor] += shares;
        _checkRequestParity(id);
        ++successfulRequests;
        _checkModelParity();
    }

    /// @notice FV-02/FV-03: no-time/no-P&L round trip after the entire prior randomized lifecycle.
    function roundTrip(uint256 actorSeed, uint96 rawAssets, uint8 repetitions) public {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _settleFinishedProfit();
        if (FUND_VAULT.totalSupply() == 0 || MANAGER.availableAssets() == 0) return;
        uint256 assets = bound(uint256(rawAssets), 1, MAX_ACTION_ASSETS);
        if (modelPreviewDeposit(assets) == 0) return; // Invalid zero-share admission is tested by deposit().
        uint256 loops = repetitions % 3 == 0 ? 2 : (repetitions % 3 == 1 ? 10 : 100);
        // External self-calls reset temporary memory without changing time, P&L or cycle count.
        for (uint256 i; i < loops; ++i) {
            if (!this.roundTripOnce(actorSeed, assets)) return;
        }
    }

    function roundTripOnce(uint256 actorSeed, uint256 assets) external returns (bool) {
        assertEq(msg.sender, address(this));
        address actor = actorAt(actorSeed);
        uint256 sharesBefore = FUND_VAULT.balanceOf(actor);
        uint256 cashBefore = ghostCashReceived[actor];
        deposit(actorSeed, uint96(assets));
        uint256 acquired = FUND_VAULT.balanceOf(actor) - sharesBefore;
        _request(actor, actor, acquired, 0);
        uint64 id = _requestIds[_requestIds.length - 1];
        uint256 quote = MANAGER.previewRedeem(acquired);
        // Idle-liquidity is a real async-settlement precondition; deposit itself supplied assets.
        if (quote > USDC.balanceOf(address(FUND_VAULT))) {
            cancelRedeem(_requestIds.length - 1);
            return false;
        }
        completeRedeem(_requestIds.length - 1);
        assertEq(
            uint256(MANAGER.getRedemption(id).status),
            uint256(AlphaEngineUSDCVaultManager.RedemptionStatus.Completed)
        );
        uint256 paid = ghostCashReceived[actor] - cashBefore;
        if (paid > assets) roundTripGainViolation = true;
        if (assets > paid + 2) roundTripLossViolation = true;
        if (assets > paid) {
            largestRoundTripLoss = Math.max(largestRoundTripLoss, assets - paid);
        }
        ++roundTrips;
        return true;
    }

    /// @notice FV-03: inverse repeated cycles reinvest real redeemed cash, with no external funding or elapsed time.
    function redeemAndReinvest(uint256 actorSeed, uint96 rawShares, uint8 repetitions) public {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _settleFinishedProfit();
        address actor = actorAt(actorSeed);
        uint256 balance = FUND_VAULT.balanceOf(actor);
        if (balance == 0 || MANAGER.availableAssets() == 0) return;
        uint256 shares = bound(rawShares, 1, balance);
        uint256 loops = repetitions % 3 == 0 ? 2 : repetitions % 3 == 1 ? 10 : 100;
        for (uint256 i; i < loops; ++i) {
            bool completed;
            (shares, completed) = this.redeemAndReinvestOnce(actorSeed, shares);
            if (!completed) return;
        }
    }

    function redeemAndReinvestOnce(uint256 actorSeed, uint256 shares)
        external
        returns (uint256, bool)
    {
        assertEq(msg.sender, address(this));
        address actor = actorAt(actorSeed);
        if (shares == FUND_VAULT.totalSupply() && MANAGER.remainingLockedProfit() != 0) {
            return (shares, false);
        }
        uint256 remainingSupply = FUND_VAULT.totalSupply() - shares;
        if (remainingSupply != 0 && remainingSupply < MANAGER.MIN_SHARE_SUPPLY()) {
            _request(actor, actor, shares, 0);
            attemptGuardedCompletion(_requestIds.length - 1);
            cancelRedeem(_requestIds.length - 1);
            return (shares, false);
        }
        uint256 quoted = MANAGER.previewRedeem(shares);
        if (
            (remainingSupply == 0 ? ghostManagedAssets : quoted)
                > USDC.balanceOf(address(FUND_VAULT))
        ) return (shares, false);
        uint256 wealthBefore = USDC.balanceOf(actor) + modelPreviewRedeem(ownedShares(actor));
        _request(actor, actor, shares, 0);
        completeRedeem(_requestIds.length - 1);
        if (quoted == 0) {
            ++scenarioRuns[3];
            return (shares, false);
        }
        uint256 expectedShares = modelPreviewDeposit(quoted);
        if (expectedShares == 0 || ghostShareSupply + expectedShares < MANAGER.MIN_SHARE_SUPPLY()) {
            bytes32 beforeState = lifecycleStateHash();
            if (expectedShares == 0) {
                vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroShares.selector);
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        AlphaEngineUSDCVaultManager.InsufficientShareSupply.selector,
                        ghostShareSupply + expectedShares,
                        MANAGER.MIN_SHARE_SUPPLY()
                    )
                );
            }
            vm.prank(actor);
            MANAGER.deposit(quoted, actor, 0);
            assertEq(lifecycleStateHash(), beforeState);
            ++rejectedActions;
            ++scenarioRuns[3];
            return (shares, false);
        }
        uint256 supplyBefore = FUND_VAULT.totalSupply();
        uint256 availableBefore = MANAGER.availableAssets();
        vm.prank(actor);
        uint256 issued = MANAGER.deposit(quoted, actor, 0);
        assertEq(issued, expectedShares);
        if (
            supplyBefore != 0
                && quoted * (supplyBefore + 1e12)
                    > issued * (availableBefore + 1) + supplyBefore + 1e12
        ) {
            incomingRoundingLossViolation = true;
        }
        ghostShares[actor] += issued;
        ghostCashReceived[actor] -= quoted;
        ghostPaidOnBehalfOfOwner[actor] -= quoted;
        ghostManagedAssets += quoted;
        ghostDepositedUsdc += quoted;
        ghostShareSupply += issued;
        feeCohortActive = false;
        ++successfulDeposits;
        uint256 wealthAfter = USDC.balanceOf(actor) + modelPreviewRedeem(ownedShares(actor));
        if (wealthAfter > wealthBefore + 2) roundTripGainViolation = true;
        if (wealthBefore > wealthAfter + 2) roundTripLossViolation = true;
        shares = issued;
        ++roundTrips;
        ++scenarioRuns[3];
        _checkModelParity();
        return (shares, true);
    }

    /// @notice FV-09/FV-17: rejected completions preserve all request/share/cash state.
    function attemptGuardedCompletion(uint256 requestSeed) public {
        (uint64 id, bool found) = _pendingRequest(requestSeed);
        if (!found) return;
        AlphaEngineUSDCVaultManager.RedemptionRequest memory r = MANAGER.getRedemption(id);
        bytes memory expected;
        uint256 locked = MANAGER.remainingLockedProfit();
        uint256 quote = MANAGER.previewRedeem(r.shares);
        uint256 remainingSupply = modelEffectiveSupply() - r.shares;
        uint256 required = remainingSupply == 0 ? ghostManagedAssets : quote;
        if (remainingSupply != 0 && remainingSupply < MANAGER.MIN_SHARE_SUPPLY()) {
            expected = abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientShareSupply.selector,
                remainingSupply,
                MANAGER.MIN_SHARE_SUPPLY()
            );
        } else if (r.shares == modelEffectiveSupply() && locked != 0) {
            expected = abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.FinalRedemptionWhileProfitLocked.selector, locked
            );
        } else if (quote < r.minAssets) {
            expected = abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientAssets.selector, quote, r.minAssets
            );
        } else if (required > USDC.balanceOf(address(FUND_VAULT))) {
            expected = abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientVaultLiquidity.selector,
                USDC.balanceOf(address(FUND_VAULT)),
                required
            );
        } else {
            completeRedeem(requestSeed);
            return;
        }
        bytes32 beforeState = lifecycleStateHash();
        vm.expectRevert(expected);
        MANAGER.completeRedeem(id);
        assertEq(lifecycleStateHash(), beforeState);
        ++rejectedActions;
    }

    /// @notice FV-16/FV-19: terminal records cannot revive or release another owner's shares.
    function attemptTerminalReplay(uint256 seed) public {
        if (_requestIds.length == 0) return;
        uint64 id = _requestIds[seed % _requestIds.length];
        AlphaEngineUSDCVaultManager.RedemptionRequest memory r = MANAGER.getRedemption(id);
        if (r.status == AlphaEngineUSDCVaultManager.RedemptionStatus.Pending) return;
        bytes32 beforeState = lifecycleStateHash();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InvalidRedemptionStatus.selector, id, r.status
            )
        );
        MANAGER.completeRedeem(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InvalidRedemptionStatus.selector, id, r.status
            )
        );
        vm.prank(r.owner);
        MANAGER.cancelRedeem(id);
        assertEq(lifecycleStateHash(), beforeState);
        ++rejectedActions;
    }

    /// @notice FV-25/FV-30: independent per-owner share accounting through both transfer APIs.
    function transferShares(uint256 actorSeed, uint96 rawShares, bool delegated) public {
        address from = actorAt(actorSeed);
        address to = actorAt(actorSeed % ACTOR_COUNT + 1);
        uint256 balance = FUND_VAULT.balanceOf(from);
        if (balance == 0) return;
        uint256 shares = bound(uint256(rawShares), 1, balance);
        if (delegated) {
            vm.prank(from);
            FUND_VAULT.approve(address(this), shares);
            FUND_VAULT.transferFrom(from, to, shares);
            assertEq(FUND_VAULT.allowance(from, address(this)), 0);
        } else {
            vm.prank(from);
            FUND_VAULT.transfer(to, shares);
        }
        feeCohortActive = false; // Transfer changes the principal basis; checked by the ownership ledger instead.
        ghostShares[from] -= shares;
        ghostShares[to] += shares;
        ++shareTransfers;
        _checkModelParity();
    }

    /// @notice FV-20/FV-21/FV-22: prospective config, issued fee ownership and immutable active timestamps.
    function configureAccounting(uint16 feeSeed, uint32 durationSeed, bool changeRecipient) public {
        uint16 fee = uint16(bound(feeSeed, 0, 2000));
        uint256 issuedFeeShares = FUND_VAULT.balanceOf(MANAGER.feeRecipient());
        uint64 oldUnlock = MANAGER.profitUnlockTimestamp();
        address owner = MANAGER.owner();
        vm.prank(owner);
        MANAGER.setPerformanceFeeBps(fee);
        assertEq(FUND_VAULT.balanceOf(MANAGER.feeRecipient()), issuedFeeShares);
        assertEq(MANAGER.profitUnlockTimestamp(), oldUnlock);
        if (changeRecipient) {
            address recipient =
                MANAGER.feeRecipient() == FEE_RECIPIENT ? SECOND_FEE_RECIPIENT : FEE_RECIPIENT;
            vm.prank(owner);
            MANAGER.setFeeRecipient(recipient);
        }
        uint64 duration = uint64(bound(durationSeed, 1, 7 days));
        uint256 locked = MANAGER.remainingLockedProfit();
        if (locked != 0) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineUSDCVaultManager.ProfitStillVesting.selector, locked
                )
            );
            vm.prank(owner);
            MANAGER.setVestingPeriod(duration);
            assertEq(MANAGER.profitUnlockTimestamp(), oldUnlock);
            ++rejectedActions;
        } else {
            _settleFinishedProfit();
            vm.prank(owner);
            MANAGER.setVestingPeriod(duration);
        }
        ++governanceTransitions;
        _checkModelParity();
    }

    /// @notice FV-23: only the current NAV reporter may mutate the ledger.
    function rotateReporter(bool alternate) public {
        address oldReporter = MANAGER.navReporter();
        address newReporter = alternate ? address(0xAAA123) : address(this);
        if (oldReporter == newReporter) return;
        vm.prank(MANAGER.owner());
        MANAGER.setNavReporter(newReporter);
        bytes32 beforeState = lifecycleStateHash();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.UnauthorizedNAVReporter.selector, oldReporter
            )
        );
        vm.prank(oldReporter);
        MANAGER.reportLoss(1, 1, 1, bytes32(uint256(1)));
        assertEq(lifecycleStateHash(), beforeState);
        ++governanceTransitions;
        ++rejectedActions;
    }

    /// @notice FV-24: independent manager/vault pause domains; old claims remain processable.
    function configurePause(bool managerPaused, bool vaultPaused) public {
        if (MANAGER.paused() != managerPaused) {
            vm.prank(MANAGER.owner());
            if (managerPaused) MANAGER.pause();
            else MANAGER.unpause();
        }
        if (FUND_VAULT.paused() != vaultPaused) {
            vm.prank(FUND_VAULT.owner());
            if (vaultPaused) FUND_VAULT.pause();
            else FUND_VAULT.unpause();
        }
        ++governanceTransitions;
        _checkModelParity();
    }

    /// @notice FV-31: two-step business ownership is independent of claims/reporter.
    function handoverOwners(bool alternate) public {
        address nextOwner = alternate ? address(0xAB011) : address(0xAB022);
        address oldOwner = MANAGER.owner();
        if (nextOwner == oldOwner) return;
        bytes32 beforeClaims = _claimsHash();
        address reporter = MANAGER.navReporter();
        vm.prank(oldOwner);
        MANAGER.transferOwnership(nextOwner);
        assertEq(MANAGER.owner(), oldOwner);
        vm.prank(nextOwner);
        MANAGER.acceptOwnership();
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, oldOwner)
        );
        vm.prank(oldOwner);
        MANAGER.setNavReporter(oldOwner);
        address vaultOwner = FUND_VAULT.owner();
        vm.prank(vaultOwner);
        FUND_VAULT.transferOwnership(nextOwner);
        assertEq(FUND_VAULT.owner(), vaultOwner);
        vm.prank(nextOwner);
        FUND_VAULT.acceptOwnership();
        assertEq(_claimsHash(), beforeClaims);
        assertEq(MANAGER.navReporter(), reporter);
        ++governanceTransitions;
        _checkModelParity();
    }

    /// @notice FV-13/FV-28: an unfinished tranche cannot be overwritten by another report.
    function attemptProfitOverwrite(uint96 rawProfit) public {
        uint256 remaining = MANAGER.remainingLockedProfit();
        if (remaining == 0 || MANAGER.paused() || ghostShareSupply == 0) return;
        (uint64 epoch, uint64 refBlock) = _nextReport();
        uint256 profit = bound(rawProfit, 1, MAX_ACTION_ASSETS);
        bytes32 beforeState = lifecycleStateHash();
        address reporter = MANAGER.navReporter();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.ProfitStillVesting.selector, remaining
            )
        );
        vm.prank(reporter);
        MANAGER.reportProfit(epoch, refBlock, profit, bytes32(uint256(1)));
        assertEq(lifecycleStateHash(), beforeState);
        ++rejectedActions;
    }

    /// @notice FV-09/FV-28: exact boundaries, monotonic time, and no invented continuous timer.
    function advanceToVestBoundary(uint8 edge) public {
        uint64 unlock = MANAGER.profitUnlockTimestamp();
        if (unlock == 0) return;
        uint256 target = uint256(unlock) + edge % 3;
        if (edge % 3 == 0 && unlock > 0) target = uint256(unlock) - 1;
        if (target > block.timestamp) vm.warp(target);
        _checkModelParity();
    }

    /// @notice FV-18/FV-19: actively complete every eligible request in a bounded drain phase.
    function drainEligibleRequests() public {
        _settleFinishedProfit();
        for (uint256 i; i < _requestIds.length; ++i) {
            AlphaEngineUSDCVaultManager.RedemptionRequest memory r =
                MANAGER.getRedemption(_requestIds[i]);
            if (r.status != AlphaEngineUSDCVaultManager.RedemptionStatus.Pending) continue;
            uint256 quote = MANAGER.previewRedeem(r.shares);
            uint256 remainingSupply = FUND_VAULT.totalSupply() - r.shares;
            uint256 required = remainingSupply == 0 ? ghostManagedAssets : quote;
            if (
                (r.shares == FUND_VAULT.totalSupply() && MANAGER.remainingLockedProfit() != 0)
                    || (remainingSupply != 0 && remainingSupply < MANAGER.MIN_SHARE_SUPPLY())
                    || quote < r.minAssets || required > USDC.balanceOf(address(FUND_VAULT))
            ) continue;
            completeRedeem(i);
            assertEq(
                uint256(MANAGER.getRedemption(_requestIds[i]).status),
                uint256(AlphaEngineUSDCVaultManager.RedemptionStatus.Completed)
            );
            ++drainedRequests;
        }
        _checkModelParity();
    }

    function lifecycleStateHash() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                _claimsHash(),
                MANAGER.managedAssets(),
                MANAGER.lockedProfit(),
                MANAGER.lockedRecoveryProfit(),
                MANAGER.lossToRecover(),
                MANAGER.profitLockTimestamp(),
                MANAGER.profitUnlockTimestamp(),
                MANAGER.reportEpoch(),
                MANAGER.lastReferenceBlock(),
                MANAGER.nextRedemptionId(),
                MANAGER.feeRecipient(),
                MANAGER.navReporter(),
                MANAGER.vestingPeriod(),
                MANAGER.performanceFeeBps()
            )
        );
    }

    function _claimsHash() private view returns (bytes32 h) {
        h = keccak256(
            abi.encode(
                FUND_VAULT.totalSupply(),
                USDC.balanceOf(address(FUND_VAULT)),
                USDC.balanceOf(STRATEGY)
            )
        );
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            h = keccak256(
                abi.encode(h, FUND_VAULT.balanceOf(_actors[i]), USDC.balanceOf(_actors[i]))
            );
        }
        h = keccak256(
            abi.encode(
                h,
                FUND_VAULT.balanceOf(address(FUND_VAULT)),
                FUND_VAULT.balanceOf(FEE_RECIPIENT),
                FUND_VAULT.balanceOf(SECOND_FEE_RECIPIENT)
            )
        );
        for (uint256 i; i < _requestIds.length; ++i) {
            h = keccak256(abi.encode(h, MANAGER.getRedemption(_requestIds[i])));
        }
    }

    /// @notice FV-01/FV-03/FV-04/FV-05/FV-10/FV-11/FV-30: relative economic stress after prior actions.
    /// Complete a legitimate cohort, then vary deposits, residual atomic supply and fee-bearing exits.
    function economicStress(uint96 initialRaw, uint96 profitRaw, uint16 residualSeed, uint8 kind)
        public
    {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _closeCohort();
        uint256 initial = bound(initialRaw, 100e6, 1_000_000e6);
        uint256 profit = bound(profitRaw, initial / 2, 2 * initial);
        uint8 mode = kind % 3;
        address owner = MANAGER.owner();
        vm.prank(owner);
        MANAGER.setPerformanceFeeBps(mode == 0 ? 0 : 2000);
        vm.prank(owner);
        MANAGER.setVestingPeriod(100);
        if (mode == 1) {
            // A large early exit, B stays: no loss, no transfers, no later entrants.
            uint256 alice = initial * bound(residualSeed, 90, 99) / 100;
            deposit(0, uint96(alice));
            deposit(1, uint96(initial - alice));
            reportProfit(uint96(profit));
            vm.warp(MANAGER.profitLockTimestamp() + 99);
            _request(actorAt(0), actorAt(0), FUND_VAULT.balanceOf(actorAt(0)), 0);
            completeRedeem(_requestIds.length - 1);
            advanceToVestBoundary(1);
            _settleFinishedProfit();
        } else {
            deposit(0, uint96(initial));
            reportProfit(uint96(profit));
            if (mode == 2) vm.warp(MANAGER.profitLockTimestamp() + 99);
            uint256 residual = mode == 0
                ? uint256(
                    residualSeed % 5 == 0
                        ? 1
                        : (residualSeed % 5 == 1
                                ? 2
                                : (residualSeed % 5 == 2
                                        ? 1e12 - 1
                                        : (residualSeed % 5 == 3 ? 1e12 : 1e18)))
                )
                : FUND_VAULT.totalSupply() / 100;
            if (residual >= FUND_VAULT.balanceOf(actorAt(0))) residual = 1;
            uint256 totalRemainder =
                FUND_VAULT.totalSupply() - FUND_VAULT.balanceOf(actorAt(0)) + residual;
            if (totalRemainder < MANAGER.MIN_SHARE_SUPPLY()) {
                _request(actorAt(0), actorAt(0), FUND_VAULT.balanceOf(actorAt(0)) - residual, 0);
                attemptGuardedCompletion(_requestIds.length - 1);
                cancelRedeem(_requestIds.length - 1);
                residual += MANAGER.MIN_SHARE_SUPPLY() - totalRemainder;
            }
            _request(actorAt(0), actorAt(0), FUND_VAULT.balanceOf(actorAt(0)) - residual, 0);
            completeRedeem(_requestIds.length - 1);
            advanceToVestBoundary(1);
            _settleFinishedProfit();
            if (mode == 0) roundTrip(1, uint96(profit + profit * 99 / 100), 0);
        }
        _checkModelParity();
    }

    /// @notice FV-04/FV-06: rejected dust bootstrap, tiny funded entry, total loss and re-entry.
    function exerciseZeroAndTinyLifecycle(uint8 branch, uint96 rawInitial) public {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _prepareCohort(0, 100);
        deposit(0, uint96(branch % 2 == 0 ? 1 : 1e6 - 1));
        assertEq(FUND_VAULT.totalSupply(), 0);
        uint256 initial = bound(rawInitial, 1e6, MAX_ACTION_ASSETS);
        uint256 first = successfulDeposits;
        deposit(0, uint96(initial));
        assertEq(successfulDeposits, first + 1);
        assertEq(FUND_VAULT.balanceOf(actorAt(0)), initial * 1e12);
        ++scenarioRuns[4];
        if (branch % 3 == 0) {
            reportProfit(1);
            deposit(1, 1);
            assertEq(FUND_VAULT.balanceOf(actorAt(1)), 1e12);
            reportLoss(1); // Cancels the single locked unit; neither investor loses principal.
            assertEq(MANAGER.availableAssets(), initial + 1);
        }
        // A zero-value terminal exit still needs the entire global supply; consolidate Bob's dust.
        uint256 tiny = FUND_VAULT.balanceOf(actorAt(1));
        if (tiny != 0) {
            vm.prank(actorAt(1));
            FUND_VAULT.transfer(actorAt(0), tiny);
            ghostShares[actorAt(1)] -= tiny;
            ghostShares[actorAt(0)] += tiny;
        }
        uint256 supply = FUND_VAULT.totalSupply();
        uint256 aliceShares = FUND_VAULT.balanceOf(actorAt(0));
        _request(actorAt(0), actorAt(1), aliceShares, 1);
        uint256 protectedRequest = _requestIds.length - 1;
        reportLoss(uint96(MANAGER.managedAssets()));
        assertEq(MANAGER.managedAssets(), 0);
        assertEq(MANAGER.availableAssets(), 0);
        assertEq(FUND_VAULT.totalSupply(), supply);
        attemptGuardedCompletion(protectedRequest);
        cancelRedeem(protectedRequest);
        // Existing worthless shares cannot silently revive from a new deposit.
        deposit(2, 1);
        _request(actorAt(0), actorAt(0), FUND_VAULT.balanceOf(actorAt(0)), 0);
        uint256 cancelled = _requestIds.length - 1;
        cancelRedeem(cancelled);
        _request(actorAt(0), actorAt(0), FUND_VAULT.balanceOf(actorAt(0)), 0);
        uint256 completed = _requestIds.length - 1;
        uint256 paidBefore = ghostPaidOnBehalfOfOwner[actorAt(0)];
        completeRedeem(completed);
        assertEq(ghostPaidOnBehalfOfOwner[actorAt(0)], paidBefore);
        attemptTerminalReplay(completed);
        uint256 bobShares = FUND_VAULT.balanceOf(actorAt(1));
        if (bobShares != 0) {
            _request(actorAt(1), actorAt(1), bobShares, 0);
            completeRedeem(_requestIds.length - 1);
        }
        assertEq(FUND_VAULT.totalSupply(), 0);
        assertEq(MANAGER.lossToRecover(), 0);
        deposit(2, 1);
        assertEq(FUND_VAULT.totalSupply(), 0);
        deposit(2, 1e6);
        assertEq(FUND_VAULT.balanceOf(actorAt(2)), 1e18);
        _closeCohort();
        ++scenarioRuns[6];
    }

    /// @notice FV-07: A owns recognized early gain; B and C only share vesting after their own entry.
    function exerciseStaggeredEntrants(uint96 rawInitial, uint32 rawProfit, uint96 rawLater)
        public
    {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _prepareCohort(0, 100);
        uint256 initial = bound(rawInitial, 2e6, MAX_ACTION_ASSETS);
        uint256 later = bound(rawLater, 2e6, MAX_ACTION_ASSETS);
        uint256 profit = (uint256(rawProfit) % 10_000 + 1) * 100;
        deposit(0, uint96(initial));
        reportProfit(uint96(profit));
        uint256 started = MANAGER.profitLockTimestamp();
        vm.warp(started + 50);
        uint256 aliceShares = FUND_VAULT.balanceOf(actorAt(0));
        uint256 aliceBefore = modelPreviewRedeem(FUND_VAULT.balanceOf(actorAt(0)));
        deposit(1, uint96(later));
        uint256 bobShares = FUND_VAULT.balanceOf(actorAt(1));
        uint256 supply = aliceShares + bobShares;
        uint256 recognized = initial + later + profit / 2;
        uint256 aliceClaim = Math.mulDiv(aliceShares, recognized + 1, supply + 1e12);
        uint256 bobClaim = Math.mulDiv(bobShares, recognized + 1, supply + 1e12);
        if (aliceClaim + 1 < aliceBefore || bobClaim > later || bobClaim + 1 < later) {
            actorEntitlementViolation = true;
        }
        vm.warp(started + 99);
        uint256 expectedAlice =
            aliceBefore + Math.mulDiv(profit * 49 / 100, aliceShares, supply + 1e12);
        uint256 paidBefore = ghostPaidOnBehalfOfOwner[actorAt(0)];
        _request(actorAt(0), actorAt(0), aliceShares, 0);
        completeRedeem(_requestIds.length - 1);
        _checkAssetBudget(ghostPaidOnBehalfOfOwner[actorAt(0)] - paidBefore, expectedAlice, 3);
        uint256 bobRecognizedBefore = modelPreviewRedeem(bobShares);
        deposit(2, uint96(later));
        uint256 carolShares = FUND_VAULT.balanceOf(actorAt(2));
        uint256 finalSupply = bobShares + carolShares;
        uint256 expectedBob =
            bobRecognizedBefore + Math.mulDiv(profit / 100, bobShares, finalSupply + 1e12);
        uint256 expectedCarol = modelPreviewRedeem(carolShares)
            + Math.mulDiv(profit / 100, carolShares, finalSupply + 1e12);
        vm.warp(started + 100);
        uint256 bobPaidBefore = ghostPaidOnBehalfOfOwner[actorAt(1)];
        _request(actorAt(1), actorAt(1), bobShares, 0);
        completeRedeem(_requestIds.length - 1);
        _checkAssetBudget(ghostPaidOnBehalfOfOwner[actorAt(1)] - bobPaidBefore, expectedBob, 4);
        uint256 carolPaidBefore = ghostPaidOnBehalfOfOwner[actorAt(2)];
        _request(actorAt(2), actorAt(2), carolShares, 0);
        completeRedeem(_requestIds.length - 1);
        _checkAssetBudget(ghostPaidOnBehalfOfOwner[actorAt(2)] - carolPaidBefore, expectedCarol, 4);
        assertEq(MANAGER.managedAssets(), 0);
        ++scenarioRuns[7];
    }

    /// @notice FV-08/FV-13: early partial exit, new money and loss around remaining locked gain.
    function exerciseExitEntryAndRelativeLoss(uint96 rawInitial, uint32 rawProfit, uint8 boundary)
        public
    {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _prepareCohort(0, 100);
        uint256 initial = bound(rawInitial, 2e6, MAX_ACTION_ASSETS);
        uint256 profit = uint256(rawProfit) % 1e9 + 100;
        deposit(0, uint96(initial));
        reportProfit(uint96(profit));
        vm.warp(MANAGER.profitLockTimestamp() + 40);
        _request(actorAt(0), actorAt(0), FUND_VAULT.balanceOf(actorAt(0)) / 2, 0);
        completeRedeem(_requestIds.length - 1);
        deposit(1, uint96(initial));
        uint256 locked = MANAGER.remainingLockedProfit();
        uint256 recognized = MANAGER.availableAssets();
        uint256 loss = boundary % 3 == 0 ? locked - 1 : boundary % 3 == 1 ? locked : locked + 1;
        reportLoss(uint96(loss));
        assertEq(MANAGER.remainingLockedProfit(), loss >= locked ? 0 : locked - loss);
        assertEq(MANAGER.availableAssets(), recognized - (loss > locked ? loss - locked : 0));
        assertEq(MANAGER.lossToRecover(), loss > locked ? loss - locked : 0);
        uint256 unlock = MANAGER.profitUnlockTimestamp();
        if (unlock > block.timestamp) vm.warp(unlock);
        _settleFinishedProfit();
        _closeCohort();
        deposit(boundary, uint96(initial));
        ++scenarioRuns[8];
    }

    /// @notice FV-09/FV-12: the full-supply guard is atomic before unlock; the exact-boundary exit progresses.
    function exerciseFinalExitGuard(uint96 rawInitial, uint32 rawProfit, bool chargeFee) public {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _prepareCohort(chargeFee ? 2000 : 0, 100);
        deposit(0, uint96(bound(rawInitial, 2e6, MAX_ACTION_ASSETS)));
        reportProfit(uint96(uint256(rawProfit) % 1e6 + 100));
        uint256 feeShares = FUND_VAULT.balanceOf(MANAGER.feeRecipient());
        if (feeShares != 0) {
            vm.prank(MANAGER.feeRecipient());
            FUND_VAULT.transfer(actorAt(0), feeShares);
            ghostShares[MANAGER.feeRecipient()] -= feeShares;
            ghostShares[actorAt(0)] += feeShares;
            feeCohortActive = false;
        }
        _request(actorAt(0), actorAt(0), FUND_VAULT.balanceOf(actorAt(0)), 0);
        uint256 id = _requestIds.length - 1;
        attemptGuardedCompletion(id);
        vm.warp(MANAGER.profitUnlockTimestamp() - 1);
        attemptGuardedCompletion(id);
        vm.warp(MANAGER.profitUnlockTimestamp());
        _settleFinishedProfit();
        completeRedeem(id);
        assertEq(
            uint256(MANAGER.getRedemption(_requestIds[id]).status),
            uint256(AlphaEngineUSDCVaultManager.RedemptionStatus.Completed)
        );
        _closeCohort();
        ++scenarioRuns[9];
    }

    /// @notice FV-13: exact relative loss, issued fee-share ownership and fee-free recovery.
    function exerciseFeeLossBoundaries(uint96 rawInitial, uint32 rawProfit, uint8 edge) public {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _prepareCohort(2000, 100);
        uint256 initial = bound(rawInitial, 2e6, MAX_ACTION_ASSETS);
        uint256 profit = (uint256(rawProfit) % 10_000 + 1) * 100;
        deposit(0, uint96(initial));
        reportProfit(uint96(profit));
        uint256 elapsed = (edge / 3) % 3 == 0 ? 0 : (edge / 3) % 3 == 1 ? 50 : 99;
        vm.warp(MANAGER.profitLockTimestamp() + elapsed);
        uint256 locked = Math.mulDiv(profit - profit / 5, 100 - elapsed, 100, Math.Rounding.Ceil);
        uint256 loss = edge % 3 == 0 ? locked - 1 : edge % 3 == 1 ? locked : locked + 1;
        uint256 mintedFeeShares = FUND_VAULT.balanceOf(MANAGER.feeRecipient());
        uint256 recognizedBefore = MANAGER.availableAssets();
        uint256 managedBefore = MANAGER.managedAssets();
        if (loss == 0) _attemptZeroReport(false);
        else reportLoss(uint96(loss));
        assertEq(MANAGER.managedAssets(), managedBefore - loss);
        assertEq(MANAGER.availableAssets(), recognizedBefore - (loss > locked ? loss - locked : 0));
        assertEq(MANAGER.lossToRecover(), loss > locked ? loss - locked : 0);
        if (loss < locked) {
            attemptProfitOverwrite(1);
            vm.warp(MANAGER.profitUnlockTimestamp());
            _settleFinishedProfit();
        }
        assertEq(FUND_VAULT.balanceOf(MANAGER.feeRecipient()), mintedFeeShares);
        uint256 recover = MANAGER.lossToRecover();
        reportProfit(uint96(recover + 100));
        assertEq(MANAGER.lossToRecover(), 0);
        assertGt(FUND_VAULT.balanceOf(MANAGER.feeRecipient()), mintedFeeShares);
        vm.warp(MANAGER.profitUnlockTimestamp());
        _settleFinishedProfit();
        _closeCohort();
        ++scenarioRuns[13];
    }

    /// @notice FV-14: loss allocation is immediate for remaining owners across entry/exit orderings.
    function exerciseLossTiming(uint96 rawInitial, uint32 rawLoss, bool enterBeforeLoss) public {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _prepareCohort(0, 100);
        uint256 initial = bound(rawInitial, 2e6, MAX_ACTION_ASSETS);
        deposit(0, uint96(initial));
        deposit(1, uint96(initial));
        uint256 beforeExitCash = ghostPaidOnBehalfOfOwner[actorAt(0)];
        _request(actorAt(0), actorAt(0), FUND_VAULT.balanceOf(actorAt(0)) / 2, 0);
        completeRedeem(_requestIds.length - 1);
        _checkAssetBudget(ghostPaidOnBehalfOfOwner[actorAt(0)] - beforeExitCash, initial / 2, 1);
        if (enterBeforeLoss) deposit(2, uint96(initial));
        uint256 beforeNav = MANAGER.availableAssets();
        uint256 supply = FUND_VAULT.totalSupply();
        uint256[ACTOR_COUNT] memory claimsBefore;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            claimsBefore[i] = Math.mulDiv(ownedShares(actorAt(i)), beforeNav, supply);
        }
        uint256 loss = uint256(rawLoss) % (beforeNav - 1) + 1;
        reportLoss(uint96(loss));
        assertEq(MANAGER.availableAssets(), beforeNav - loss);
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            uint256 claim = Math.mulDiv(ownedShares(actorAt(i)), MANAGER.availableAssets(), supply);
            uint256 allocatedLoss = Math.mulDiv(loss, ownedShares(actorAt(i)), supply);
            if (claim > claimsBefore[i] || claimsBefore[i] - claim > allocatedLoss + 1) {
                actorEntitlementViolation = true;
            }
        }
        if (!enterBeforeLoss) deposit(2, uint96(initial));
        _request(actorAt(0), actorAt(0), FUND_VAULT.balanceOf(actorAt(0)), 0);
        completeRedeem(_requestIds.length - 1);
        _request(actorAt(1), actorAt(1), FUND_VAULT.balanceOf(actorAt(1)), 0);
        completeRedeem(_requestIds.length - 1);
        _closeCohort();
        ++scenarioRuns[14];
    }

    /// @notice FV-15: redemption scales fund-level deficit, new money does not, recovery remains fee-free.
    function exerciseRecoveryAndFreshMoney(uint96 rawInitial, uint32 rawLoss, uint16 split) public {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _prepareCohort(2000, 100);
        uint256 initial = bound(rawInitial, 2e6, MAX_ACTION_ASSETS);
        deposit(0, uint96(initial));
        uint256 loss = uint256(rawLoss) % (initial - 1) + 1;
        reportLoss(uint96(loss));
        uint256 supply = FUND_VAULT.totalSupply();
        uint256 exiting = supply * (uint256(split) % 50 + 1) / 100;
        _request(actorAt(0), actorAt(0), exiting, 0);
        completeRedeem(_requestIds.length - 1);
        uint256 deficit = (loss * (supply - exiting) + supply - 1) / supply;
        assertEq(MANAGER.lossToRecover(), deficit);
        deposit(1, uint96(initial));
        assertEq(MANAGER.lossToRecover(), deficit);
        uint256 firstRecovery = uint256(split) % deficit + 1;
        reportProfit(uint96(firstRecovery));
        assertEq(MANAGER.lossToRecover(), deficit - firstRecovery);
        vm.warp(MANAGER.profitUnlockTimestamp());
        _settleFinishedProfit();
        uint256 remaining = deficit - firstRecovery;
        uint256 feeable = uint256(rawLoss) % (MAX_ACTION_ASSETS - remaining) + 1;
        uint256 feeSharesBefore = FUND_VAULT.balanceOf(MANAGER.feeRecipient());
        uint256 expectedNewShares =
            Math.mulDiv(feeable / 5, ghostShareSupply + 1e12, modelAvailableAssets() + 1);
        reportProfit(uint96(remaining + feeable));
        assertEq(MANAGER.lossToRecover(), 0);
        assertEq(FUND_VAULT.balanceOf(MANAGER.feeRecipient()) - feeSharesBefore, expectedNewShares);
        vm.warp(MANAGER.profitUnlockTimestamp());
        _settleFinishedProfit();
        _closeCohort();
        ++scenarioRuns[15];
    }

    /// @notice FV-28: repeated daily reports/fee changes preserve eligible partial-exit progress.
    function exerciseDailyReportsAndExitProgress(uint96 rawInitial, uint16 rawDays, uint8 ordering)
        public
    {
        if (MANAGER.paused() || FUND_VAULT.paused()) return;
        _prepareCohort(0, 1 days);
        uint256 initial = bound(rawInitial, 1e6, MAX_ACTION_ASSETS);
        deposit(0, uint96(initial));
        deposit(1, uint96(initial));
        uint256 daysCount = uint256(rawDays) % 5 + 3;
        for (uint256 day; day < daysCount; ++day) {
            uint256 profit = initial / 1000 + day + 1;
            reportProfit(uint96(profit));
            uint256 start = MANAGER.profitLockTimestamp();
            uint256 shares = FUND_VAULT.balanceOf(actorAt(0)) / (daysCount + 2);
            assertGt(shares, 0);
            _request(actorAt(0), actorAt(ordering % ACTOR_COUNT), shares, 0);
            uint256 requestIndex = _requestIds.length - 1;
            vm.warp(start + 12 hours);
            attemptProfitOverwrite(uint96(profit));
            if ((ordering + day) % 2 == 0) {
                completeRedeem(requestIndex);
                assertEq(
                    uint256(MANAGER.getRedemption(_requestIds[requestIndex]).status),
                    uint256(AlphaEngineUSDCVaultManager.RedemptionStatus.Completed)
                );
                ++dailyExitProgress;
            }
            if ((ordering + day) % 3 == 0) reportLoss(1);
            // Rate updates are prospective; even a fresh report at the exact boundary cannot block a partial exit.
            vm.prank(MANAGER.owner());
            MANAGER.setPerformanceFeeBps(uint16((ordering + day) % 3) * 1000);
            vm.warp(start + 1 days);
            _settleFinishedProfit();
            if (
                MANAGER.getRedemption(_requestIds[requestIndex]).status
                    == AlphaEngineUSDCVaultManager.RedemptionStatus.Pending
            ) {
                completeRedeem(requestIndex);
                assertEq(
                    uint256(MANAGER.getRedemption(_requestIds[requestIndex]).status),
                    uint256(AlphaEngineUSDCVaultManager.RedemptionStatus.Completed)
                );
                ++dailyExitProgress;
            }
            _checkModelParity();
        }
        _closeCohort();
        ++scenarioRuns[28];
    }

    function _attemptZeroReport(bool profit) private {
        (uint64 epoch, uint64 referenceBlock) = _nextReport();
        bytes32 beforeState = lifecycleStateHash();
        address reporter = MANAGER.navReporter();
        vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroAssets.selector);
        vm.prank(reporter);
        if (profit) MANAGER.reportProfit(epoch, referenceBlock, 0, bytes32(uint256(1)));
        else MANAGER.reportLoss(epoch, referenceBlock, 0, bytes32(uint256(1)));
        assertEq(lifecycleStateHash(), beforeState);
        ++rejectedActions;
    }

    function _prepareCohort(uint16 fee, uint64 vest) private {
        _closeCohort();
        vm.prank(MANAGER.owner());
        MANAGER.setPerformanceFeeBps(fee);
        vm.prank(MANAGER.owner());
        MANAGER.setVestingPeriod(vest);
    }

    function _checkAssetBudget(uint256 actual, uint256 expected, uint256 budget) private {
        if (actual > expected ? actual - expected > budget : expected - actual > budget) {
            actorEntitlementViolation = true;
        }
    }

    function _closeCohort() private {
        uint256 unlock = MANAGER.profitUnlockTimestamp();
        if (unlock > block.timestamp) vm.warp(unlock);
        _settleFinishedProfit();
        uint256 deployed = USDC.balanceOf(STRATEGY);
        if (deployed != 0) returnLiquidity(uint96(deployed));
        for (uint256 i; i < _requestIds.length; ++i) {
            if (
                MANAGER.getRedemption(_requestIds[i]).status
                    == AlphaEngineUSDCVaultManager.RedemptionStatus.Pending
            ) {
                cancelRedeem(i);
            }
        }
        address recipient = actorAt(0);
        for (uint256 i = 1; i < ACTOR_COUNT + 2; ++i) {
            address from = i < ACTOR_COUNT
                ? _actors[i]
                : (i == ACTOR_COUNT ? FEE_RECIPIENT : SECOND_FEE_RECIPIENT);
            uint256 shares = FUND_VAULT.balanceOf(from);
            if (shares == 0) continue;
            vm.prank(from);
            FUND_VAULT.transfer(recipient, shares);
            ghostShares[from] -= shares;
            ghostShares[recipient] += shares;
        }
        feeCohortActive = false;
        uint256 supply = FUND_VAULT.totalSupply();
        if (supply != 0) {
            _request(recipient, recipient, supply, 0);
            completeRedeem(_requestIds.length - 1);
        }
        assertEq(FUND_VAULT.totalSupply(), 0);
        assertEq(MANAGER.managedAssets(), 0);
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
        total += FUND_VAULT.balanceOf(SECOND_FEE_RECIPIENT);
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

    function modelEffectiveSupply() public view returns (uint256) {
        return ghostShareSupply;
    }

    function modelPreviewDeposit(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, ghostShareSupply + 1e12, modelAvailableAssets() + 1);
    }

    function modelPreviewRedeem(uint256 shares) public view returns (uint256) {
        if (ghostShareSupply == 0) return 0;
        return Math.mulDiv(shares, modelAvailableAssets() + 1, ghostShareSupply + 1e12);
    }

    function _applyModelLoss(uint256 loss) private {
        uint256 remainingProfit = modelRemainingLockedProfit();
        uint256 remainingRecovery = modelRemainingLockedRecoveryProfit();
        uint256 cancelledProfit = Math.min(loss, remainingProfit);
        uint256 cancelledFeeable = Math.min(cancelledProfit, remainingProfit - remainingRecovery);
        uint256 cancelledRecovery = cancelledProfit - cancelledFeeable;
        ghostLockedProfit = remainingProfit - cancelledProfit;
        ghostLockedRecoveryProfit = remainingRecovery - cancelledRecovery;
        ghostLossToRecover += cancelledRecovery + loss - cancelledProfit;
        if (ghostLockedProfit == 0) {
            ghostLockedRecoveryProfit = 0;
            ghostProfitLockTimestamp = 0;
            ghostProfitUnlockTimestamp = 0;
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

    function ownedShares(address actor) public view returns (uint256) {
        return ghostShares[actor] + ghostPendingShares[actor];
    }

    /// @dev Full archive audit after each fuzzed action; transitions also check their changed request immediately.
    function requestHistoryMatchesModel() external view returns (bool) {
        uint256[ACTOR_COUNT] memory pending;
        for (uint256 i; i < _requestIds.length; ++i) {
            uint64 id = _requestIds[i];
            AlphaEngineUSDCVaultManager.RedemptionRequest memory r = MANAGER.getRedemption(id);
            if (!_requestMatchesModel(id, r)) return false;
            if (r.status == AlphaEngineUSDCVaultManager.RedemptionStatus.Pending) {
                bool trackedOwner;
                for (uint256 j; j < ACTOR_COUNT; ++j) {
                    if (r.owner == _actors[j]) {
                        pending[j] += r.shares;
                        trackedOwner = true;
                        break;
                    }
                }
                if (!trackedOwner) return false;
            }
        }
        uint256 totalPending;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            if (pending[i] != ghostPendingShares[_actors[i]]) return false;
            totalPending += pending[i];
        }
        return totalPending == ghostShares[address(FUND_VAULT)];
    }

    function _requestMatchesModel(uint64 id, AlphaEngineUSDCVaultManager.RedemptionRequest memory r)
        private
        view
        returns (bool)
    {
        return ghostRequestBinding[id]
                == keccak256(abi.encode(r.owner, r.receiver, r.shares, r.minAssets))
            && ghostRequestStatus[id] == r.status;
    }

    function _checkRequestParity(uint64 id) private {
        if (!_requestMatchesModel(id, MANAGER.getRedemption(id))) actorLedgerViolation = true;
    }

    function _checkModelParity() private {
        if (feeCohortActive && ghostShareSupply != 0) {
            for (uint256 i; i < ACTOR_COUNT; ++i) {
                uint256 wealth = ghostPaidOnBehalfOfOwner[_actors[i]]
                    + modelPreviewRedeem(ownedShares(_actors[i]));
                // One unit per bounded floor operation, not a share-price-dependent tolerance.
                uint256 roundingBudget = 2 * (successfulCompletions + successfulDeposits + 1);
                if (wealth + roundingBudget < cohortPrincipal[i]) feeCohortViolation = true;
            }
        }
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address actor = _actors[i];
            if (
                FUND_VAULT.balanceOf(actor) != ghostShares[actor]
                    || USDC.balanceOf(actor) != ghostCashReceived[actor]
            ) actorLedgerViolation = true;
        }
        if (
            FUND_VAULT.balanceOf(address(FUND_VAULT)) != ghostShares[address(FUND_VAULT)]
                || FUND_VAULT.balanceOf(FEE_RECIPIENT) != ghostShares[FEE_RECIPIENT]
                || FUND_VAULT.balanceOf(SECOND_FEE_RECIPIENT) != ghostShares[SECOND_FEE_RECIPIENT]
        ) {
            actorLedgerViolation = true;
        }
        if (
            MANAGER.managedAssets() != ghostManagedAssets
                || MANAGER.lockedProfit() != ghostLockedProfit
                || MANAGER.lockedRecoveryProfit() != ghostLockedRecoveryProfit
                || MANAGER.lossToRecover() != ghostLossToRecover
                || MANAGER.profitLockTimestamp() != ghostProfitLockTimestamp
                || MANAGER.profitUnlockTimestamp() != ghostProfitUnlockTimestamp
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
