// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {
    AlphaEngineCompetitionStrategyManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {
    AlphaEngineTraderQualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
import {
    CompetitionManagerInvariantHandler
} from "test/handlers/CompetitionManagerInvariantHandler.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";

contract AlphaEngineCompetitionStrategyManagerInvariantTest is StdInvariant, MockCoFheTest {
    bytes32 private constant ISSUER_ROLE = keccak256("QUALIFICATION_ISSUER_ROLE");
    bytes32 private constant CREATOR_ROLE = keccak256("COMPETITION_CREATOR_ROLE");

    AlphaEngineTraderQualificationRegistry private registry;
    AlphaEngineCompetitionStrategyManager private manager;
    CompetitionManagerInvariantHandler private handler;
    bytes32 private competitionId;

    address private admin = makeAddr("admin");
    address private pauser = makeAddr("pauser");
    address private revoker = makeAddr("revoker");
    address private operator = makeAddr("operator");

    function setUp() public {
        _installMockTaskManager();
        registry = _deployRegistry();
        manager = _deployManager();

        vm.startPrank(admin);
        registry.grantRole(ISSUER_ROLE, address(manager));
        manager.grantRole(CREATOR_ROLE, address(this));
        registry.unpause();
        manager.unpause();
        vm.stopPrank();

        vm.prank(address(this));
        competitionId = manager.createCompetition(
            AlphaEngineCompetitionStrategyManager.CompetitionConfig({
                rulesHash: keccak256("invariant rules"),
                submissionDeadline: uint40(block.timestamp) + 7 days,
                evaluationDeadline: uint40(block.timestamp) + 14 days,
                qualificationValidUntil: uint40(block.timestamp) + 30 days,
                qualificationSlots: 2
            })
        );

        handler =
            new CompetitionManagerInvariantHandler(manager, competitionId, registry, admin, pauser);
        vm.startPrank(admin);
        manager.grantRole(manager.EVALUATOR_ROLE(), address(handler));
        manager.grantRole(manager.COMPETITION_CREATOR_ROLE(), address(handler));
        manager.grantRole(manager.COMPETITION_CANCELLER_ROLE(), address(handler));
        registry.grantRole(registry.QUALIFICATION_ISSUER_ROLE(), address(handler));
        registry.grantRole(registry.QUALIFICATION_REVOKER_ROLE(), address(handler));
        manager.grantRole(manager.FINALIZER_ROLE(), address(handler));
        manager.grantRole(manager.QUALIFIER_ROLE(), address(handler));
        manager.grantRole(manager.SCORE_REVEALER_ROLE(), address(handler));
        vm.stopPrank();

        handler.submit(0, 1, 1);
        handler.submit(0, 2, 2);
        handler.submit(0, 3, 3);
        handler.submit(0, 4, 4);
        handler.cancel(2);
        handler.advanceTime(300);
        handler.submit(0, 1, 1);

        handler.attemptInvalidCancellationOrReplacement(0, false);
        handler.attemptInvalidCancellationOrReplacement(3, true);
        handler.governanceCycle(2 | (uint256(300) << 8));
        handler.upgradeCycle();
        bytes4[] memory selectors = new bytes4[](25);
        selectors[0] = handler.submit.selector;
        selectors[1] = handler.cancel.selector;
        selectors[2] = handler.beginEvaluation.selector;
        selectors[3] = handler.evaluateNext.selector;
        selectors[4] = handler.finalize.selector;
        selectors[5] = handler.publishNextQualification.selector;
        selectors[6] = handler.requestScoreReveal.selector;
        selectors[7] = handler.advanceTime.selector;
        selectors[8] = handler.selectOrCreateCompetition.selector;
        selectors[9] = handler.attemptInvalidCancellationOrReplacement.selector;
        selectors[10] = handler.governanceCycle.selector;
        selectors[11] = handler.phaseBoundary.selector;
        selectors[12] = handler.evaluateOutOfOrder.selector;
        selectors[13] = handler.attemptIncompleteFinalization.selector;
        selectors[14] = handler.cancelCompetitionLifecycle.selector;
        selectors[15] = handler.qualificationHistory.selector;
        selectors[16] = handler.attemptInvalidPublication.selector;
        selectors[17] = handler.attemptInvalidReveal.selector;
        selectors[18] = handler.upgradeCycle.selector;
        selectors[19] = handler.attemptLateSubmission.selector;
        selectors[20] = handler.processingRoleCycle.selector;
        selectors[21] = handler.pausePhaseProbe.selector;
        selectors[22] = handler.attemptTerminalFinalization.selector;
        selectors[23] = handler.publishQualificationAt.selector;
        selectors[24] = handler.attemptInvalidRevealBatch.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_countsMatchAndStayBounded() public view {
        for (uint256 i; i < handler.competitionCount(); ++i) {
            bytes32 id = handler.competitionAt(i);
            AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
                manager.getCompetition(id);
            CompetitionManagerInvariantHandler.Counts memory counts = handler.countsFor(id);
            assertEq(competition.activeSubmissionCount, counts.active);
            assertEq(competition.evaluatedCount, counts.evaluated);
            assertEq(competition.publishedQualificationCount, counts.published);
            assertEq(manager.scoreRevealedThrough(id), counts.revealed);
            assertLe(competition.activeSubmissionCount, manager.MAX_ACTIVE_SUBMISSIONS());
            assertLe(competition.evaluatedCount, competition.activeSubmissionCount);
            assertLe(competition.publishedQualificationCount, competition.qualificationSlots);
        }
        if (handler.successfulRevealBatches() != 0) {
            assertEq(manager.nextScoreRevealAt(), uint256(handler.lastRevealAt()) + 5);
        }
    }

    function invariant_nonceEqualsSuccessfulSubmissions() public view {
        for (uint256 index = 0; index < handler.TRADER_COUNT(); ++index) {
            address trader = handler.traderAt(index);
            assertEq(manager.traderNonces(trader), handler.successfulSubmissions(trader));
        }
    }

    function invariant_submissionRankAndActivePointerParity() public view {
        uint256 length = handler.submissionCount();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 submissionId = handler.submissionAt(index);
            AlphaEngineCompetitionStrategyManager.SubmissionIdentity memory identity =
                manager.getSubmissionIdentity(submissionId);
            AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
                manager.getSubmissionState(submissionId);
            AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
                manager.getCompetition(identity.competitionId);
            assertEq(manager.getSubmissionComponents(submissionId).length, state.componentCount);

            if (
                state.status == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Cancelled
                    || state.status
                        == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Superseded
            ) {
                assertNotEq(
                    manager.activeSubmissionByTrader(identity.competitionId, identity.trader),
                    submissionId
                );
            } else {
                assertEq(
                    manager.activeSubmissionByTrader(identity.competitionId, identity.trader),
                    submissionId
                );
            }

            if (state.status == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated) {
                assertGt(state.rank, 0);
                assertLe(state.rank, competition.activeSubmissionCount);
                assertEq(manager.submissionByRank(identity.competitionId, state.rank), submissionId);
            } else {
                assertEq(state.rank, 0);
            }
        }
    }

    function invariant_publishedQualificationRequiresFinalizedEligibleEvaluation() public view {
        uint256 length = handler.submissionCount();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 submissionId = handler.submissionAt(index);
            AlphaEngineCompetitionStrategyManager.SubmissionIdentity memory identity =
                manager.getSubmissionIdentity(submissionId);
            AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
                manager.getSubmissionState(submissionId);
            AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
                manager.getCompetition(identity.competitionId);
            if (!state.qualificationPublished) {
                continue;
            }
            assertEq(
                uint8(competition.status),
                uint8(AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized)
            );
            assertEq(
                uint8(state.status),
                uint8(AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated)
            );
            assertLe(state.rank, competition.qualificationSlots);
            assertGt(handler.publishedVersion(submissionId), 0);
            assertGe(
                registry.getQualification(identity.trader).version,
                handler.publishedVersion(submissionId)
            );
        }
    }

    function invariant_managerHasNoNativeCustody() public view {
        assertEq(address(manager).balance, 0);
    }

    function invariant_recordedPermissionsAndAdversarialWitnesses() public view {
        handler.property_preservedPermissionLedger();
        assertGt(handler.failedProofChecks(), 0);
        assertGt(handler.rejectedLifecycleAttempts(), 0);
        assertGt(handler.successfulGovernanceCycles(), 0);
        assertGt(handler.successfulUpgradeCycles(), 0);
    }

    /// @dev CM-02/03/08/09/10/14/15/16/18/19/20/21: concrete multi-step witnesses plus randomized values.
    function testFuzz_CM_lifecycleReplacementRankingPublicationAndUpgrade(
        uint128 market,
        uint128 component,
        uint8 seed
    ) public {
        handler.submit(1, market, component);
        handler.submit(2, market, component);
        handler.phaseBoundary(0);
        handler.attemptInvalidCancellationOrReplacement(3, true);
        handler.phaseBoundary(1);
        handler.attemptIncompleteFinalization();
        handler.evaluateOutOfOrder(3, 3);
        handler.evaluateOutOfOrder(4, 1);
        handler.evaluateOutOfOrder(5, 1);
        handler.evaluateOutOfOrder(0, 1);
        handler.evaluateOutOfOrder(2, 2);
        handler.evaluateOutOfOrder(5, 2);
        handler.evaluateOutOfOrder(3, 3);
        handler.finalize();
        handler.attemptTerminalFinalization();
        handler.publishQualificationAt(5);
        handler.publishQualificationAt(4);
        handler.attemptInvalidPublication(3);
        handler.attemptInvalidPublication(4);
        handler.attemptInvalidPublication(0);
        handler.attemptInvalidPublication(2);
        handler.attemptInvalidReveal(seed, true);
        handler.attemptInvalidRevealBatch(false);
        handler.attemptInvalidRevealBatch(true);
        handler.requestScoreReveal(1, 0);
        handler.upgradeCycle();
        handler.processingRoleCycle(seed);
        handler.pausePhaseProbe();
        handler.requestScoreReveal(1, 7);
        handler.attemptInvalidReveal(seed, false);
        handler.qualificationHistory(4, seed % 2 == 0);
        assertGt(handler.failedRevealChecks(), 0);
        assertGt(handler.qualificationHistoryChecks(), 0);
        _assertAllProperties();
    }

    /// @dev CM-04/05/06: wrap the 256-entry history, reject repeated timestamps and refill at the exact edge.
    function test_CM_globalAllowanceWrapAndExactBoundaries() public {
        handler.governanceCycle(0); // one accepted submission per one second; old successes remain recorded.
        handler.selectOrCreateCompetition(1, true);
        for (uint256 i; i < 259; ++i) {
            // Each step gets fresh EVM memory; retain every history and exact-boundary assertion.
            this.checkAllowanceWrapStep(i);
        }
        _assertAllProperties();
    }

    function checkAllowanceWrapStep(uint256 i) external {
        assertEq(msg.sender, address(this));
        handler.selectOrCreateCompetition(i % 2, false);
        uint256 beforeNonce = manager.traderNonces(handler.traderAt(1));
        handler.submit(1, uint128(i % 3), 1);
        assertEq(manager.traderNonces(handler.traderAt(1)), beforeNonce + 1);
        handler.submit(1, uint128(i % 3), 1);
        assertEq(manager.traderNonces(handler.traderAt(1)), beforeNonce + 1);
        invariant_rollingAllowanceMatchesSubmissionHistory();
        handler.advanceTime(1);
        (bool allowed,) = manager.getSubmissionAllowance(handler.traderAt(1));
        assertTrue(allowed);
    }

    /// @dev CM-07/16/21: fill every active slot, replace at capacity, then upgrade during partial reveal.
    function test_CM_fullCapacityReplacementRankDrainAndUpgrade() public {
        handler.selectOrCreateCompetition(1, true);
        bytes32 id = handler.competitionAt(1);
        handler.fillCompetitionCapacity();
        handler.beginEvaluation();
        for (uint256 i; i < manager.MAX_ACTIVE_SUBMISSIONS(); ++i) {
            handler.evaluateNext();
        }
        handler.finalize();
        handler.requestScoreReveal(1, 7);
        assertEq(manager.scoreRevealedThrough(id), 8);
        handler.upgradeCycle();
        for (uint256 i = 1; i < 32; ++i) {
            handler.requestScoreReveal(1, 7);
        }
        assertEq(manager.scoreRevealedThrough(id), manager.MAX_ACTIVE_SUBMISSIONS());
        handler.requestScoreReveal(1, 0);
        _assertAllProperties();
    }

    /// @dev CM-12/13/20: empty and incompletely evaluated work can terminate while paused, without revival.
    function testFuzz_CM_expiryAndEmergencyCancellationAreTerminal(bool emergency, uint128 value)
        public
    {
        handler.selectOrCreateCompetition(1, true);
        handler.cancelCompetitionLifecycle(emergency, true);
        handler.selectOrCreateCompetition(2, true);
        handler.submit(1, value, value);
        handler.beginEvaluation();
        handler.cancelCompetitionLifecycle(emergency, true);
        handler.attemptInvalidPublication(handler.submissionCount() - 1);
        handler.attemptTerminalFinalization();
        assertEq(handler.successfulExpiryCleanups(), 2);
        _assertAllProperties();
    }

    /// @dev CM-17: independent competition cursors cannot bypass the global five-second grant budget.
    function testFuzz_CM_twoCompetitionsShareRevealPacing(uint128 value) public {
        handler.selectOrCreateCompetition(1, true);
        handler.submit(1, value, value);
        handler.selectOrCreateCompetition(2, true);
        handler.submit(2, value, value);
        for (uint256 i = 1; i < 3; ++i) {
            handler.selectOrCreateCompetition(i, false);
            handler.beginEvaluation();
            handler.evaluateNext();
            handler.finalize();
        }
        handler.selectOrCreateCompetition(1, false);
        handler.requestScoreReveal(1, 0);
        handler.publishNextQualification();
        handler.selectOrCreateCompetition(2, false);
        handler.publishNextQualification();
        uint256 denied = handler.rejectedRevealAttempts();
        handler.requestScoreReveal(0, 0);
        assertEq(handler.rejectedRevealAttempts(), denied + 1);
        handler.requestScoreReveal(1, 0);
        _assertAllProperties();
    }

    function test_CM_lateSubmissionFailsBeforeFheAndExpiredBeginCannotRewindTime() public {
        handler.phaseBoundary(2);
        handler.attemptLateSubmission(0);
        uint256 nowBefore = block.timestamp;
        handler.beginEvaluation();
        assertEq(block.timestamp, nowBefore);
        _assertAllProperties();
    }

    function test_CM_exactSubmissionAndEvaluationDeadlineBoundaries() public {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            manager.getCompetition(competitionId);
        vm.warp(competition.submissionDeadline);
        handler.attemptLateSubmission(0);
        handler.beginEvaluation();
        vm.warp(competition.evaluationDeadline);
        handler.evaluateNext();
        handler.finalize();
        _assertAllProperties();
    }

    /// @dev CM-11/R4 POLICY-CONDITIONAL: desired completed-work protection, deliberately red on current code.
    /// This is exploratory until the owner chooses this policy rather than a hard finalization cutoff.
    function test_CM11_exploratory_completedEvaluationSurvivesPublicExpiryCancellation() public {
        handler.beginEvaluation();
        handler.evaluateNext();
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            manager.getCompetition(competitionId);
        assertEq(competition.evaluatedCount, competition.activeSubmissionCount);
        vm.warp(uint256(competition.evaluationDeadline) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionCancellationNotAvailable.selector,
                competitionId,
                AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating,
                block.timestamp
            )
        );
        manager.cancelExpiredCompetition(competitionId);
        handler.finalize();
        assertEq(
            uint8(manager.getCompetition(competitionId).status),
            uint8(AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized)
        );
    }

    function _assertAllProperties() private view {
        invariant_countsMatchAndStayBounded();
        invariant_nonceEqualsSuccessfulSubmissions();
        invariant_submissionRankAndActivePointerParity();
        invariant_publishedQualificationRequiresFinalizedEligibleEvaluation();
        invariant_rollingAllowanceMatchesSubmissionHistory();
        invariant_scoreRevealIsFinalizedAndRequestsAllComponentsTogether();
        invariant_recordedPermissionsAndAdversarialWitnesses();
    }

    /// @dev CM-04/CM-05/CM-06: current policy applies to the last accepted successes across all competitions.
    function invariant_rollingAllowanceMatchesSubmissionHistory() public view {
        assertGt(handler.successfulReplacements(), 0);
        assertGt(handler.rejectedSubmissionAttempts(), 0);
        for (uint256 traderIndex; traderIndex < handler.TRADER_COUNT(); ++traderIndex) {
            address trader = handler.traderAt(traderIndex);
            uint256 successes = handler.successfulSubmissions(trader);
            uint256 limit = manager.submissionLimit();
            uint256 expectedNext;
            if (successes >= limit) {
                uint256 expiry = uint256(handler.acceptedAt(trader, successes - limit))
                    + manager.submissionWindowSeconds();
                if (expiry > vm.getBlockTimestamp()) expectedNext = expiry;
            }
            (bool allowed, uint256 nextAt) = manager.getSubmissionAllowance(trader);
            assertEq(allowed, expectedNext == 0);
            assertEq(nextAt, expectedNext);
        }
    }

    function invariant_scoreRevealIsFinalizedAndRequestsAllComponentsTogether() public view {
        uint256 length = handler.submissionCount();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 submissionId = handler.submissionAt(index);
            AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
                manager.getSubmissionState(submissionId);
            if (state.status != AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated) {
                continue;
            }

            bytes32 id = manager.getSubmissionIdentity(submissionId).competitionId;
            AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
                manager.getCompetition(id);
            CompetitionManagerInvariantHandler.Counts memory counts = handler.countsFor(id);
            AlphaEngineCompetitionStrategyManager.EvaluationRecord memory evaluation =
                manager.getEvaluation(submissionId);
            uint256 realSisterRequests =
                taskManager.publicAllowCount(uint256(evaluation.realSisterScoreHandle));
            uint256 perturbationRequests =
                taskManager.publicAllowCount(uint256(evaluation.perturbationP25ScoreHandle));
            uint256 stressRequests =
                taskManager.publicAllowCount(uint256(evaluation.stressP25ScoreHandle));

            assertLe(realSisterRequests, 1);
            assertEq(realSisterRequests, state.rank <= counts.revealed ? 1 : 0);
            assertEq(realSisterRequests, perturbationRequests);
            assertEq(realSisterRequests, stressRequests);
            if (realSisterRequests > 0) {
                assertEq(
                    uint8(competition.status),
                    uint8(AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized)
                );
                assertEq(
                    taskManager.lastPublicAllower(uint256(evaluation.realSisterScoreHandle)),
                    address(manager)
                );
            }
        }
    }

    function _deployRegistry() private returns (AlphaEngineTraderQualificationRegistry deployed) {
        AlphaEngineTraderQualificationRegistry implementation =
            new AlphaEngineTraderQualificationRegistry();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(
                AlphaEngineTraderQualificationRegistry.initialize, (admin, pauser, revoker)
            )
        );
        return AlphaEngineTraderQualificationRegistry(address(proxy));
    }

    function _deployManager() private returns (AlphaEngineCompetitionStrategyManager deployed) {
        AlphaEngineCompetitionStrategyManager implementation =
            new AlphaEngineCompetitionStrategyManager();
        AlphaEngineCompetitionStrategyManager.InitializationParams memory params =
            AlphaEngineCompetitionStrategyManager.InitializationParams({
                initialDefaultAdmin: admin,
                initialPauser: pauser,
                initialFheOperator: operator,
                qualificationRegistry: address(registry)
            });
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(AlphaEngineCompetitionStrategyManager.initialize, (params))
        );
        return AlphaEngineCompetitionStrategyManager(address(proxy));
    }
}
