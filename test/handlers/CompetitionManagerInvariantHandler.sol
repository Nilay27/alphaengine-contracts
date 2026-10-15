// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {externalEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    AlphaEngineCompetitionStrategyManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockCoFheTaskManager} from "test/mocks/MockCoFheTaskManager.sol";
import {
    AlphaEngineTraderQualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";

contract CompetitionManagerInvariantHandler is MockCoFheTest {
    uint256 public constant TRADER_COUNT = 4;

    AlphaEngineCompetitionStrategyManager public immutable MANAGER;
    bytes32 public immutable COMPETITION_ID;

    bytes32[] private _submissionIds;
    mapping(address trader => uint64 count) public successfulSubmissions;
    mapping(address trader => mapping(uint256 nonce => uint40)) public acceptedAt;

    struct Counts {
        uint16 active;
        uint16 evaluated;
        uint16 published;
        uint16 revealed;
    }
    mapping(bytes32 => Counts) private _counts;
    bytes32[] private _competitionIds;
    uint256 public selectedCompetitionIndex;
    AlphaEngineTraderQualificationRegistry public immutable REGISTRY;
    address private immutable ADMIN;
    address private immutable PAUSER;
    mapping(bytes32 => uint64) public publishedVersion;
    uint256 public rejectedLifecycleAttempts;
    uint256 public successfulGovernanceCycles;
    uint256 public successfulUpgradeCycles;
    uint256 public successfulExpiryCleanups;
    uint256 public failedProofChecks;
    uint256 public failedRevealChecks;
    uint256 public qualificationHistoryChecks;
    uint40 public lastRevealAt;
    uint256 public successfulRevealBatches;
    uint256 public rejectedRevealAttempts;
    uint256 public rejectedSubmissionAttempts;
    uint256 public successfulReplacements;

    constructor(
        AlphaEngineCompetitionStrategyManager manager,
        bytes32 competitionId,
        AlphaEngineTraderQualificationRegistry registry,
        address admin,
        address pauser
    ) {
        MANAGER = manager;
        COMPETITION_ID = competitionId;
        REGISTRY = registry;
        ADMIN = admin;
        PAUSER = pauser;
        _competitionIds.push(competitionId);
        _bindMockTaskManager();
    }

    function submit(uint256 traderSeed, uint128 market, uint128 component) external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(_selected());
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active
                || block.timestamp >= competition.submissionDeadline
        ) {
            return;
        }

        address trader = traderAt(traderSeed);
        bytes32 previousSubmission = MANAGER.activeSubmissionByTrader(_selected(), trader);

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
                _selected(), keccak256("1h"), encryptedMarket, components, proof
            );
            assertEq(taskManager.batchVerificationCount(), verifiedBefore);
            rejectedSubmissionAttempts += 1;
            return;
        }
        vm.prank(trader);
        bytes32 submissionId = MANAGER.submitCompetitionStrategy(
            _selected(), keccak256("1h"), encryptedMarket, components, proof
        );
        _recordSuccessfulSubmission(trader, submissionId);
        if (previousSubmission == bytes32(0)) {
            _counts[_selected()].active += 1;
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
            MANAGER.getCompetition(identity.competitionId);
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
        _counts[identity.competitionId].active -= 1;
    }

    function beginEvaluation() external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(_selected());
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active
                || competition.activeSubmissionCount == 0
                || block.timestamp > competition.evaluationDeadline
        ) {
            return;
        }
        if (block.timestamp < competition.submissionDeadline) {
            vm.warp(competition.submissionDeadline);
        }
        MANAGER.beginEvaluation(_selected());
    }

    function evaluateNext() external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(_selected());
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating
                || block.timestamp > competition.evaluationDeadline
        ) {
            return;
        }

        uint256 length = _submissionIds.length;
        for (uint256 index = 0; index < length; ++index) {
            bytes32 submissionId = _submissionIds[index];
            if (MANAGER.getSubmissionIdentity(submissionId).competitionId != _selected()) continue;
            if (
                MANAGER.getSubmissionState(submissionId).status
                    == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Submitted
            ) {
                uint32 score = uint32(_counts[_selected()].evaluated) + 1;
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
                uint16 rank = 1;
                while (MANAGER.submissionByRank(_selected(), rank) != bytes32(0)) ++rank;
                MANAGER.recordEvaluation(
                    submissionId, scores, rank, keccak256(abi.encode("evidence", submissionId))
                );
                _counts[_selected()].evaluated += 1;
                return;
            }
        }
    }

    function finalize() external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(_selected());
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating
                || competition.evaluatedCount != competition.activeSubmissionCount
        ) {
            return;
        }
        MANAGER.finalizeCompetition(_selected());
    }

    function publishNextQualification() external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(_selected());
        if (competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized)
        {
            return;
        }

        uint256 length = _submissionIds.length;
        for (uint256 index = 0; index < length; ++index) {
            bytes32 submissionId = _submissionIds[index];
            if (MANAGER.getSubmissionIdentity(submissionId).competitionId != _selected()) continue;
            AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
                MANAGER.getSubmissionState(submissionId);
            if (
                state.status == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated
                    && state.rank <= competition.qualificationSlots && !state.qualificationPublished
            ) {
                address trader = MANAGER.getSubmissionIdentity(submissionId).trader;
                if (block.timestamp >= competition.qualificationValidUntil) return;
                if (
                    REGISTRY.isQualified(trader)
                        && REGISTRY.getQualification(trader).validUntil
                            >= competition.qualificationValidUntil
                ) return;
                publishedVersion[submissionId] = MANAGER.publishTraderQualification(submissionId);
                _counts[_selected()].published += 1;
                return;
            }
        }
    }

    /// @dev CM-14: choose publication order independently of submission order and rank.
    function publishQualificationAt(uint256 seed) external {
        if (_submissionIds.length == 0) return;
        bytes32 id = _submissionIds[seed % _submissionIds.length];
        AlphaEngineCompetitionStrategyManager.SubmissionIdentity memory identity =
            MANAGER.getSubmissionIdentity(id);
        AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
            MANAGER.getSubmissionState(id);
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(identity.competitionId);
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized
                || state.status != AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated
                || state.rank == 0 || state.rank > competition.qualificationSlots
                || state.qualificationPublished
                || block.timestamp >= competition.qualificationValidUntil
        ) return;
        if (
            REGISTRY.isQualified(identity.trader)
                && REGISTRY.getQualification(identity.trader).validUntil
                    >= competition.qualificationValidUntil
        ) return;
        publishedVersion[id] = MANAGER.publishTraderQualification(id);
        ++_counts[identity.competitionId].published;
    }

    function requestScoreReveal(uint16 startSeed, uint16 countSeed) external {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(_selected());
        if (competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized)
        {
            return;
        }

        uint16 startRank = _counts[_selected()].revealed + 1;
        uint16 count = uint16((uint256(countSeed) % MANAGER.MAX_SCORE_REVEAL_BATCH()) + 1);
        if (_counts[_selected()].revealed == competition.activeSubmissionCount) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCompetitionStrategyManager.ScoreRevealCursorMismatch.selector,
                    _selected(),
                    1,
                    startRank
                )
            );
            MANAGER.requestCompetitionScoreReveal(_selected(), 1, count);
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
                MANAGER.requestCompetitionScoreReveal(_selected(), startRank, count);
                rejectedRevealAttempts += 1;
                return;
            }
            vm.warp(MANAGER.nextScoreRevealAt());
        }
        if (successfulRevealBatches != 0) assertGe(block.timestamp, uint256(lastRevealAt) + 5);
        uint16 expectedCount = competition.activeSubmissionCount - _counts[_selected()].revealed;
        if (expectedCount > count) expectedCount = count;
        (uint16 next, uint16 processed) =
            MANAGER.requestCompetitionScoreReveal(_selected(), startRank, count);
        assertEq(processed, expectedCount);
        assertEq(next, startRank + expectedCount);
        _counts[_selected()].revealed += expectedCount;
        lastRevealAt = uint40(block.timestamp);
        successfulRevealBatches += 1;
    }

    function submissionCount() external view returns (uint256) {
        return _submissionIds.length;
    }

    function competitionCount() external view returns (uint256) {
        return _competitionIds.length;
    }

    function competitionAt(uint256 i) external view returns (bytes32) {
        return _competitionIds[i];
    }

    function countsFor(bytes32 id) external view returns (Counts memory) {
        return _counts[id];
    }

    function property_preservedPermissionLedger() external view {
        _allSnapshot();
    }

    function trackedActiveSubmissionCount() external view returns (uint16) {
        return _counts[COMPETITION_ID].active;
    }

    function trackedEvaluatedCount() external view returns (uint16) {
        return _counts[COMPETITION_ID].evaluated;
    }

    function trackedPublishedCount() external view returns (uint16) {
        return _counts[COMPETITION_ID].published;
    }

    function trackedRevealedThrough() external view returns (uint16) {
        return _counts[COMPETITION_ID].revealed;
    }

    /// @dev CM-04/CM-17: all competitions share wallet history and reveal pacing.
    function selectOrCreateCompetition(uint256 seed, bool create) external {
        if (create && _competitionIds.length < 8) {
            bytes32 id = MANAGER.createCompetition(
                AlphaEngineCompetitionStrategyManager.CompetitionConfig({
                    rulesHash: keccak256(
                        abi.encode("lifecycle rules", seed, _competitionIds.length)
                    ),
                    submissionDeadline: uint40(block.timestamp + 7 days),
                    evaluationDeadline: uint40(block.timestamp + 14 days),
                    qualificationValidUntil: uint40(
                        block.timestamp + 30 days + _competitionIds.length * 1 days
                    ),
                    qualificationSlots: 2
                })
            );
            _competitionIds.push(id);
            selectedCompetitionIndex = _competitionIds.length - 1;
        } else {
            selectedCompetitionIndex = seed % _competitionIds.length;
        }
    }

    /// @dev CM-02/CM-03: rejected old-entry cancellation and invalid proof never replace live evidence.
    function attemptInvalidCancellationOrReplacement(uint256 seed, bool proofFailure) external {
        if (_submissionIds.length == 0) return;
        bytes32 id = _submissionIds[seed % _submissionIds.length];
        AlphaEngineCompetitionStrategyManager.SubmissionIdentity memory identity =
            MANAGER.getSubmissionIdentity(id);
        AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
            MANAGER.getSubmissionState(id);
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(identity.competitionId);
        bytes32 beforeHash = _snapshot(identity.competitionId);
        uint256 verified = taskManager.batchVerificationCount();
        if (
            !proofFailure
                && state.status != AlphaEngineCompetitionStrategyManager.SubmissionStatus.Submitted
        ) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCompetitionStrategyManager.SubmissionNotSubmitted.selector,
                    id,
                    state.status
                )
            );
            vm.prank(identity.trader);
            MANAGER.cancelCompetitionSubmission(id);
            assertEq(_snapshot(identity.competitionId), beforeHash);
            ++rejectedLifecycleAttempts;
        } else if (
            proofFailure
                && state.status == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Submitted
                && competition.status
                    == AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active
                && block.timestamp < competition.submissionDeadline
        ) {
            (bool allowed,) = MANAGER.getSubmissionAllowance(identity.trader);
            if (!allowed) return;
            externalEuint128 market = createExternalEuint128(uint128(seed), identity.trader);
            externalEuint128[] memory components = new externalEuint128[](1);
            components[0] = createExternalEuint128(uint128(seed ^ 1), identity.trader);
            bytes memory invalidProof = _strategyProof(address(0xBAD), market, components);
            vm.expectPartialRevert(MockCoFheTaskManager.InvalidSigner.selector);
            vm.prank(identity.trader);
            MANAGER.submitCompetitionStrategy(
                identity.competitionId, keccak256("1h"), market, components, invalidProof
            );
            assertEq(_snapshot(identity.competitionId), beforeHash);
            assertFalse(
                taskManager.isAllowed(uint256(externalEuint128.unwrap(market)), address(MANAGER))
            );
            ++failedProofChecks;
        }
        assertEq(taskManager.batchVerificationCount(), verified);
    }

    /// @dev CM-06/CM-19/CM-20: configure prospective policy without erasing historical admission or ACLs.
    function governanceCycle(uint256 seed) external {
        bytes32 beforeHash = _allSnapshot();
        address oldOperator = MANAGER.fheOperator();
        vm.prank(PAUSER);
        MANAGER.pause();
        externalEuint128 market = createExternalEuint128(1, traderAt(seed));
        externalEuint128[] memory components = new externalEuint128[](1);
        components[0] = createExternalEuint128(2, traderAt(seed));
        bytes memory proof = _strategyProof(address(MANAGER), market, components);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(traderAt(seed));
        MANAGER.submitCompetitionStrategy(_selected(), keccak256("1h"), market, components, proof);
        vm.startPrank(ADMIN);
        MANAGER.updateSubmissionLimits(uint16(1 + seed % 8), uint32(1 + (seed >> 8) % 600));
        MANAGER.updateFheOperator(
            oldOperator == address(0xF1E1) ? address(0xF1E2) : address(0xF1E1)
        );
        MANAGER.unpause();
        MANAGER.revokeRole(MANAGER.EVALUATOR_ROLE(), address(this));
        vm.stopPrank();
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores = _scores(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                MANAGER.EVALUATOR_ROLE()
            )
        );
        MANAGER.recordEvaluation(bytes32(uint256(1)), scores, 1, keccak256("forbidden"));
        bytes32 evaluatorRole = MANAGER.EVALUATOR_ROLE();
        vm.prank(ADMIN);
        MANAGER.grantRole(evaluatorRole, address(this));
        // Operator/limits are deliberately prospective, so exclude them from this historical snapshot.
        assertEq(_allSnapshot(), beforeHash);
        ++successfulGovernanceCycles;
    }

    /// @dev CM-08: submission/evaluation edges are tested from the actual current time, never rewound.
    function phaseBoundary(uint8 edge) external {
        bytes32 id = _selected();
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(id);
        if (competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active) {
            return;
        }
        uint256 target = edge % 3 == 0
            ? uint256(competition.submissionDeadline) - 1
            : edge % 3 == 1
                ? competition.submissionDeadline
                : uint256(competition.evaluationDeadline) + 1;
        if (target < block.timestamp) return;
        vm.warp(target);
        bytes32 beforeHash = _snapshot(id);
        if (target < competition.submissionDeadline) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCompetitionStrategyManager.CompetitionEvaluationNotStarted.selector,
                    id,
                    competition.submissionDeadline,
                    target
                )
            );
            MANAGER.beginEvaluation(id);
        } else if (target > competition.evaluationDeadline) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCompetitionStrategyManager.CompetitionEvaluationClosed.selector,
                    id,
                    competition.evaluationDeadline,
                    target
                )
            );
            MANAGER.beginEvaluation(id);
        } else if (competition.activeSubmissionCount == 0) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCompetitionStrategyManager.CompetitionHasNoActiveSubmissions
                    .selector,
                    id
                )
            );
            MANAGER.beginEvaluation(id);
        } else {
            MANAGER.beginEvaluation(id);
            return;
        }
        assertEq(_snapshot(id), beforeHash);
        ++rejectedLifecycleAttempts;
    }

    /// @dev CM-09/CM-10: out-of-order ranks and atomic invalid evaluation/finalization.
    function evaluateOutOfOrder(uint256 seed, uint16 rankSeed) external {
        bytes32 id = _selected();
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(id);
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating
                || block.timestamp > competition.evaluationDeadline || _submissionIds.length == 0
        ) return;
        bytes32 submission = _submissionIds[seed % _submissionIds.length];
        if (MANAGER.getSubmissionIdentity(submission).competitionId != id) return;
        AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
            MANAGER.getSubmissionState(submission);
        uint16 rank = uint16(uint256(rankSeed) % (uint256(competition.activeSubmissionCount) + 2));
        bytes32 beforeHash = _snapshot(id);
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(uint32(seed % 1000));
        bytes memory failure;
        if (state.status != AlphaEngineCompetitionStrategyManager.SubmissionStatus.Submitted) {
            failure = abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.SubmissionNotSubmitted.selector,
                submission,
                state.status
            );
        } else if (rank == 0 || rank > competition.activeSubmissionCount) {
            failure = abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidRank.selector,
                id,
                rank,
                competition.activeSubmissionCount
            );
        } else if (MANAGER.submissionByRank(id, rank) != bytes32(0)) {
            failure = abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.RankAlreadyAssigned.selector,
                id,
                rank,
                MANAGER.submissionByRank(id, rank)
            );
        }
        if (failure.length != 0) {
            vm.expectRevert(failure);
            MANAGER.recordEvaluation(
                submission, scores, rank, keccak256(abi.encode("evidence", submission))
            );
            assertEq(_snapshot(id), beforeHash);
            ++rejectedLifecycleAttempts;
        } else {
            MANAGER.recordEvaluation(
                submission, scores, rank, keccak256(abi.encode("evidence", submission))
            );
            ++_counts[id].evaluated;
        }
    }

    function attemptIncompleteFinalization() external {
        bytes32 id = _selected();
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(id);
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating
                || competition.evaluatedCount == competition.activeSubmissionCount
        ) return;
        bytes32 beforeHash = _snapshot(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionEvaluationIncomplete.selector,
                id,
                competition.evaluatedCount,
                competition.activeSubmissionCount
            )
        );
        MANAGER.finalizeCompetition(id);
        assertEq(_snapshot(id), beforeHash);
        ++rejectedLifecycleAttempts;
    }

    /// @dev CM-12/CM-13/CM-20: expiry/emergency cancellation is terminal, including while paused.
    function cancelCompetitionLifecycle(bool emergency, bool paused) external {
        bytes32 id = _selected();
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(id);
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active
                && competition.status
                    != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating
        ) return;
        if (paused) {
            vm.prank(PAUSER);
            MANAGER.pause();
        }
        address stranger = address(0xBADCA11);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                MANAGER.COMPETITION_CANCELLER_ROLE()
            )
        );
        vm.prank(stranger);
        MANAGER.cancelCompetition(id);
        if (emergency) {
            MANAGER.cancelCompetition(id);
        } else {
            if (block.timestamp <= competition.evaluationDeadline) {
                vm.warp(uint256(competition.evaluationDeadline) + 1);
            }
            bytes32 beforeExpiry = _snapshot(id);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    stranger,
                    MANAGER.COMPETITION_CANCELLER_ROLE()
                )
            );
            vm.prank(stranger);
            MANAGER.cancelExpiredCompetition(id);
            assertEq(_snapshot(id), beforeExpiry);
            MANAGER.cancelExpiredCompetition(id);
        }
        assertEq(
            uint8(MANAGER.getCompetition(id).status),
            uint8(AlphaEngineCompetitionStrategyManager.CompetitionStatus.Cancelled)
        );
        if (paused) {
            vm.prank(ADMIN);
            MANAGER.unpause();
        }
        bytes32 beforeHash = _snapshot(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionNotEvaluating.selector,
                id,
                AlphaEngineCompetitionStrategyManager.CompetitionStatus.Cancelled
            )
        );
        MANAGER.finalizeCompetition(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionNotFinalized.selector,
                id,
                AlphaEngineCompetitionStrategyManager.CompetitionStatus.Cancelled
            )
        );
        MANAGER.requestCompetitionScoreReveal(id, 1, 1);
        assertEq(_snapshot(id), beforeHash);
        ++successfulExpiryCleanups;
    }

    /// @dev CM-14/CM-15: publication is historical evidence, not perpetual current qualification.
    function qualificationHistory(uint256 seed, bool revoke) external {
        if (_submissionIds.length == 0) return;
        bytes32 id = _submissionIds[seed % _submissionIds.length];
        AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
            MANAGER.getSubmissionState(id);
        AlphaEngineCompetitionStrategyManager.SubmissionIdentity memory identity =
            MANAGER.getSubmissionIdentity(id);
        if (!state.qualificationPublished) return;
        if (revoke && REGISTRY.isQualified(identity.trader)) {
            REGISTRY.revokeTrader(
                identity.trader, keccak256("historical evidence survives revocation")
            );
        } else {
            uint40 expiry = REGISTRY.getQualification(identity.trader).validUntil;
            if (block.timestamp < expiry) vm.warp(expiry);
        }
        assertTrue(MANAGER.getSubmissionState(id).qualificationPublished);
        assertFalse(REGISTRY.isQualified(identity.trader));
        REGISTRY.qualifyTrader(
            identity.trader,
            uint40(block.timestamp + 1 days),
            keccak256("later source"),
            keccak256("later evidence")
        );
        assertTrue(MANAGER.getSubmissionState(id).qualificationPublished);
        ++qualificationHistoryChecks;
    }

    function attemptInvalidPublication(uint256 seed) external {
        if (_submissionIds.length == 0) return;
        bytes32 id = _submissionIds[seed % _submissionIds.length];
        AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
            MANAGER.getSubmissionState(id);
        bytes32 competitionId = MANAGER.getSubmissionIdentity(id).competitionId;
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(competitionId);
        bytes memory failure;
        if (competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized)
        {
            failure = abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionNotFinalized.selector,
                competitionId,
                competition.status
            );
        } else if (
            state.status != AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated
                || state.rank == 0 || state.rank > competition.qualificationSlots
        ) {
            failure = abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.SubmissionNotEligible.selector,
                id,
                state.rank,
                competition.qualificationSlots
            );
        } else if (state.qualificationPublished) {
            failure = abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.QualificationAlreadyPublished.selector, id
            );
        } else {
            return;
        }
        bytes32 beforeHash = _snapshot(competitionId);
        vm.expectRevert(failure);
        MANAGER.publishTraderQualification(id);
        assertEq(_snapshot(competitionId), beforeHash);
        ++rejectedLifecycleAttempts;
    }

    /// @dev CM-16/CM-18: cursor errors and mid-batch failures preserve every preceding grant.
    function attemptInvalidReveal(uint16 seed, bool injectFailure) external {
        bytes32 id = _selected();
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(id);
        if (competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized)
        {
            return;
        }
        uint16 expected = MANAGER.scoreRevealedThrough(id) + 1;
        uint16 start = uint16(uint256(seed) % (uint256(competition.activeSubmissionCount) + 2));
        bytes32 beforeHash = _snapshot(id);
        uint256 beforePacing = MANAGER.nextScoreRevealAt();
        if (!injectFailure) {
            if (start == expected) start = start == 1 ? 0 : 1;
            bytes memory failure = start == 0 || start > competition.activeSubmissionCount
                ? abi.encodeWithSelector(
                    AlphaEngineCompetitionStrategyManager.InvalidScoreRevealStartRank.selector,
                    id,
                    start,
                    competition.activeSubmissionCount
                )
                : abi.encodeWithSelector(
                    AlphaEngineCompetitionStrategyManager.ScoreRevealCursorMismatch.selector,
                    id,
                    start,
                    expected
                );
            vm.expectRevert(failure);
            MANAGER.requestCompetitionScoreReveal(id, start, 1);
            ++rejectedLifecycleAttempts;
        } else {
            if (expected > competition.activeSubmissionCount) return;
            if (block.timestamp < beforePacing) vm.warp(beforePacing);
            uint16 failingRank = seed % 3 == 2 && expected < competition.activeSubmissionCount
                ? expected + 1
                : expected;
            bytes32 submission = MANAGER.submissionByRank(id, failingRank);
            AlphaEngineCompetitionStrategyManager.EvaluationRecord memory scores =
                MANAGER.getEvaluation(submission);
            bytes32 failHandle =
                seed % 2 == 0 ? scores.perturbationP25ScoreHandle : scores.stressP25ScoreHandle;
            bytes memory failure = abi.encodeWithSelector(
                MockCoFheTaskManager.SenderNotAllowed.selector,
                uint256(failHandle),
                address(MANAGER)
            );
            vm.mockCallRevert(
                address(taskManager),
                abi.encodeWithSelector(taskManager.allowGlobal.selector, uint256(failHandle)),
                failure
            );
            vm.expectRevert(failure);
            MANAGER.requestCompetitionScoreReveal(id, expected, 2);
            vm.clearMockedCalls();
            ++failedRevealChecks;
        }
        assertEq(_snapshot(id), beforeHash);
        assertEq(MANAGER.nextScoreRevealAt(), beforePacing);
    }

    /// @dev CM-21: populated compatible upgrade, rejected old ProxyAdmin owner and initializer replay.
    function upgradeCycle() external {
        bytes32 beforeHash = _allSnapshot();
        bytes32 settingsHash = keccak256(
            abi.encode(
                MANAGER.fheOperator(),
                MANAGER.submissionLimit(),
                MANAGER.submissionWindowSeconds(),
                MANAGER.defaultAdmin(),
                MANAGER.nextScoreRevealAt(),
                MANAGER.competitionNonce()
            )
        );
        ProxyAdmin proxyAdmin = ProxyAdmin(
            address(
                uint160(
                    uint256(
                        vm.load(
                            address(MANAGER), bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
                        )
                    )
                )
            )
        );
        address nextAdmin = address(0xC021);
        address implementation = address(new AlphaEngineCompetitionStrategyManager());
        vm.prank(ADMIN);
        proxyAdmin.transferOwnership(nextAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ADMIN));
        vm.prank(ADMIN);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(MANAGER)), implementation, ""
        );
        vm.prank(nextAdmin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(MANAGER)), implementation, ""
        );
        assertEq(_allSnapshot(), beforeHash);
        assertEq(
            keccak256(
                abi.encode(
                    MANAGER.fheOperator(),
                    MANAGER.submissionLimit(),
                    MANAGER.submissionWindowSeconds(),
                    MANAGER.defaultAdmin(),
                    MANAGER.nextScoreRevealAt(),
                    MANAGER.competitionNonce()
                )
            ),
            settingsHash
        );
        AlphaEngineCompetitionStrategyManager.InitializationParams memory params =
            AlphaEngineCompetitionStrategyManager.InitializationParams(
                ADMIN, PAUSER, MANAGER.fheOperator(), address(REGISTRY)
            );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        MANAGER.initialize(params);
        vm.prank(nextAdmin);
        proxyAdmin.transferOwnership(ADMIN);
        ++successfulUpgradeCycles;
    }

    /// @dev CM-07/CM-16: deterministic saturation witness supplements small randomized actor sets.
    function fillCompetitionCapacity() external {
        bytes32 id = _selected();
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(id);
        assertEq(competition.activeSubmissionCount, 0);
        for (uint256 i; i < MANAGER.MAX_ACTIVE_SUBMISSIONS(); ++i) {
            _submitExtra(id, address(uint160(0x4000 + i)), uint128(i));
        }
        bytes32 old = MANAGER.activeSubmissionByTrader(id, address(0x4000));
        _submitExtra(id, address(0x4000), 999);
        assertEq(
            uint8(MANAGER.getSubmissionState(old).status),
            uint8(AlphaEngineCompetitionStrategyManager.SubmissionStatus.Superseded)
        );
        assertEq(MANAGER.getCompetition(id).activeSubmissionCount, MANAGER.MAX_ACTIVE_SUBMISSIONS());
        bytes32 beforeHash = _snapshot(id);
        uint256 verified = taskManager.batchVerificationCount();
        address newcomer = address(0x5000);
        externalEuint128 market = createExternalEuint128(1, newcomer);
        externalEuint128[] memory components = new externalEuint128[](1);
        components[0] = createExternalEuint128(2, newcomer);
        bytes memory proof = _strategyProof(address(MANAGER), market, components);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.MaximumActiveSubmissionsReached.selector, id
            )
        );
        vm.prank(newcomer);
        MANAGER.submitCompetitionStrategy(id, keccak256("1h"), market, components, proof);
        assertEq(taskManager.batchVerificationCount(), verified);
        assertEq(_snapshot(id), beforeHash);
        ++rejectedLifecycleAttempts;
    }

    function _submitExtra(bytes32 id, address trader, uint128 value) private {
        externalEuint128 market = createExternalEuint128(value, trader);
        externalEuint128[] memory components = new externalEuint128[](1);
        components[0] = createExternalEuint128(value, trader);
        bytes memory proof = _strategyProof(address(MANAGER), market, components);
        bytes32 previous = MANAGER.activeSubmissionByTrader(id, trader);
        vm.prank(trader);
        bytes32 submission =
            MANAGER.submitCompetitionStrategy(id, keccak256("1h"), market, components, proof);
        _recordSuccessfulSubmission(trader, submission);
        if (previous == bytes32(0)) ++_counts[id].active;
        else ++successfulReplacements;
    }

    function _recordSuccessfulSubmission(address trader, bytes32 submission) private {
        uint64 nonce = successfulSubmissions[trader];
        uint40 timestamp = uint40(vm.getBlockTimestamp());
        _submissionIds.push(submission);
        acceptedAt[trader][nonce] = timestamp;
        successfulSubmissions[trader] = nonce + 1;
        AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
            MANAGER.getSubmissionState(submission);
        assertEq(state.traderNonce, nonce);
        assertEq(state.createdAt, timestamp);
        assertEq(MANAGER.traderNonces(trader), nonce + 1);
    }

    /// @dev CM-08: late submissions fail before verification and cannot change the frozen final entry.
    function attemptLateSubmission(uint256 seed) external {
        bytes32 id = _selected();
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(id);
        if (
            competition.status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active
                || block.timestamp < competition.submissionDeadline
        ) return;
        bytes32 beforeHash = _snapshot(id);
        uint256 verified = taskManager.batchVerificationCount();
        address trader = traderAt(seed);
        externalEuint128 market = createExternalEuint128(1, trader);
        externalEuint128[] memory components = new externalEuint128[](1);
        components[0] = createExternalEuint128(2, trader);
        bytes memory proof = _strategyProof(address(MANAGER), market, components);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionSubmissionClosed.selector,
                id,
                competition.submissionDeadline,
                block.timestamp
            )
        );
        vm.prank(trader);
        MANAGER.submitCompetitionStrategy(id, keccak256("1h"), market, components, proof);
        assertEq(_snapshot(id), beforeHash);
        assertEq(taskManager.batchVerificationCount(), verified);
        ++rejectedLifecycleAttempts;
    }

    /// @dev CM-19: rotating any processing role cannot silently preserve the former role holder's authority.
    function processingRoleCycle(uint8 seed) external {
        bytes32 role = seed % 3 == 0
            ? MANAGER.FINALIZER_ROLE()
            : seed % 3 == 1 ? MANAGER.QUALIFIER_ROLE() : MANAGER.SCORE_REVEALER_ROLE();
        bytes32 beforeHash = _allSnapshot();
        vm.prank(ADMIN);
        MANAGER.revokeRole(role, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role
            )
        );
        if (seed % 3 == 0) MANAGER.finalizeCompetition(_selected());
        else if (seed % 3 == 1) MANAGER.publishTraderQualification(bytes32(uint256(1)));
        else MANAGER.requestCompetitionScoreReveal(_selected(), 1, 1);
        vm.prank(ADMIN);
        MANAGER.grantRole(role, address(this));
        assertEq(_allSnapshot(), beforeHash);
        ++successfulGovernanceCycles;
    }

    /// @dev CM-20: pause selectors are checked in every selected phase; score reveal remains available.
    function pausePhaseProbe() external {
        bytes32 id = _selected();
        bytes32 beforeHash = _snapshot(id);
        vm.prank(PAUSER);
        MANAGER.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        MANAGER.beginEvaluation(id);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        MANAGER.finalizeCompetition(id);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        MANAGER.publishTraderQualification(bytes32(uint256(1)));
        assertEq(_snapshot(id), beforeHash);
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            MANAGER.getCompetition(id);
        if (
            competition.status == AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active
                && block.timestamp < competition.submissionDeadline
        ) {
            for (uint256 i; i < _submissionIds.length; ++i) {
                bytes32 submission = _submissionIds[i];
                if (
                    MANAGER.getSubmissionIdentity(submission).competitionId == id
                        && MANAGER.getSubmissionState(submission).status
                            == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Submitted
                ) {
                    this.cancel(i);
                    break;
                }
            }
        }
        if (
            MANAGER.getCompetition(id).status
                == AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized
        ) {
            this.requestScoreReveal(1, 0);
        }
        vm.prank(ADMIN);
        MANAGER.unpause();
        ++successfulGovernanceCycles;
    }

    /// @dev CM-10/CM-12: finalized/cancelled competitions cannot be finalized again.
    function attemptTerminalFinalization() external {
        bytes32 id = _selected();
        AlphaEngineCompetitionStrategyManager.CompetitionStatus status =
        MANAGER.getCompetition(id).status;
        if (
            status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized
                && status != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Cancelled
        ) return;
        bytes32 beforeHash = _snapshot(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionNotEvaluating.selector, id, status
            )
        );
        MANAGER.finalizeCompetition(id);
        assertEq(_snapshot(id), beforeHash);
        ++rejectedLifecycleAttempts;
    }

    function attemptInvalidRevealBatch(bool oversized) external {
        bytes32 id = _selected();
        if (
            MANAGER.getCompetition(id).status
                != AlphaEngineCompetitionStrategyManager.CompetitionStatus.Finalized
        ) return;
        uint16 count = oversized ? MANAGER.MAX_SCORE_REVEAL_BATCH() + 1 : 0;
        bytes32 beforeHash = _snapshot(id);
        uint256 pacing = MANAGER.nextScoreRevealAt();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidScoreRevealBatchSize.selector,
                count,
                MANAGER.MAX_SCORE_REVEAL_BATCH()
            )
        );
        MANAGER.requestCompetitionScoreReveal(id, 1, count);
        assertEq(_snapshot(id), beforeHash);
        assertEq(MANAGER.nextScoreRevealAt(), pacing);
        ++rejectedLifecycleAttempts;
    }

    function _selected() private view returns (bytes32) {
        return _competitionIds[selectedCompetitionIndex];
    }

    function _scores(uint32 score)
        private
        returns (AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory)
    {
        return _withScoreProof(
            address(MANAGER),
            AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission({
                realSisterScore: createExternalEuint32(score, address(this)),
                perturbationP25Score: createExternalEuint32(score + 1, address(this)),
                stressP25Score: createExternalEuint32(score + 2, address(this)),
                inputProof: ""
            })
        );
    }

    function _snapshot(bytes32 competitionId) private view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                MANAGER.getCompetition(competitionId), MANAGER.scoreRevealedThrough(competitionId)
            )
        );
        for (uint256 i; i < _submissionIds.length; ++i) {
            bytes32 id = _submissionIds[i];
            AlphaEngineCompetitionStrategyManager.SubmissionIdentity memory identity =
                MANAGER.getSubmissionIdentity(id);
            if (identity.competitionId != competitionId) continue;
            AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
                MANAGER.getSubmissionState(id);
            result = keccak256(
                abi.encode(
                    result,
                    identity,
                    state,
                    MANAGER.getSubmissionComponents(id),
                    MANAGER.activeSubmissionByTrader(competitionId, identity.trader),
                    MANAGER.traderNonces(identity.trader)
                )
            );
            // Historical snapshots omit allowance eligibility because it changes with time/configuration.
            assertTrue(
                taskManager.isAllowed(
                    uint256(identity.marketIdHandle), identity.operatorAtSubmission
                )
            );
            assertTrue(taskManager.isAllowed(uint256(identity.marketIdHandle), address(MANAGER)));
            bytes32[] memory components = MANAGER.getSubmissionComponents(id);
            for (uint256 j; j < components.length; ++j) {
                assertTrue(
                    taskManager.isAllowed(uint256(components[j]), identity.operatorAtSubmission)
                );
                assertTrue(taskManager.isAllowed(uint256(components[j]), address(MANAGER)));
            }
            if (state.status == AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated) {
                AlphaEngineCompetitionStrategyManager.EvaluationRecord memory evaluation =
                    MANAGER.getEvaluation(id);
                result = keccak256(
                    abi.encode(
                        result,
                        evaluation,
                        MANAGER.submissionByRank(competitionId, state.rank),
                        taskManager.publicAllowCount(uint256(evaluation.realSisterScoreHandle)),
                        taskManager.publicAllowCount(
                            uint256(evaluation.perturbationP25ScoreHandle)
                        ),
                        taskManager.publicAllowCount(uint256(evaluation.stressP25ScoreHandle))
                    )
                );
            }
        }
    }

    function _allSnapshot() private view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                MANAGER.defaultAdmin(),
                address(MANAGER.qualificationRegistry()),
                MANAGER.paused(),
                MANAGER.hasRole(MANAGER.PAUSER_ROLE(), PAUSER),
                MANAGER.hasRole(MANAGER.COMPETITION_CREATOR_ROLE(), address(this)),
                MANAGER.hasRole(MANAGER.COMPETITION_CANCELLER_ROLE(), address(this)),
                MANAGER.hasRole(MANAGER.EVALUATOR_ROLE(), address(this)),
                MANAGER.hasRole(MANAGER.FINALIZER_ROLE(), address(this)),
                MANAGER.hasRole(MANAGER.QUALIFIER_ROLE(), address(this)),
                MANAGER.hasRole(MANAGER.SCORE_REVEALER_ROLE(), address(this))
            )
        );
        for (uint256 i; i < _competitionIds.length; ++i) {
            result = keccak256(abi.encode(result, _snapshot(_competitionIds[i])));
        }
    }

    function submissionAt(uint256 index) external view returns (bytes32) {
        return _submissionIds[index];
    }

    function traderAt(uint256 seed) public pure returns (address) {
        return address(uint160(0x2000 + (seed % TRADER_COUNT)));
    }
}
