// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {AlphaEngineUSDCVaultManager} from "src/vault/AlphaEngineUSDCVaultManager.sol";
import {USDCVaultInvariantHandler} from "test/handlers/USDCVaultInvariantHandler.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {
    MockFundVaultExecutionManager,
    MockRecoveryVault
} from "test/mocks/MockFundVaultExecution.sol";

contract AlphaEngineUSDCVaultManagerInvariantTest is StdInvariant, Test {
    address private constant FEE_RECIPIENT = address(0xFEE);
    address private constant STRATEGY = address(0x5151);

    MockERC20 private usdc;
    AlphaEngineFundVault private fundVault;
    AlphaEngineUSDCVaultManager private manager;
    USDCVaultInvariantHandler private handler;

    function setUp() public {
        vm.roll(100);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        fundVault = new AlphaEngineFundVault(address(this), usdc);
        manager = new AlphaEngineUSDCVaultManager(
            address(this),
            usdc,
            IAlphaEngineFundVault(address(fundVault)),
            address(this),
            FEE_RECIPIENT,
            1 days,
            1000
        );
        handler = new USDCVaultInvariantHandler(usdc, fundVault, manager, FEE_RECIPIENT, STRATEGY);

        fundVault.setUsdcManager(address(manager));
        fundVault.setExecutionManager(address(new MockFundVaultExecutionManager(address(this))));
        fundVault.setEmergencyConfiguration(address(this), address(new MockRecoveryVault()));
        fundVault.unpause();
        manager.setNavReporter(address(handler));
        manager.unpause();

        handler.deposit(0, 1000e6);
        handler.requestRedeem(0, 100e18);
        handler.cancelRedeem(0);
        handler.requestRedeem(0, 100e18);
        handler.completeRedeem(0);
        handler.reportProfit(100e6);
        handler.advanceTime(1 days);
        handler.settleFinishedProfit();
        handler.reportLoss(10e6);

        // Seed actual governance/rejection/transfer/round-trip transitions as well as the original cash paths.
        handler.transferShares(0, 1e18, true);
        handler.requestWithMinimum(1, 1e17, 2);
        handler.attemptGuardedCompletion(2);
        handler.configureAccounting(1500, 2 days, true);
        handler.rotateReporter(true);
        handler.configurePause(true, true);
        handler.deposit(0, 1e6);
        handler.configurePause(false, false);
        handler.handoverOwners(true);
        handler.roundTrip(2, 100e6, 0);
        handler.redeemAndReinvest(0, 1e18, 0);

        handler.exerciseZeroAndTinyLifecycle(0, 1);
        handler.exerciseStaggeredEntrants(1000e6, 1000, 500e6);
        handler.exerciseExitEntryAndRelativeLoss(1000e6, 100e6, 1);
        handler.exerciseFinalExitGuard(1000e6, 100e6, true);
        handler.exerciseFeeLossBoundaries(1000e6, 1000, 4);
        handler.exerciseLossTiming(1000e6, 100e6, false);
        handler.exerciseRecoveryAndFreshMoney(1000e6, 100e6, 20);
        handler.exerciseDailyReportsAndExitProgress(1000e6, 0, 1);

        bytes4[] memory selectors = new bytes4[](35);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.requestRedeem.selector;
        selectors[2] = handler.cancelRedeem.selector;
        selectors[3] = handler.completeRedeem.selector;
        selectors[4] = handler.attemptIlliquidCompletion.selector;
        selectors[5] = handler.reportProfit.selector;
        selectors[6] = handler.reportLoss.selector;
        selectors[7] = handler.advanceTime.selector;
        selectors[8] = handler.settleFinishedProfit.selector;
        selectors[9] = handler.deployLiquidity.selector;
        selectors[10] = handler.returnLiquidity.selector;
        selectors[11] = handler.donate.selector;
        selectors[12] = handler.requestWithMinimum.selector;
        selectors[13] = handler.requestResidualExit.selector;
        selectors[14] = handler.roundTrip.selector;
        selectors[15] = handler.attemptGuardedCompletion.selector;
        selectors[16] = handler.attemptTerminalReplay.selector;
        selectors[17] = handler.transferShares.selector;
        selectors[18] = handler.configureAccounting.selector;
        selectors[19] = handler.rotateReporter.selector;
        selectors[20] = handler.configurePause.selector;
        selectors[21] = handler.handoverOwners.selector;
        selectors[22] = handler.attemptProfitOverwrite.selector;
        selectors[23] = handler.advanceToVestBoundary.selector;
        selectors[24] = handler.drainEligibleRequests.selector;
        selectors[25] = handler.economicStress.selector;
        selectors[26] = handler.exerciseZeroAndTinyLifecycle.selector;
        selectors[27] = handler.exerciseStaggeredEntrants.selector;
        selectors[28] = handler.exerciseExitEntryAndRelativeLoss.selector;
        selectors[29] = handler.exerciseFinalExitGuard.selector;
        selectors[30] = handler.exerciseFeeLossBoundaries.selector;
        selectors[31] = handler.exerciseLossTiming.selector;
        selectors[32] = handler.exerciseRecoveryAndFreshMoney.selector;
        selectors[33] = handler.exerciseDailyReportsAndExitProgress.selector;
        selectors[34] = handler.redeemAndReinvest.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_FV_replaysFeeLossRoundingBoundaries() public {
        // 100 units gross - 20 fee = 80 net; the final 1% is 0.8 units,
        // so one unit remains locked. Exercise loss below/at/above that unit.
        uint256 before = handler.scenarioRuns(13);
        for (uint8 edge = 6; edge <= 8; ++edge) {
            handler.exerciseFeeLossBoundaries(1000e6, 0, edge);
            invariant_independentAccountingModelMatchesEveryReachableState();
        }
        assertEq(handler.scenarioRuns(13), before + 3);
    }

    function test_FV_replaysLongRoundTripCounterexample() public {
        handler.exerciseExitEntryAndRelativeLoss(type(uint96).max, 1, 8);
        uint256 before = handler.roundTrips();
        handler.roundTrip(
            232_252_764_209_307_188_295_952_445_350_777_503_742_124_612_188_346_098_122_753,
            10_672,
            35
        );
        assertEq(handler.roundTrips(), before + 100);
        invariant_FV02_roundTripsPreservePrincipalWithinAssetRoundingBudget();
        invariant_FV_actorSharesCashAndRequestOwnershipReconcile();
        invariant_independentAccountingModelMatchesEveryReachableState();
    }

    function test_FV_longReinvestmentKeepsEveryEconomicCheck() public {
        handler.deposit(0, 100e6);
        uint256 before = handler.roundTrips();
        handler.redeemAndReinvest(0, 1e18, 2);
        assertEq(handler.roundTrips(), before + 100);
        invariant_FV02_roundTripsPreservePrincipalWithinAssetRoundingBudget();
        invariant_FV_actorSharesCashAndRequestOwnershipReconcile();
        invariant_independentAccountingModelMatchesEveryReachableState();
    }

    function test_FV_repeatedHundredCycleActionsKeepHistoryChecksBounded() public {
        handler.deposit(0, 1000e6);
        handler.deposit(1, 1000e6);
        uint256 before = handler.roundTrips();
        for (uint256 i; i < 3; ++i) {
            handler.roundTrip(i % 2, 100e6, 2);
        }
        assertEq(handler.roundTrips(), before + 300);
        invariant_FV02_roundTripsPreservePrincipalWithinAssetRoundingBudget();
        invariant_FV_actorSharesCashAndRequestOwnershipReconcile();
        invariant_independentAccountingModelMatchesEveryReachableState();
        invariant_actualUSDCIsConservedAcrossVaultAndStrategy();
    }

    function test_FV_largePendingCohortRetainsEveryRequestCheck() public {
        handler.deposit(0, 1000e6);
        for (uint256 i; i < 512; ++i) {
            handler.requestRedeem(0, 1e12);
        }
        invariant_FV_actorSharesCashAndRequestOwnershipReconcile();
        invariant_shareSupplyIsFullyAccountedFor();
        handler.exerciseZeroAndTinyLifecycle(0, 1);
        invariant_FV_actorSharesCashAndRequestOwnershipReconcile();
        invariant_independentAccountingModelMatchesEveryReachableState();
        invariant_actualUSDCIsConservedAcrossVaultAndStrategy();
    }

    function test_FV_archiveCheckDetectsOldAndPendingRequestMutation() public {
        assertTrue(handler.requestHistoryMatchesModel());
        uint64 oldId = handler.requestAt(0);
        AlphaEngineUSDCVaultManager.RedemptionRequest memory oldRequest =
            manager.getRedemption(oldId);
        assertTrue(oldRequest.status != AlphaEngineUSDCVaultManager.RedemptionStatus.Pending);
        oldRequest.receiver = address(0xBAD);
        vm.mockCall(
            address(manager), abi.encodeCall(manager.getRedemption, (oldId)), abi.encode(oldRequest)
        );
        assertFalse(handler.requestHistoryMatchesModel());
        vm.clearMockedCalls();

        handler.deposit(0, 100e6);
        handler.requestRedeem(0, 1e18);
        uint64 pendingId = handler.requestAt(handler.requestCount() - 1);
        AlphaEngineUSDCVaultManager.RedemptionRequest memory pendingRequest =
            manager.getRedemption(pendingId);
        assertEq(
            uint256(pendingRequest.status),
            uint256(AlphaEngineUSDCVaultManager.RedemptionStatus.Pending)
        );
        pendingRequest.shares += 1;
        vm.mockCall(
            address(manager),
            abi.encodeCall(manager.getRedemption, (pendingId)),
            abi.encode(pendingRequest)
        );
        assertFalse(handler.requestHistoryMatchesModel());
        vm.clearMockedCalls();
        assertTrue(handler.requestHistoryMatchesModel());
    }

    function invariant_managedAssetsMatchEveryAccountingDelta() public view {
        assertEq(manager.managedAssets(), handler.ghostManagedAssets());
        uint256 additions = handler.ghostDepositedUsdc() + handler.ghostReportedProfit();
        uint256 deductions = handler.ghostRedeemedUsdc() + handler.ghostProtocolResidual()
            + handler.ghostReportedLoss();
        assertGe(additions, deductions);
        assertEq(manager.managedAssets(), additions - deductions);
    }

    function invariant_shareSupplyIsFullyAccountedFor() public view {
        assertEq(fundVault.totalSupply(), handler.trackedShareSupply());
        assertEq(fundVault.balanceOf(address(fundVault)), handler.pendingRedemptionShares());
    }

    function invariant_actualUSDCIsConservedAcrossVaultAndStrategy() public view {
        uint256 inflows =
            handler.ghostDepositedUsdc() + handler.ghostDonations() + handler.ghostFundedProfit();
        uint256 outflows = handler.ghostRedeemedUsdc() + handler.ghostProtocolResidual()
            + handler.ghostFundedLoss();
        assertGe(inflows, outflows);
        assertEq(usdc.balanceOf(address(fundVault)) + usdc.balanceOf(STRATEGY), inflows - outflows);
        assertEq(usdc.balanceOf(STRATEGY), handler.ghostDeployedUsdc());
        assertEq(usdc.balanceOf(address(manager)), 0);
    }

    function invariant_lockedProfitAndRecoveryRemainBounded() public view {
        assertLe(manager.remainingLockedProfit(), manager.lockedProfit());
        assertLe(manager.remainingLockedProfit(), manager.managedAssets());
        assertLe(manager.remainingLockedRecoveryProfit(), manager.remainingLockedProfit());
        assertLe(manager.availableAssets(), manager.managedAssets());
    }

    function invariant_depositsAndRedemptionsNeverDiluteSharePrice() public view {
        assertFalse(handler.depositPriceViolation());
        assertFalse(handler.redemptionPriceViolation());
    }

    function invariant_performanceFeeNeverOvercharges() public view {
        assertFalse(handler.feeOverchargeViolation());
        assertFalse(handler.feeExactnessViolation());
        assertFalse(handler.feeSettlementPriceViolation());
        assertFalse(handler.lossRecoveryFlowViolation());
        assertLe(manager.performanceFeeBps(), manager.MAX_PERFORMANCE_FEE_BPS());
    }

    function invariant_independentAccountingModelMatchesEveryReachableState() public view {
        assertFalse(handler.accountingModelViolation());
        assertEq(manager.managedAssets(), handler.ghostManagedAssets());
        assertEq(manager.lockedProfit(), handler.ghostLockedProfit());
        assertEq(manager.lockedRecoveryProfit(), handler.ghostLockedRecoveryProfit());
        assertEq(manager.lossToRecover(), handler.ghostLossToRecover());
        assertEq(manager.profitLockTimestamp(), handler.ghostProfitLockTimestamp());
        assertEq(manager.profitUnlockTimestamp(), handler.ghostProfitUnlockTimestamp());
        assertEq(fundVault.totalSupply(), handler.ghostShareSupply());
        assertEq(manager.remainingLockedProfit(), handler.modelRemainingLockedProfit());
        assertEq(
            manager.remainingLockedRecoveryProfit(), handler.modelRemainingLockedRecoveryProfit()
        );
        assertEq(manager.availableAssets(), handler.modelAvailableAssets());
    }

    function invariant_failedIlliquidCompletionIsAtomic() public view {
        assertFalse(handler.failedCompletionMutation());
    }

    function invariant_reportsAreSequential() public view {
        assertEq(
            manager.reportEpoch(),
            handler.successfulProfitReports() + handler.successfulLossReports()
        );
    }

    function invariant_seededActionsPreventVacuousCoverage() public view {
        assertGt(handler.successfulDeposits(), 0);
        assertGt(handler.successfulRequests(), 0);
        assertGt(handler.successfulCancellations(), 0);
        assertGt(handler.successfulCompletions(), 0);
        assertGt(handler.successfulProfitReports(), 0);
        assertGt(handler.successfulLossReports(), 0);
        assertGt(handler.successfulFeeSettlements(), 0);
    }

    /// @notice FV-16/FV-17/FV-19/FV-25/FV-30: per-owner balances and immutable request bindings.
    function invariant_FV_actorSharesCashAndRequestOwnershipReconcile() public view {
        assertFalse(handler.actorLedgerViolation());
        assertTrue(
            handler.requestHistoryMatchesModel(), "request archive or pending ownership mismatch"
        );
        assertGt(handler.shareTransfers(), 0);
        assertGt(handler.governanceTransitions(), 0);
        assertGt(handler.rejectedActions(), 0);
        uint256 ownerPaid;
        uint256 recipientsReceived;
        uint256 externallyFunded;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actorAt(i);
            ownerPaid += handler.ghostPaidOnBehalfOfOwner(actor);
            recipientsReceived += handler.ghostCashReceived(actor);
            externallyFunded += handler.ghostExternalFunding(actor);
        }
        assertEq(ownerPaid, recipientsReceived);
        assertEq(
            externallyFunded + handler.ghostFundedProfit() + handler.ghostDonations(),
            recipientsReceived + usdc.balanceOf(address(fundVault)) + usdc.balanceOf(STRATEGY)
                + handler.ghostFundedLoss() + handler.ghostProtocolResidual()
        );
    }

    /// @notice FV-01: independent cross-multiplied incoming asset-loss bound.
    function invariant_FV01_incomingDepositLossIsAtMostOneAssetUnit() public view {
        assertFalse(
            handler.incomingRoundingLossViolation(), "incoming principal lost to coarse shares"
        );
    }

    /// @notice FV-02/FV-03: repeated cycles cannot create gain or material depositor loss.
    function invariant_FV02_roundTripsPreservePrincipalWithinAssetRoundingBudget() public view {
        assertGt(handler.roundTrips(), 0);
        assertGt(handler.scenarioRuns(3), 0);
        assertFalse(handler.roundTripGainViolation(), "round trip manufactured value");
        assertFalse(
            handler.roundTripLossViolation(), "round trip lost more than two USDC base units"
        );
    }

    /// @notice FV-10: a profit-only pre-existing cohort cannot pay fees from remaining principal.
    function invariant_FV10_profitOnlyCohortRetainsItsPrincipal() public view {
        assertFalse(handler.feeCohortViolation(), "fee burden shifted to another investor");
    }

    /// @notice FV-11: earned fee value survives settlement independently of share-formula parity.
    function invariant_FV11_earnedFeesAreNotErased() public view {
        assertFalse(handler.earnedFeeErasureViolation(), "earned performance fee silently erased");
    }

    /// @notice FV-04/FV-06/FV-07/FV-08/FV-09/FV-13/FV-14/FV-15/FV-28: explicit lifecycle witnesses.
    function invariant_FV_relativeEconomicLifecycleScenariosAreReachable() public view {
        uint256[9] memory ids = [uint256(4), 6, 7, 8, 9, 13, 14, 15, 28];
        for (uint256 i; i < ids.length; ++i) {
            assertGt(handler.scenarioRuns(ids[i]), 0);
        }
        assertGt(handler.dailyExitProgress(), 0);
        assertFalse(
            handler.actorEntitlementViolation(), "FV: independent actor entitlement mismatch"
        );
    }

    /// @notice FV-10/FV-11/FV-18/FV-19: economic safety is rechecked after actual eligible exit progress.
    function invariant_FV_economicSafetySurvivesTheEligibleDrain() public {
        // Probe a real drain without changing later random action eligibility or contaminating other properties.
        uint256 snapshot = vm.snapshotState();
        handler.drainEligibleRequests();
        bool actorMismatch = handler.actorLedgerViolation();
        bool requestMismatch = !handler.requestHistoryMatchesModel();
        bool modelMismatch = handler.accountingModelViolation();
        bool cohortShift = handler.feeCohortViolation();
        bool feeErased = handler.earnedFeeErasureViolation();
        bool redemptionPrice = handler.redemptionPriceViolation();
        bool entitlement = handler.actorEntitlementViolation();
        assertTrue(vm.revertToState(snapshot));
        assertFalse(
            actorMismatch || requestMismatch || modelMismatch || cohortShift || feeErased
                || redemptionPrice || entitlement,
            "FV: eligible drain violated actor economics or accounting"
        );
    }

    function afterInvariant() public {
        handler.drainEligibleRequests();
        assertFalse(handler.actorLedgerViolation());
        assertFalse(handler.accountingModelViolation());
        assertTrue(handler.requestHistoryMatchesModel());
    }
}
