// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    FHE,
    externalEuint32,
    externalEuint128,
    euint32,
    euint128
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {
    IAlphaEngineTraderQualificationRegistry
} from "../interfaces/IAlphaEngineTraderQualificationRegistry.sol";
import {AlphaEngineStrategyHashLib} from "../libraries/AlphaEngineStrategyHashLib.sol";

/// @title AlphaEngineCompetitionStrategyManager
/// @notice Runs confidential strategy competitions and publishes trader-level qualification.
/// @dev This contract never approves capital execution and never holds user or treasury assets.
contract AlphaEngineCompetitionStrategyManager is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint48 public constant DEFAULT_ADMIN_DELAY = 48 hours;
    uint256 public constant MAX_COMPONENT_COUNT = 16;
    uint16 public constant MAX_ACTIVE_SUBMISSIONS = 256;
    uint16 public constant MAX_SCORE_REVEAL_BATCH = 32;

    bytes32 public constant COMPETITION_CREATOR_ROLE = keccak256("COMPETITION_CREATOR_ROLE");
    bytes32 public constant COMPETITION_CANCELLER_ROLE = keccak256("COMPETITION_CANCELLER_ROLE");
    bytes32 public constant EVALUATOR_ROLE = keccak256("EVALUATOR_ROLE");
    bytes32 public constant FINALIZER_ROLE = keccak256("FINALIZER_ROLE");
    bytes32 public constant QUALIFIER_ROLE = keccak256("QUALIFIER_ROLE");
    bytes32 public constant SCORE_REVEALER_ROLE = keccak256("SCORE_REVEALER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    enum CompetitionStatus {
        Unset,
        Active,
        Evaluating,
        Finalized,
        Cancelled
    }

    enum SubmissionStatus {
        Unset,
        Submitted,
        Cancelled,
        Evaluated
    }

    struct InitializationParams {
        address initialDefaultAdmin;
        address initialPauser;
        address initialFheOperator;
        address qualificationRegistry;
    }

    struct CompetitionConfig {
        bytes32 rulesHash;
        uint40 submissionDeadline;
        uint40 evaluationDeadline;
        uint40 qualificationValidUntil;
        uint16 qualificationSlots;
    }

    struct CompetitionRecord {
        bytes32 rulesHash;
        uint40 submissionDeadline;
        uint40 evaluationDeadline;
        uint40 qualificationValidUntil;
        uint64 competitionNonce;
        uint16 qualificationSlots;
        uint16 activeSubmissionCount;
        uint16 evaluatedCount;
        uint16 publishedQualificationCount;
        CompetitionStatus status;
    }

    struct SubmissionRecord {
        address trader;
        address operatorAtSubmission;
        bytes32 competitionId;
        bytes32 marketIdHandle;
        bytes32 timeframeKey;
        bytes32 payloadHash;
        uint40 evaluationDeadline;
        uint40 createdAt;
        uint64 traderNonce;
        uint16 rank;
        uint8 componentCount;
        SubmissionStatus status;
        bool qualificationPublished;
    }

    struct SubmissionIdentity {
        address trader;
        address operatorAtSubmission;
        bytes32 competitionId;
        bytes32 marketIdHandle;
        bytes32 timeframeKey;
        bytes32 payloadHash;
    }

    struct SubmissionState {
        uint40 evaluationDeadline;
        uint40 createdAt;
        uint64 traderNonce;
        uint16 rank;
        uint8 componentCount;
        SubmissionStatus status;
        bool qualificationPublished;
    }

    struct EvaluationScoreSubmission {
        externalEuint32 realSisterScore;
        externalEuint32 perturbationP25Score;
        externalEuint32 stressP25Score;
        bytes inputProof;
    }

    struct EvaluationRecord {
        bytes32 realSisterScoreHandle;
        bytes32 perturbationP25ScoreHandle;
        bytes32 stressP25ScoreHandle;
        bytes32 evidenceHash;
    }

    struct PublicEvaluationScores {
        uint32 realSisterScore;
        uint32 perturbationP25Score;
        uint32 stressP25Score;
        bool realSisterScoreReady;
        bool perturbationP25ScoreReady;
        bool stressP25ScoreReady;
    }

    error ZeroInitializationAddress(bytes32 field);
    error InvalidQualificationRegistry(address registry);
    error ZeroFheOperator();
    error ZeroRulesHash();
    error ZeroTimeframeKey();
    error ZeroEvidenceHash();
    error ZeroEncryptedHandle(bytes32 field, uint256 index);
    error DeadlineNotInFuture(uint40 deadline, uint256 currentTimestamp);
    error InvalidCompetitionSchedule(
        uint40 submissionDeadline, uint40 evaluationDeadline, uint40 qualificationValidUntil
    );
    error InvalidQualificationSlots(uint16 qualificationSlots);
    error InvalidComponentCount(uint256 componentCount);
    error CompetitionNotFound(bytes32 competitionId);
    error CompetitionNotActive(bytes32 competitionId, CompetitionStatus status);
    error CompetitionNotEvaluating(bytes32 competitionId, CompetitionStatus status);
    error CompetitionNotFinalized(bytes32 competitionId, CompetitionStatus status);
    error CompetitionSubmissionClosed(
        bytes32 competitionId, uint40 submissionDeadline, uint256 currentTimestamp
    );
    error CompetitionEvaluationNotStarted(
        bytes32 competitionId, uint40 submissionDeadline, uint256 currentTimestamp
    );
    error CompetitionEvaluationClosed(
        bytes32 competitionId, uint40 evaluationDeadline, uint256 currentTimestamp
    );
    error CompetitionHasNoActiveSubmissions(bytes32 competitionId);
    error CompetitionEvaluationIncomplete(
        bytes32 competitionId, uint16 evaluatedCount, uint16 activeSubmissionCount
    );
    error CompetitionCancellationNotAvailable(
        bytes32 competitionId, CompetitionStatus status, uint256 currentTimestamp
    );
    error MaximumActiveSubmissionsReached(bytes32 competitionId);
    error ActiveSubmissionAlreadyExists(
        bytes32 competitionId, address trader, bytes32 submissionId
    );
    error SubmissionNotFound(bytes32 submissionId);
    error SubmissionNotSubmitted(bytes32 submissionId, SubmissionStatus status);
    error UnauthorizedSubmissionCancellation(address actor, bytes32 submissionId);
    error InvalidRank(bytes32 competitionId, uint16 rank, uint16 activeSubmissionCount);
    error RankAlreadyAssigned(bytes32 competitionId, uint16 rank, bytes32 submissionId);
    error SubmissionNotEligible(bytes32 submissionId, uint16 rank, uint16 qualificationSlots);
    error QualificationAlreadyPublished(bytes32 submissionId);
    error InvalidScoreRevealStartRank(
        bytes32 competitionId, uint16 startRank, uint16 activeSubmissionCount
    );
    error InvalidScoreRevealBatchSize(uint16 requestedSize, uint16 maximumSize);
    error CompetitionNonceExhausted();
    error TraderNonceExhausted(address trader);

    event CompetitionCreated(
        bytes32 indexed competitionId,
        uint64 indexed competitionNonce,
        bytes32 indexed rulesHash,
        uint40 submissionDeadline,
        uint40 evaluationDeadline,
        uint40 qualificationValidUntil,
        uint16 qualificationSlots
    );
    event CompetitionEvaluationStarted(bytes32 indexed competitionId, address indexed actor);
    event CompetitionCancelled(bytes32 indexed competitionId, address indexed actor);
    event CompetitionStrategySubmitted(
        bytes32 indexed submissionId,
        bytes32 indexed competitionId,
        address indexed trader,
        bytes32 marketIdHandle,
        bytes32 timeframeKey,
        uint40 evaluationDeadline,
        bytes32 payloadHash,
        uint64 traderNonce,
        address operatorAtSubmission
    );
    event CompetitionStrategyComponents(bytes32 indexed submissionId, bytes32[] componentHandles);
    event CompetitionStrategyCancelled(
        bytes32 indexed submissionId, bytes32 indexed competitionId, address indexed trader
    );
    event CompetitionEvaluationRecorded(
        bytes32 indexed submissionId,
        bytes32 indexed competitionId,
        address indexed trader,
        uint16 rank,
        bytes32 realSisterScoreHandle,
        bytes32 perturbationP25ScoreHandle,
        bytes32 stressP25ScoreHandle,
        bytes32 evidenceHash
    );
    event CompetitionFinalized(
        bytes32 indexed competitionId, uint16 activeSubmissionCount, uint16 qualificationSlots
    );
    event CompetitionScoreRevealRequested(
        bytes32 indexed competitionId,
        bytes32 indexed submissionId,
        address indexed trader,
        uint16 rank,
        bytes32 realSisterScoreHandle,
        bytes32 perturbationP25ScoreHandle,
        bytes32 stressP25ScoreHandle
    );
    event TraderQualificationPublished(
        bytes32 indexed competitionId,
        bytes32 indexed submissionId,
        address indexed trader,
        uint16 rank,
        uint64 qualificationVersion,
        uint40 validUntil,
        bytes32 evidenceHash
    );
    event FheOperatorUpdated(address indexed previousOperator, address indexed newOperator);

    IAlphaEngineTraderQualificationRegistry public qualificationRegistry;
    address public fheOperator;
    uint64 public competitionNonce;

    mapping(bytes32 competitionId => CompetitionRecord competition) private _competitions;
    mapping(bytes32 submissionId => SubmissionRecord submission) private _submissions;
    mapping(bytes32 submissionId => bytes32[] componentHandles) private _submissionComponents;
    mapping(bytes32 submissionId => EvaluationRecord evaluation) private _evaluations;
    mapping(address trader => uint64 nonce) public traderNonces;
    mapping(bytes32 competitionId => mapping(address trader => bytes32 submissionId)) private
        _activeSubmissionByTrader;
    mapping(bytes32 competitionId => mapping(uint16 rank => bytes32 submissionId)) private
        _submissionByRank;

    /// @dev Nine repository-owned storage slots above plus this gap reserve 50 slots.
    uint256[41] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitializationParams calldata params) external initializer {
        _validateInitialization(params);

        __AccessControlDefaultAdminRules_init(DEFAULT_ADMIN_DELAY, params.initialDefaultAdmin);
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(PAUSER_ROLE, params.initialPauser);

        qualificationRegistry =
            IAlphaEngineTraderQualificationRegistry(params.qualificationRegistry);
        fheOperator = params.initialFheOperator;
        _pause();
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function updateFheOperator(address newOperator)
        external
        whenPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newOperator == address(0)) {
            revert ZeroFheOperator();
        }
        address previousOperator = fheOperator;
        fheOperator = newOperator;
        emit FheOperatorUpdated(previousOperator, newOperator);
    }

    function createCompetition(CompetitionConfig calldata config)
        external
        whenNotPaused
        onlyRole(COMPETITION_CREATOR_ROLE)
        returns (bytes32 competitionId)
    {
        _validateCompetitionConfig(config);

        uint64 currentNonce = competitionNonce;
        if (currentNonce == type(uint64).max) {
            revert CompetitionNonceExhausted();
        }
        competitionId = AlphaEngineStrategyHashLib.hashCompetitionId(
            block.chainid, address(this), currentNonce, config.rulesHash
        );

        _competitions[competitionId] = CompetitionRecord({
            rulesHash: config.rulesHash,
            submissionDeadline: config.submissionDeadline,
            evaluationDeadline: config.evaluationDeadline,
            qualificationValidUntil: config.qualificationValidUntil,
            competitionNonce: currentNonce,
            qualificationSlots: config.qualificationSlots,
            activeSubmissionCount: 0,
            evaluatedCount: 0,
            publishedQualificationCount: 0,
            status: CompetitionStatus.Active
        });
        competitionNonce = currentNonce + 1;

        emit CompetitionCreated(
            competitionId,
            currentNonce,
            config.rulesHash,
            config.submissionDeadline,
            config.evaluationDeadline,
            config.qualificationValidUntil,
            config.qualificationSlots
        );
    }

    function submitCompetitionStrategy(
        bytes32 competitionId,
        bytes32 timeframeKey,
        externalEuint128 encryptedMarketId,
        externalEuint128[] calldata encryptedComponents,
        bytes calldata inputProof
    ) external whenNotPaused nonReentrant returns (bytes32 submissionId) {
        CompetitionRecord storage competition = _getCompetition(competitionId);
        if (competition.status != CompetitionStatus.Active) {
            revert CompetitionNotActive(competitionId, competition.status);
        }
        if (block.timestamp >= competition.submissionDeadline) {
            revert CompetitionSubmissionClosed(
                competitionId, competition.submissionDeadline, block.timestamp
            );
        }
        if (timeframeKey == bytes32(0)) {
            revert ZeroTimeframeKey();
        }
        uint256 componentCount = encryptedComponents.length;
        if (componentCount == 0 || componentCount > MAX_COMPONENT_COUNT) {
            revert InvalidComponentCount(componentCount);
        }
        if (competition.activeSubmissionCount >= MAX_ACTIVE_SUBMISSIONS) {
            revert MaximumActiveSubmissionsReached(competitionId);
        }

        bytes32 activeSubmissionId = _activeSubmissionByTrader[competitionId][msg.sender];
        if (activeSubmissionId != bytes32(0)) {
            revert ActiveSubmissionAlreadyExists(competitionId, msg.sender, activeSubmissionId);
        }

        uint64 traderNonce = traderNonces[msg.sender];
        if (traderNonce == type(uint64).max) {
            revert TraderNonceExhausted(msg.sender);
        }
        submissionId = AlphaEngineStrategyHashLib.hashCompetitionSubmissionId(
            block.chainid, address(this), competitionId, msg.sender, traderNonce
        );

        address operatorAtSubmission = fheOperator;
        (bytes32 marketIdHandle, bytes32[] memory componentHandles) = _internalizeStrategy(
            submissionId, encryptedMarketId, encryptedComponents, inputProof, operatorAtSubmission
        );
        bytes32 payloadHash = AlphaEngineStrategyHashLib.hashCompetitionPayload(
            AlphaEngineStrategyHashLib.CompetitionPayloadV1({
                chainId: block.chainid,
                manager: address(this),
                submissionId: submissionId,
                competitionId: competitionId,
                trader: msg.sender,
                traderNonce: traderNonce,
                marketIdHandle: marketIdHandle,
                timeframeKey: timeframeKey,
                evaluationDeadline: competition.evaluationDeadline,
                componentsHash: AlphaEngineStrategyHashLib.hashComponents(componentHandles)
            })
        );

        _submissions[submissionId] = SubmissionRecord({
            trader: msg.sender,
            operatorAtSubmission: operatorAtSubmission,
            competitionId: competitionId,
            marketIdHandle: marketIdHandle,
            timeframeKey: timeframeKey,
            payloadHash: payloadHash,
            evaluationDeadline: competition.evaluationDeadline,
            createdAt: uint40(block.timestamp),
            traderNonce: traderNonce,
            rank: 0,
            componentCount: uint8(componentCount),
            status: SubmissionStatus.Submitted,
            qualificationPublished: false
        });
        _activeSubmissionByTrader[competitionId][msg.sender] = submissionId;
        competition.activeSubmissionCount += 1;
        traderNonces[msg.sender] = traderNonce + 1;

        emit CompetitionStrategySubmitted(
            submissionId,
            competitionId,
            msg.sender,
            marketIdHandle,
            timeframeKey,
            competition.evaluationDeadline,
            payloadHash,
            traderNonce,
            operatorAtSubmission
        );
        emit CompetitionStrategyComponents(submissionId, componentHandles);
    }

    function cancelCompetitionSubmission(bytes32 submissionId) external {
        SubmissionRecord storage submission = _getSubmission(submissionId);
        if (submission.trader != msg.sender) {
            revert UnauthorizedSubmissionCancellation(msg.sender, submissionId);
        }
        if (submission.status != SubmissionStatus.Submitted) {
            revert SubmissionNotSubmitted(submissionId, submission.status);
        }

        CompetitionRecord storage competition = _competitions[submission.competitionId];
        if (
            competition.status != CompetitionStatus.Active
                || block.timestamp >= competition.submissionDeadline
        ) {
            revert CompetitionSubmissionClosed(
                submission.competitionId, competition.submissionDeadline, block.timestamp
            );
        }

        submission.status = SubmissionStatus.Cancelled;
        delete _activeSubmissionByTrader[submission.competitionId][submission.trader];
        competition.activeSubmissionCount -= 1;

        emit CompetitionStrategyCancelled(submissionId, submission.competitionId, submission.trader);
    }

    function beginEvaluation(bytes32 competitionId) external whenNotPaused {
        CompetitionRecord storage competition = _getCompetition(competitionId);
        if (competition.status != CompetitionStatus.Active) {
            revert CompetitionNotActive(competitionId, competition.status);
        }
        if (block.timestamp < competition.submissionDeadline) {
            revert CompetitionEvaluationNotStarted(
                competitionId, competition.submissionDeadline, block.timestamp
            );
        }
        if (block.timestamp > competition.evaluationDeadline) {
            revert CompetitionEvaluationClosed(
                competitionId, competition.evaluationDeadline, block.timestamp
            );
        }
        if (competition.activeSubmissionCount == 0) {
            revert CompetitionHasNoActiveSubmissions(competitionId);
        }

        competition.status = CompetitionStatus.Evaluating;
        emit CompetitionEvaluationStarted(competitionId, msg.sender);
    }

    function recordEvaluation(
        bytes32 submissionId,
        EvaluationScoreSubmission calldata scores,
        uint16 rank,
        bytes32 evidenceHash
    ) external whenNotPaused nonReentrant onlyRole(EVALUATOR_ROLE) {
        if (evidenceHash == bytes32(0)) {
            revert ZeroEvidenceHash();
        }
        SubmissionRecord storage submission = _getSubmission(submissionId);
        if (submission.status != SubmissionStatus.Submitted) {
            revert SubmissionNotSubmitted(submissionId, submission.status);
        }
        CompetitionRecord storage competition = _competitions[submission.competitionId];
        if (competition.status != CompetitionStatus.Evaluating) {
            revert CompetitionNotEvaluating(submission.competitionId, competition.status);
        }
        if (block.timestamp > competition.evaluationDeadline) {
            revert CompetitionEvaluationClosed(
                submission.competitionId, competition.evaluationDeadline, block.timestamp
            );
        }
        if (rank == 0 || rank > competition.activeSubmissionCount) {
            revert InvalidRank(submission.competitionId, rank, competition.activeSubmissionCount);
        }
        bytes32 rankedSubmissionId = _submissionByRank[submission.competitionId][rank];
        if (rankedSubmissionId != bytes32(0)) {
            revert RankAlreadyAssigned(submission.competitionId, rank, rankedSubmissionId);
        }

        bytes32[3] memory scoreHandles = _internalizeScores(submission.trader, scores);
        _evaluations[submissionId] = EvaluationRecord({
            realSisterScoreHandle: scoreHandles[0],
            perturbationP25ScoreHandle: scoreHandles[1],
            stressP25ScoreHandle: scoreHandles[2],
            evidenceHash: evidenceHash
        });
        submission.rank = rank;
        submission.status = SubmissionStatus.Evaluated;
        _submissionByRank[submission.competitionId][rank] = submissionId;
        competition.evaluatedCount += 1;

        emit CompetitionEvaluationRecorded(
            submissionId,
            submission.competitionId,
            submission.trader,
            rank,
            scoreHandles[0],
            scoreHandles[1],
            scoreHandles[2],
            evidenceHash
        );
    }

    function finalizeCompetition(bytes32 competitionId)
        external
        whenNotPaused
        onlyRole(FINALIZER_ROLE)
    {
        CompetitionRecord storage competition = _getCompetition(competitionId);
        if (competition.status != CompetitionStatus.Evaluating) {
            revert CompetitionNotEvaluating(competitionId, competition.status);
        }
        if (competition.evaluatedCount != competition.activeSubmissionCount) {
            revert CompetitionEvaluationIncomplete(
                competitionId, competition.evaluatedCount, competition.activeSubmissionCount
            );
        }

        competition.status = CompetitionStatus.Finalized;
        emit CompetitionFinalized(
            competitionId, competition.activeSubmissionCount, competition.qualificationSlots
        );
    }

    /// @notice Requests asynchronous public decryption of finalized evaluation scores by rank.
    /// @dev Results are published by CoFHE and exposed through `getPublicEvaluationScores`.
    function requestCompetitionScoreReveal(
        bytes32 competitionId,
        uint16 startRank,
        uint16 maxSubmissions
    )
        external
        nonReentrant
        onlyRole(SCORE_REVEALER_ROLE)
        returns (uint16 nextRank, uint16 requestedSubmissionCount)
    {
        CompetitionRecord storage competition = _getCompetition(competitionId);
        if (competition.status != CompetitionStatus.Finalized) {
            revert CompetitionNotFinalized(competitionId, competition.status);
        }
        if (startRank == 0 || startRank > competition.activeSubmissionCount) {
            revert InvalidScoreRevealStartRank(
                competitionId, startRank, competition.activeSubmissionCount
            );
        }
        if (maxSubmissions == 0 || maxSubmissions > MAX_SCORE_REVEAL_BATCH) {
            revert InvalidScoreRevealBatchSize(maxSubmissions, MAX_SCORE_REVEAL_BATCH);
        }

        uint16 endRankExclusive = startRank + maxSubmissions;
        uint16 competitionEndRankExclusive = competition.activeSubmissionCount + 1;
        if (endRankExclusive > competitionEndRankExclusive) {
            endRankExclusive = competitionEndRankExclusive;
        }

        for (uint16 rank = startRank; rank < endRankExclusive; ++rank) {
            bytes32 submissionId = _submissionByRank[competitionId][rank];
            SubmissionRecord storage submission = _submissions[submissionId];
            EvaluationRecord storage evaluation = _evaluations[submissionId];

            FHE.allowPublic(FHE.wrapEuint32(evaluation.realSisterScoreHandle));
            FHE.allowPublic(FHE.wrapEuint32(evaluation.perturbationP25ScoreHandle));
            FHE.allowPublic(FHE.wrapEuint32(evaluation.stressP25ScoreHandle));

            emit CompetitionScoreRevealRequested(
                competitionId,
                submissionId,
                submission.trader,
                rank,
                evaluation.realSisterScoreHandle,
                evaluation.perturbationP25ScoreHandle,
                evaluation.stressP25ScoreHandle
            );
        }

        nextRank = endRankExclusive;
        requestedSubmissionCount = endRankExclusive - startRank;
    }

    function publishTraderQualification(bytes32 submissionId)
        external
        whenNotPaused
        nonReentrant
        onlyRole(QUALIFIER_ROLE)
        returns (uint64 qualificationVersion)
    {
        SubmissionRecord storage submission = _getSubmission(submissionId);
        CompetitionRecord storage competition = _competitions[submission.competitionId];
        if (competition.status != CompetitionStatus.Finalized) {
            revert CompetitionNotFinalized(submission.competitionId, competition.status);
        }
        if (
            submission.status != SubmissionStatus.Evaluated || submission.rank == 0
                || submission.rank > competition.qualificationSlots
        ) {
            revert SubmissionNotEligible(
                submissionId, submission.rank, competition.qualificationSlots
            );
        }
        if (submission.qualificationPublished) {
            revert QualificationAlreadyPublished(submissionId);
        }

        submission.qualificationPublished = true;
        competition.publishedQualificationCount += 1;
        EvaluationRecord storage evaluation = _evaluations[submissionId];
        qualificationVersion = qualificationRegistry.qualifyTrader(
            submission.trader,
            competition.qualificationValidUntil,
            submission.competitionId,
            evaluation.evidenceHash
        );

        emit TraderQualificationPublished(
            submission.competitionId,
            submissionId,
            submission.trader,
            submission.rank,
            qualificationVersion,
            competition.qualificationValidUntil,
            evaluation.evidenceHash
        );
    }

    function cancelCompetition(bytes32 competitionId)
        external
        onlyRole(COMPETITION_CANCELLER_ROLE)
    {
        CompetitionRecord storage competition = _getCompetition(competitionId);
        if (
            competition.status != CompetitionStatus.Active
                && competition.status != CompetitionStatus.Evaluating
        ) {
            revert CompetitionCancellationNotAvailable(
                competitionId, competition.status, block.timestamp
            );
        }
        _cancelCompetition(competitionId, competition);
    }

    function cancelExpiredCompetition(bytes32 competitionId) external {
        CompetitionRecord storage competition = _getCompetition(competitionId);
        if (
            (competition.status != CompetitionStatus.Active
                    && competition.status != CompetitionStatus.Evaluating)
                || block.timestamp <= competition.evaluationDeadline
        ) {
            revert CompetitionCancellationNotAvailable(
                competitionId, competition.status, block.timestamp
            );
        }
        _cancelCompetition(competitionId, competition);
    }

    function existsCompetition(bytes32 competitionId) external view returns (bool) {
        return _competitions[competitionId].status != CompetitionStatus.Unset;
    }

    function getCompetition(bytes32 competitionId)
        external
        view
        returns (CompetitionRecord memory competition)
    {
        competition = _getCompetition(competitionId);
    }

    function existsSubmission(bytes32 submissionId) external view returns (bool) {
        return _submissions[submissionId].status != SubmissionStatus.Unset;
    }

    function getSubmissionIdentity(bytes32 submissionId)
        external
        view
        returns (SubmissionIdentity memory identity)
    {
        SubmissionRecord storage submission = _getSubmission(submissionId);
        return SubmissionIdentity({
            trader: submission.trader,
            operatorAtSubmission: submission.operatorAtSubmission,
            competitionId: submission.competitionId,
            marketIdHandle: submission.marketIdHandle,
            timeframeKey: submission.timeframeKey,
            payloadHash: submission.payloadHash
        });
    }

    function getSubmissionState(bytes32 submissionId)
        external
        view
        returns (SubmissionState memory state)
    {
        SubmissionRecord storage submission = _getSubmission(submissionId);
        return SubmissionState({
            evaluationDeadline: submission.evaluationDeadline,
            createdAt: submission.createdAt,
            traderNonce: submission.traderNonce,
            rank: submission.rank,
            componentCount: submission.componentCount,
            status: submission.status,
            qualificationPublished: submission.qualificationPublished
        });
    }

    function getSubmissionComponents(bytes32 submissionId)
        external
        view
        returns (bytes32[] memory componentHandles)
    {
        _getSubmission(submissionId);
        return _submissionComponents[submissionId];
    }

    function getEvaluation(bytes32 submissionId)
        external
        view
        returns (EvaluationRecord memory evaluation)
    {
        SubmissionRecord storage submission = _getSubmission(submissionId);
        if (submission.status != SubmissionStatus.Evaluated) {
            revert SubmissionNotSubmitted(submissionId, submission.status);
        }
        return _evaluations[submissionId];
    }

    /// @notice Returns any asynchronously published plaintext scores after finalization.
    /// @dev Each readiness flag must be checked independently because results may arrive separately.
    function getPublicEvaluationScores(bytes32 submissionId)
        external
        view
        returns (PublicEvaluationScores memory scores)
    {
        SubmissionRecord storage submission = _getSubmission(submissionId);
        CompetitionRecord storage competition = _competitions[submission.competitionId];
        if (competition.status != CompetitionStatus.Finalized) {
            revert CompetitionNotFinalized(submission.competitionId, competition.status);
        }
        if (submission.status != SubmissionStatus.Evaluated) {
            revert SubmissionNotSubmitted(submissionId, submission.status);
        }

        EvaluationRecord storage evaluation = _evaluations[submissionId];
        (scores.realSisterScore, scores.realSisterScoreReady) =
            FHE.getDecryptResultSafe(euint32.wrap(evaluation.realSisterScoreHandle));
        (scores.perturbationP25Score, scores.perturbationP25ScoreReady) =
            FHE.getDecryptResultSafe(euint32.wrap(evaluation.perturbationP25ScoreHandle));
        (scores.stressP25Score, scores.stressP25ScoreReady) =
            FHE.getDecryptResultSafe(euint32.wrap(evaluation.stressP25ScoreHandle));
    }

    function activeSubmissionByTrader(bytes32 competitionId, address trader)
        external
        view
        returns (bytes32 submissionId)
    {
        _getCompetition(competitionId);
        return _activeSubmissionByTrader[competitionId][trader];
    }

    function submissionByRank(bytes32 competitionId, uint16 rank)
        external
        view
        returns (bytes32 submissionId)
    {
        _getCompetition(competitionId);
        return _submissionByRank[competitionId][rank];
    }

    function _validateInitialization(InitializationParams calldata params) private view {
        _requireNonZero(params.initialDefaultAdmin, "initialDefaultAdmin");
        _requireNonZero(params.initialPauser, "initialPauser");
        if (params.initialFheOperator == address(0)) {
            revert ZeroFheOperator();
        }
        if (
            params.qualificationRegistry == address(0)
                || params.qualificationRegistry.code.length == 0
        ) {
            revert InvalidQualificationRegistry(params.qualificationRegistry);
        }
    }

    function _validateCompetitionConfig(CompetitionConfig calldata config) private view {
        if (config.rulesHash == bytes32(0)) {
            revert ZeroRulesHash();
        }
        if (config.submissionDeadline <= block.timestamp) {
            revert DeadlineNotInFuture(config.submissionDeadline, block.timestamp);
        }
        if (
            config.evaluationDeadline <= config.submissionDeadline
                || config.qualificationValidUntil <= config.evaluationDeadline
        ) {
            revert InvalidCompetitionSchedule(
                config.submissionDeadline, config.evaluationDeadline, config.qualificationValidUntil
            );
        }
        if (config.qualificationSlots == 0 || config.qualificationSlots > MAX_ACTIVE_SUBMISSIONS) {
            revert InvalidQualificationSlots(config.qualificationSlots);
        }
    }

    /// @dev Verify the market and ordered components under one consumer-bound batch proof.
    function _internalizeStrategy(
        bytes32 submissionId,
        externalEuint128 encryptedMarketId,
        externalEuint128[] calldata encryptedComponents,
        bytes calldata inputProof,
        address operator
    ) private returns (bytes32 marketIdHandle, bytes32[] memory componentHandles) {
        uint256 componentCount = encryptedComponents.length;
        externalEuint128[] memory inputs = new externalEuint128[](componentCount + 1);
        inputs[0] = encryptedMarketId;
        for (uint256 index = 0; index < componentCount; ++index) {
            inputs[index + 1] = encryptedComponents[index];
        }
        euint128[] memory verified = FHE.asEuint128s(inputs, inputProof);
        marketIdHandle = FHE.unwrap(verified[0]);
        if (marketIdHandle == bytes32(0)) revert ZeroEncryptedHandle("marketId", 0);
        FHE.allowThis(verified[0]);
        FHE.allow(verified[0], operator);

        componentHandles = new bytes32[](componentCount);
        bytes32[] storage storedComponents = _submissionComponents[submissionId];
        for (uint256 index = 0; index < componentCount; ++index) {
            euint128 component = verified[index + 1];
            bytes32 componentHandle = FHE.unwrap(component);
            if (componentHandle == bytes32(0)) revert ZeroEncryptedHandle("component", index);
            FHE.allowThis(component);
            FHE.allow(component, operator);
            componentHandles[index] = componentHandle;
            storedComponents.push(componentHandle);
        }
    }

    function _internalizeScores(address trader, EvaluationScoreSubmission calldata scores)
        private
        returns (bytes32[3] memory scoreHandles)
    {
        externalEuint32[] memory encryptedScores = new externalEuint32[](3);
        encryptedScores[0] = scores.realSisterScore;
        encryptedScores[1] = scores.perturbationP25Score;
        encryptedScores[2] = scores.stressP25Score;
        euint32[] memory verified = FHE.asEuint32s(encryptedScores, scores.inputProof);
        for (uint256 index = 0; index < encryptedScores.length; ++index) {
            euint32 internalizedScore = verified[index];
            bytes32 scoreHandle = FHE.unwrap(internalizedScore);
            if (scoreHandle == bytes32(0)) {
                revert ZeroEncryptedHandle("evaluationScore", index);
            }
            FHE.allowThis(internalizedScore);
            FHE.allow(internalizedScore, trader);
            scoreHandles[index] = scoreHandle;
        }
    }

    function _cancelCompetition(bytes32 competitionId, CompetitionRecord storage competition)
        private
    {
        competition.status = CompetitionStatus.Cancelled;
        emit CompetitionCancelled(competitionId, msg.sender);
    }

    function _getCompetition(bytes32 competitionId)
        private
        view
        returns (CompetitionRecord storage competition)
    {
        competition = _competitions[competitionId];
        if (competition.status == CompetitionStatus.Unset) {
            revert CompetitionNotFound(competitionId);
        }
    }

    function _getSubmission(bytes32 submissionId)
        private
        view
        returns (SubmissionRecord storage submission)
    {
        submission = _submissions[submissionId];
        if (submission.status == SubmissionStatus.Unset) {
            revert SubmissionNotFound(submissionId);
        }
    }

    function _requireNonZero(address account, bytes32 field) private pure {
        if (account == address(0)) {
            revert ZeroInitializationAddress(field);
        }
    }
}
