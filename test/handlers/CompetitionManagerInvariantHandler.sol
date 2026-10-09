// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {externalEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {
    AlphaEngineCompetitionStrategyManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";

contract CompetitionManagerInvariantHandler is MockCoFheTest {
    uint256 public constant TRADER_COUNT = 4;

    AlphaEngineCompetitionStrategyManager public immutable MANAGER;
    bytes32 public immutable COMPETITION_ID;

    bytes32[] private _submissionIds;
    mapping(address trader => uint64 count) public successfulSubmissions;
    uint16 public trackedActiveSubmissionCount;
    uint16 public trackedEvaluatedCount;
    uint16 public trackedPublishedCount;
    uint16 public trackedRevealedThrough;
    uint40 public lastRevealAt;
    uint256 public successfulRevealBatches;
    uint256 public rejectedRevealAttempts;
    uint256 public rejectedSubmissionAttempts;
    uint256 public successfulReplacements;

    constructor(AlphaEngineCompetitionStrategyManager manager, bytes32 competitionId) {
        MANAGER = manager;
        COMPETITION_ID = competitionId;
        _bindMockTaskManager();
    }

    function submit(uint256 traderSeed, uint128 market, uint128 component) external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(COMPETITION_ID);
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active
                || block.timestamp >= competition.submissionDeadline
        ) {
            return;
        }

        address trader = traderAt(traderSeed);
        bytes32 previousSubmission = MANAGER.activeSubmissionByTrader(COMPETITION_ID, trader);

        externalEuint128 encryptedMarket = createExternalEuint128(market, trader);
        externalEuint128[] memory components = new externalEuint128[](2);
        components[0] = createExternalEuint128(component, trader);
        components[1] = createExternalEuint128(component ^ 1, trader);

        (bool allowed, uint256 nextAllowedAt) = MANAGER.getSubmissionAllowance(trader);
        bytes memory proof = _strategyProof(address(MANAGER), encryptedMarket, components);
        if (!allowed) {
            uint256 verifiedBefore = taskManager.batchVerificationCount();
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCompetitionStrategyManager.SubmissionAllowanceExceeded.selector,
                    trader,
                    nextAllowedAt
                )
            );
            vm.prank(trader);
            MANAGER.submitCompetitionStrategy(
                COMPETITION_ID, keccak256("1h"), encryptedMarket, components, proof
            );
            assertEq(taskManager.batchVerificationCount(), verifiedBefore);
            rejectedSubmissionAttempts += 1;
            return;
        }
        vm.prank(trader);
        bytes32 submissionId = MANAGER.submitCompetitionStrategy(
            COMPETITION_ID, keccak256("1h"), encryptedMarket, components, proof
        );
        _submissionIds.push(submissionId);
        successfulSubmissions[trader] += 1;
        if (previousSubmission == bytes32(0)) {
            trackedActiveSubmissionCount += 1;
        } else {
            assertEq(
                uint8(MANAGER.getSubmissionState(previousSubmission).status),
                uint8(AlphaEngineCompetitionStrategyManager.SubmissionStatus.Superseded)
            );
            successfulReplacements += 1;
        }
    }

    function advanceTime(uint32 secondsSeed) external {
        vm.warp(block.timestamp + secondsSeed % 301);
    }

    function cancel(uint256 submissionSeed) external {
        uint256 length = _submissionIds.length;
        if (length == 0) {
            return;
        }
        bytes32 submissionId = _submissionIds[submissionSeed % length];
        AlphaEngineCompetitionStrategyManager.SubmissionIdentity memory identity =
            MANAGER.getSubmissionIdentity(submissionId);
        AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
            MANAGER.getSubmissionState(submissionId);
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(COMPETITION_ID);
        if (
            state.status != AlphaEngineCompetitionStrategyManager.SubmissionStatus.Submitted
                || competition.status
                    != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active
                || block.timestamp >= competition.submissionDeadline
        ) {
            return;
        }

        vm.prank(identity.trader);
        MANAGER.cancelCompetitionSubmission(submissionId);
        trackedActiveSubmissionCount -= 1;
    }

    function beginEvaluation() external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(COMPETITION_ID);
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active
                || competition.activeSubmissionCount == 0
        ) {
            return;
        }
        vm.warp(competition.submissionDeadline);
        MANAGER.beginEvaluation(COMPETITION_ID);
    }

    function evaluateNext() external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(COMPETITION_ID);
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating
                || block.timestamp > competition.evaluationDeadline
        ) {
            return;
        }

        uint256 length = _submissionIds.length;
        for (uint256 index = 0; index < length; ++index) {
            bytes32 submissionId = _submissionIds[index];
            if (
                MANAGER.getSubmissionState(submissionId).status
                    == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Submitted
            ) {
                uint32 score = uint32(trackedEvaluatedCount) + 1;
                AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores =
                    _withScoreProof(
                        address(MANAGER),
                        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission({
                            realSisterScore: createExternalEuint32(score, address(this)),
                            perturbationP25Score: createExternalEuint32(score + 1, address(this)),
                            stressP25Score: createExternalEuint32(score + 2, address(this)),
                            inputProof: ""
                        })
                    );
                MANAGER.recordEvaluation(
                    submissionId,
                    scores,
                    trackedEvaluatedCount + 1,
                    keccak256(abi.encode("evidence", submissionId))
                );
                trackedEvaluatedCount += 1;
                return;
            }
        }
    }

    function finalize() external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(COMPETITION_ID);
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating
                || competition.evaluatedCount != competition.activeSubmissionCount
        ) {
            return;
        }
        MANAGER.finalizeCompetition(COMPETITION_ID);
    }

    function publishNextQualification() external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(COMPETITION_ID);
        if (competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized)
        {
            return;
        }

        uint256 length = _submissionIds.length;
        for (uint256 index = 0; index < length; ++index) {
            bytes32 submissionId = _submissionIds[index];
            AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
                MANAGER.getSubmissionState(submissionId);
            if (
                state.status == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated
                    && state.rank <= competition.qualificationSlots && !state.qualificationPublished
            ) {
                MANAGER.publishTraderQualification(submissionId);
                trackedPublishedCount += 1;
                return;
            }
        }
    }

    function requestScoreReveal(uint16 startSeed, uint16 countSeed) external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(COMPETITION_ID);
        if (competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized)
        {
            return;
        }

        uint16 startRank = trackedRevealedThrough + 1;
        uint16 count = uint16((uint256(countSeed) % MANAGER.MAX_SCORE_REVEAL_BATCH()) + 1);
        if (trackedRevealedThrough == competition.activeSubmissionCount) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCompetitionStrategyManager.ScoreRevealCursorMismatch.selector,
                    COMPETITION_ID,
                    1,
                    startRank
                )
            );
            MANAGER.requestCompetitionScoreReveal(COMPETITION_ID, 1, count);
            rejectedRevealAttempts += 1;
            return;
        }
        if (block.timestamp < MANAGER.nextScoreRevealAt()) {
            if (startSeed % 2 == 0) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        AlphaEngineCompetitionStrategyManager.ScoreRevealNotAvailable.selector,
                        MANAGER.nextScoreRevealAt()
                    )
                );
                MANAGER.requestCompetitionScoreReveal(COMPETITION_ID, startRank, count);
                rejectedRevealAttempts += 1;
                return;
            }
            vm.warp(MANAGER.nextScoreRevealAt());
        }
        if (successfulRevealBatches != 0) assertGe(block.timestamp, uint256(lastRevealAt) + 5);
        uint16 expectedCount = competition.activeSubmissionCount - trackedRevealedThrough;
        if (expectedCount > count) expectedCount = count;
        (uint16 next, uint16 processed) =
            MANAGER.requestCompetitionScoreReveal(COMPETITION_ID, startRank, count);
        assertEq(processed, expectedCount);
        assertEq(next, startRank + expectedCount);
        trackedRevealedThrough += expectedCount;
        lastRevealAt = uint40(block.timestamp);
        successfulRevealBatches += 1;
    }

    function submissionCount() external view returns (uint256) {
        return _submissionIds.length;
    }

    function submissionAt(uint256 index) external view returns (bytes32) {
        return _submissionIds[index];
    }

    function traderAt(uint256 seed) public pure returns (address) {
        return address(uint160(0x2000 + (seed % TRADER_COUNT)));
    }
}
