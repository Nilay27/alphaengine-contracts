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

        handler = new CompetitionManagerInvariantHandler(manager, competitionId);
        vm.startPrank(admin);
        manager.grantRole(manager.EVALUATOR_ROLE(), address(handler));
        manager.grantRole(manager.FINALIZER_ROLE(), address(handler));
        manager.grantRole(manager.QUALIFIER_ROLE(), address(handler));
        manager.grantRole(manager.SCORE_REVEALER_ROLE(), address(handler));
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.submit.selector;
        selectors[1] = handler.cancel.selector;
        selectors[2] = handler.beginEvaluation.selector;
        selectors[3] = handler.evaluateNext.selector;
        selectors[4] = handler.finalize.selector;
        selectors[5] = handler.publishNextQualification.selector;
        selectors[6] = handler.requestScoreReveal.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_countsMatchAndStayBounded() public view {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            manager.getCompetition(competitionId);
        assertEq(competition.activeSubmissionCount, handler.trackedActiveSubmissionCount());
        assertEq(competition.evaluatedCount, handler.trackedEvaluatedCount());
        assertEq(competition.publishedQualificationCount, handler.trackedPublishedCount());
        assertLe(competition.activeSubmissionCount, manager.MAX_ACTIVE_SUBMISSIONS());
        assertLe(competition.evaluatedCount, competition.activeSubmissionCount);
        assertLe(competition.publishedQualificationCount, competition.qualificationSlots);
    }

    function invariant_nonceEqualsSuccessfulSubmissions() public view {
        for (uint256 index = 0; index < handler.TRADER_COUNT(); ++index) {
            address trader = handler.traderAt(index);
            assertEq(manager.traderNonces(trader), handler.successfulSubmissions(trader));
        }
    }

    function invariant_submissionRankAndActivePointerParity() public view {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            manager.getCompetition(competitionId);
        uint256 length = handler.submissionCount();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 submissionId = handler.submissionAt(index);
            AlphaEngineCompetitionStrategyManager.SubmissionIdentity memory identity =
                manager.getSubmissionIdentity(submissionId);
            AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
                manager.getSubmissionState(submissionId);
            assertEq(manager.getSubmissionComponents(submissionId).length, state.componentCount);

            if (state.status == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Cancelled) {
                assertNotEq(
                    manager.activeSubmissionByTrader(competitionId, identity.trader), submissionId
                );
            } else {
                assertEq(
                    manager.activeSubmissionByTrader(competitionId, identity.trader), submissionId
                );
            }

            if (state.status == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated) {
                assertGt(state.rank, 0);
                assertLe(state.rank, competition.activeSubmissionCount);
                assertEq(manager.submissionByRank(competitionId, state.rank), submissionId);
            } else {
                assertEq(state.rank, 0);
            }
        }
    }

    function invariant_publishedQualificationRequiresFinalizedEligibleEvaluation() public view {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            manager.getCompetition(competitionId);
        uint256 length = handler.submissionCount();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 submissionId = handler.submissionAt(index);
            AlphaEngineCompetitionStrategyManager.SubmissionIdentity memory identity =
                manager.getSubmissionIdentity(submissionId);
            AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
                manager.getSubmissionState(submissionId);
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
            assertTrue(registry.isQualified(identity.trader));
        }
    }

    function invariant_managerHasNoNativeCustody() public view {
        assertEq(address(manager).balance, 0);
    }

    function invariant_scoreRevealIsFinalizedAndRequestsAllComponentsTogether() public view {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            manager.getCompetition(competitionId);
        uint256 length = handler.submissionCount();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 submissionId = handler.submissionAt(index);
            AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
                manager.getSubmissionState(submissionId);
            if (state.status != AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated) {
                continue;
            }

            AlphaEngineCompetitionStrategyManager.EvaluationRecord memory evaluation =
                manager.getEvaluation(submissionId);
            uint256 realSisterRequests =
                taskManager.publicAllowCount(uint256(evaluation.realSisterScoreHandle));
            uint256 perturbationRequests =
                taskManager.publicAllowCount(uint256(evaluation.perturbationP25ScoreHandle));
            uint256 stressRequests =
                taskManager.publicAllowCount(uint256(evaluation.stressP25ScoreHandle));

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
