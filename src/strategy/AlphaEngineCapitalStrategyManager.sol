// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    FHE, InEuint32, InEuint128, euint32, euint128
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IAlphaEngineCapitalStrategyManager} from
    "../interfaces/IAlphaEngineCapitalStrategyManager.sol";
import {IAlphaEngineTraderQualificationRegistry} from
    "../interfaces/IAlphaEngineTraderQualificationRegistry.sol";
import {AlphaEngineExecutionHashLib} from "../libraries/AlphaEngineExecutionHashLib.sol";
import {AlphaEngineStrategyHashLib} from "../libraries/AlphaEngineStrategyHashLib.sol";

/// @title AlphaEngineCapitalStrategyManager
/// @notice Accepts fresh confidential capital intents from qualified traders and records exact,
///         one-time execution authorizations after independent evaluation.
/// @dev This contract never holds assets or calls strategy targets. An allowlisted execution
///      manager consumes an authorization before performing the downstream transaction in the
///      same call frame, so a downstream revert also rolls back consumption.
contract AlphaEngineCapitalStrategyManager is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IAlphaEngineCapitalStrategyManager
{
    uint48 public constant DEFAULT_ADMIN_DELAY = 48 hours;
    uint256 public constant MAX_COMPONENT_COUNT = 16;
    uint40 public constant MAX_AUTHORIZATION_WINDOW = 1 hours;

    bytes32 public constant EVALUATOR_ROLE = keccak256("EVALUATOR_ROLE");
    bytes32 public constant REVOCER_ROLE = keccak256("REVOCER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    enum CapitalIntentStatus {
        Unset,
        PendingEvaluation,
        Cancelled,
        Rejected,
        Approved,
        Consumed,
        Revoked,
        Expired
    }

    struct InitializationParams {
        address initialDefaultAdmin;
        address initialPauser;
        address initialFheOperator;
        address qualificationRegistry;
    }

    struct CapitalIntentRecord {
        address trader;
        address operatorAtSubmission;
        bytes32 marketIdHandle;
        bytes32 timeframeKey;
        bytes32 payloadHash;
        uint40 deadline;
        uint40 createdAt;
        uint40 authorizationDeadline;
        uint64 traderNonce;
        uint64 qualificationVersion;
        uint64 authorizationNonce;
        uint8 componentCount;
        CapitalIntentStatus status;
    }

    struct CapitalIntentIdentity {
        address trader;
        address operatorAtSubmission;
        bytes32 marketIdHandle;
        bytes32 timeframeKey;
        bytes32 payloadHash;
    }

    struct CapitalIntentState {
        uint40 deadline;
        uint40 createdAt;
        uint40 authorizationDeadline;
        uint64 traderNonce;
        uint64 qualificationVersion;
        uint64 authorizationNonce;
        uint8 componentCount;
        CapitalIntentStatus status;
    }

    struct EvaluationScoreSubmission {
        InEuint32 realSisterScore;
        InEuint32 perturbationP25Score;
        InEuint32 stressP25Score;
    }

    struct EvaluationRecord {
        bytes32 realSisterScoreHandle;
        bytes32 perturbationP25ScoreHandle;
        bytes32 stressP25ScoreHandle;
        bytes32 evidenceHash;
        bytes32 reasonHash;
        bytes32 executionCommitment;
    }

    error ZeroInitializationAddress(bytes32 field);
    error InvalidQualificationRegistry(address registry);
    error ZeroFheOperator();
    error ZeroTimeframeKey();
    error ZeroEvidenceHash();
    error ZeroReasonHash();
    error ZeroEncryptedHandle(bytes32 field, uint256 index);
    error DeadlineNotInFuture(uint40 deadline, uint256 currentTimestamp);
    error DeadlineExceedsQualification(
        uint40 deadline, uint40 qualificationValidUntil, uint64 qualificationVersion
    );
    error InvalidComponentCount(uint256 componentCount);
    error TraderNotQualified(address trader);
    error QualificationVersionNotActive(address trader, uint64 qualificationVersion);
    error CapitalIntentNotFound(bytes32 intentId);
    error InvalidCapitalIntentStatus(bytes32 intentId, CapitalIntentStatus status);
    error UnauthorizedIntentCancellation(address actor, bytes32 intentId);
    error TraderNonceExhausted(address trader);
    error AuthorizationNonceExhausted();
    error AuthorizationNonceMismatch(uint64 supplied, uint64 expected);
    error InvalidAuthorizationDomain(
        uint256 chainId, address capitalStrategyManager, bytes32 intentId, address trader
    );
    error InvalidAuthorizationQualification(uint64 supplied, uint64 expected);
    error InvalidVaultExecutionManager(address manager);
    error ExecutionManagerNotAuthorized(address manager);
    error ExecutionManagerAuthorizationUnchanged(address manager, bool authorized);
    error InvalidFundVault(address fundVault);
    error ZeroExecutor();
    error InvalidAuthorizationWindow(uint40 validAfter, uint40 deadline);
    error AuthorizationWindowTooLong(uint40 suppliedWindow, uint40 maximumWindow);
    error AuthorizationDeadlineExceedsIntent(uint40 authorizationDeadline, uint40 intentDeadline);
    error InvalidAuthorizationPolicy(
        bytes32 policyRoot, uint64 policyVersion, uint64 riskPolicyVersion
    );
    error ZeroCallsHash();
    error ZeroRiskEnvelopeHash();
    error SubmissionPayloadHashMismatch(bytes32 supplied, bytes32 expected);
    error ExecutionCommitmentMismatch(bytes32 supplied, bytes32 expected);
    error UnauthorizedExecutionConsumer(address actor, address expectedManager);
    error AuthorizationNotYetActive(uint40 validAfter, uint256 currentTimestamp);
    error AuthorizationExpired(uint40 deadline, uint256 currentTimestamp);
    error ExecutionCommitmentAlreadyConsumed(bytes32 executionCommitment);
    error AuthorizationNonceAlreadyConsumed(uint64 authorizationNonce);
    error CapitalIntentNotExpirable(
        bytes32 intentId, CapitalIntentStatus status, uint40 deadline, uint256 currentTimestamp
    );

    event CapitalIntentSubmitted(
        bytes32 indexed intentId,
        address indexed trader,
        uint64 indexed qualificationVersion,
        bytes32 marketIdHandle,
        bytes32 timeframeKey,
        uint40 deadline,
        bytes32 payloadHash,
        uint64 traderNonce,
        address operatorAtSubmission
    );
    event CapitalIntentComponents(bytes32 indexed intentId, bytes32[] componentHandles);
    event CapitalEvaluationScoresRecorded(
        bytes32 indexed intentId,
        address indexed trader,
        bytes32 realSisterScoreHandle,
        bytes32 perturbationP25ScoreHandle,
        bytes32 stressP25ScoreHandle,
        bytes32 evidenceHash
    );
    event CapitalIntentRejected(
        bytes32 indexed intentId,
        address indexed trader,
        bytes32 indexed evidenceHash,
        bytes32 reasonHash
    );
    event CapitalIntentApproved(
        bytes32 indexed intentId,
        address indexed trader,
        bytes32 indexed executionCommitment,
        address vaultExecutionManager,
        address fundVault,
        address executor,
        uint64 authorizationNonce,
        uint40 validAfter,
        uint40 deadline
    );
    event CapitalExecutionPolicyCommitted(
        bytes32 indexed intentId,
        bytes32 indexed executionCommitment,
        bytes32 indexed policyRoot,
        uint64 policyVersion,
        bytes32 callsHash,
        bytes32 riskEnvelopeHash,
        uint64 riskPolicyVersion,
        bytes32 evaluationEvidenceHash
    );
    event CapitalIntentCancelled(bytes32 indexed intentId, address indexed trader);
    event CapitalIntentRevoked(
        bytes32 indexed intentId,
        address indexed trader,
        bytes32 indexed executionCommitment,
        bytes32 reasonHash
    );
    event CapitalIntentExpired(
        bytes32 indexed intentId,
        address indexed trader,
        CapitalIntentStatus previousStatus,
        uint40 deadline
    );
    event CapitalExecutionConsumed(
        bytes32 indexed intentId,
        address indexed trader,
        bytes32 indexed executionCommitment,
        address vaultExecutionManager,
        address executor,
        uint64 authorizationNonce
    );
    event FheOperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event VaultExecutionManagerAuthorizationUpdated(
        address indexed manager, bool previousAuthorization, bool newAuthorization
    );

    IAlphaEngineTraderQualificationRegistry public qualificationRegistry;
    address public fheOperator;
    uint64 public nextAuthorizationNonce;

    mapping(bytes32 intentId => CapitalIntentRecord intent) private _capitalIntents;
    mapping(bytes32 intentId => bytes32[] componentHandles) private _capitalIntentComponents;
    mapping(bytes32 intentId => EvaluationRecord evaluation) private _evaluations;
    mapping(address trader => uint64 nonce) public traderNonces;
    mapping(address manager => bool authorized) public approvedExecutionManagers;
    mapping(uint64 authorizationNonce => bytes32 intentId) public intentByAuthorizationNonce;
    mapping(bytes32 executionCommitment => bool consumed) private _consumedCommitments;
    mapping(uint64 authorizationNonce => bool consumed) public consumedAuthorizationNonces;

    /// @dev Ten repository-owned storage slots above plus this gap reserve 50 slots.
    uint256[40] private __gap;

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
        if (newOperator == address(0)) revert ZeroFheOperator();
        address previousOperator = fheOperator;
        fheOperator = newOperator;
        emit FheOperatorUpdated(previousOperator, newOperator);
    }

    function setExecutionManagerAuthorization(address manager, bool authorized)
        external
        whenPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (manager == address(0) || (authorized && manager.code.length == 0)) {
            revert InvalidVaultExecutionManager(manager);
        }
        bool previousAuthorization = approvedExecutionManagers[manager];
        if (previousAuthorization == authorized) {
            revert ExecutionManagerAuthorizationUnchanged(manager, authorized);
        }
        approvedExecutionManagers[manager] = authorized;
        emit VaultExecutionManagerAuthorizationUpdated(manager, previousAuthorization, authorized);
    }

    function submitCapitalIntent(
        InEuint128 calldata encryptedMarketId,
        bytes32 timeframeKey,
        uint40 deadline,
        InEuint128[] calldata encryptedComponents
    ) external whenNotPaused nonReentrant returns (bytes32 intentId) {
        if (timeframeKey == bytes32(0)) revert ZeroTimeframeKey();
        if (deadline <= block.timestamp) revert DeadlineNotInFuture(deadline, block.timestamp);
        uint256 componentCount = encryptedComponents.length;
        if (componentCount == 0 || componentCount > MAX_COMPONENT_COUNT) {
            revert InvalidComponentCount(componentCount);
        }

        IAlphaEngineTraderQualificationRegistry.Qualification memory qualification =
            _getActiveQualification(msg.sender);
        if (deadline > qualification.validUntil) {
            revert DeadlineExceedsQualification(
                deadline, qualification.validUntil, qualification.version
            );
        }

        uint64 traderNonce = traderNonces[msg.sender];
        if (traderNonce == type(uint64).max) revert TraderNonceExhausted(msg.sender);
        intentId = AlphaEngineStrategyHashLib.hashCapitalIntentId(
            block.chainid, address(this), msg.sender, traderNonce
        );

        address operatorAtSubmission = fheOperator;
        bytes32 marketIdHandle = _internalizeMarket(encryptedMarketId, operatorAtSubmission);
        bytes32[] memory componentHandles =
            _internalizeComponents(intentId, encryptedComponents, operatorAtSubmission);
        bytes32 payloadHash = AlphaEngineStrategyHashLib.hashCapitalPayload(
            AlphaEngineStrategyHashLib.CapitalPayloadV1({
                chainId: block.chainid,
                manager: address(this),
                intentId: intentId,
                trader: msg.sender,
                traderNonce: traderNonce,
                qualificationVersion: qualification.version,
                marketIdHandle: marketIdHandle,
                timeframeKey: timeframeKey,
                deadline: deadline,
                componentsHash: AlphaEngineStrategyHashLib.hashComponents(componentHandles)
            })
        );

        _capitalIntents[intentId] = CapitalIntentRecord({
            trader: msg.sender,
            operatorAtSubmission: operatorAtSubmission,
            marketIdHandle: marketIdHandle,
            timeframeKey: timeframeKey,
            payloadHash: payloadHash,
            deadline: deadline,
            createdAt: uint40(block.timestamp),
            authorizationDeadline: 0,
            traderNonce: traderNonce,
            qualificationVersion: qualification.version,
            authorizationNonce: 0,
            // Bound by MAX_COMPONENTS immediately above.
            // forge-lint: disable-next-line(unsafe-typecast)
            componentCount: uint8(componentCount),
            status: CapitalIntentStatus.PendingEvaluation
        });
        traderNonces[msg.sender] = traderNonce + 1;

        emit CapitalIntentSubmitted(
            intentId,
            msg.sender,
            qualification.version,
            marketIdHandle,
            timeframeKey,
            deadline,
            payloadHash,
            traderNonce,
            operatorAtSubmission
        );
        emit CapitalIntentComponents(intentId, componentHandles);
    }

    function cancelCapitalIntent(bytes32 intentId) external {
        CapitalIntentRecord storage intent = _getCapitalIntent(intentId);
        if (intent.trader != msg.sender) {
            revert UnauthorizedIntentCancellation(msg.sender, intentId);
        }
        _requireStatus(intentId, intent, CapitalIntentStatus.PendingEvaluation);
        intent.status = CapitalIntentStatus.Cancelled;
        emit CapitalIntentCancelled(intentId, intent.trader);
    }

    function rejectCapitalIntent(
        bytes32 intentId,
        EvaluationScoreSubmission calldata scores,
        bytes32 evidenceHash,
        bytes32 reasonHash
    ) external whenNotPaused nonReentrant onlyRole(EVALUATOR_ROLE) {
        if (evidenceHash == bytes32(0)) revert ZeroEvidenceHash();
        if (reasonHash == bytes32(0)) revert ZeroReasonHash();
        CapitalIntentRecord storage intent = _getCapitalIntent(intentId);
        _requireStatus(intentId, intent, CapitalIntentStatus.PendingEvaluation);
        if (block.timestamp >= intent.deadline) {
            revert AuthorizationExpired(intent.deadline, block.timestamp);
        }

        bytes32[3] memory scoreHandles = _internalizeScores(intent.trader, scores);
        _evaluations[intentId] = EvaluationRecord({
            realSisterScoreHandle: scoreHandles[0],
            perturbationP25ScoreHandle: scoreHandles[1],
            stressP25ScoreHandle: scoreHandles[2],
            evidenceHash: evidenceHash,
            reasonHash: reasonHash,
            executionCommitment: bytes32(0)
        });
        intent.status = CapitalIntentStatus.Rejected;

        emit CapitalEvaluationScoresRecorded(
            intentId, intent.trader, scoreHandles[0], scoreHandles[1], scoreHandles[2], evidenceHash
        );
        emit CapitalIntentRejected(intentId, intent.trader, evidenceHash, reasonHash);
    }

    function approveCapitalIntent(
        bytes32 intentId,
        EvaluationScoreSubmission calldata scores,
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(EVALUATOR_ROLE)
        returns (bytes32 commitmentHash)
    {
        CapitalIntentRecord storage intent = _getCapitalIntent(intentId);
        _requireStatus(intentId, intent, CapitalIntentStatus.PendingEvaluation);
        _requireQualificationVersion(intent.trader, intent.qualificationVersion);
        _validateAuthorization(intentId, intent, authorization);

        bytes32[3] memory scoreHandles = _internalizeScores(intent.trader, scores);
        commitmentHash = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);
        bytes32 evidenceHash = authorization.evaluationEvidenceHash;
        _evaluations[intentId] = EvaluationRecord({
            realSisterScoreHandle: scoreHandles[0],
            perturbationP25ScoreHandle: scoreHandles[1],
            stressP25ScoreHandle: scoreHandles[2],
            evidenceHash: evidenceHash,
            reasonHash: bytes32(0),
            executionCommitment: commitmentHash
        });

        uint64 authorizationNonce = authorization.authorizationNonce;
        intent.authorizationNonce = authorizationNonce;
        intent.authorizationDeadline = authorization.deadline;
        intent.status = CapitalIntentStatus.Approved;
        intentByAuthorizationNonce[authorizationNonce] = intentId;
        nextAuthorizationNonce = authorizationNonce + 1;

        emit CapitalEvaluationScoresRecorded(
            intentId, intent.trader, scoreHandles[0], scoreHandles[1], scoreHandles[2], evidenceHash
        );
        emit CapitalIntentApproved(
            intentId,
            intent.trader,
            commitmentHash,
            authorization.vaultExecutionManager,
            authorization.fundVault,
            authorization.executor,
            authorizationNonce,
            authorization.validAfter,
            authorization.deadline
        );
        emit CapitalExecutionPolicyCommitted(
            intentId,
            commitmentHash,
            authorization.policyRoot,
            authorization.policyVersion,
            authorization.callsHash,
            authorization.riskEnvelopeHash,
            authorization.riskPolicyVersion,
            evidenceHash
        );
    }

    function revokeCapitalIntent(bytes32 intentId, bytes32 reasonHash)
        external
        onlyRole(REVOCER_ROLE)
    {
        if (reasonHash == bytes32(0)) revert ZeroReasonHash();
        CapitalIntentRecord storage intent = _getCapitalIntent(intentId);
        _requireStatus(intentId, intent, CapitalIntentStatus.Approved);
        intent.status = CapitalIntentStatus.Revoked;
        bytes32 commitmentHash = _evaluations[intentId].executionCommitment;
        emit CapitalIntentRevoked(intentId, intent.trader, commitmentHash, reasonHash);
    }

    function expireCapitalIntent(bytes32 intentId) external {
        CapitalIntentRecord storage intent = _getCapitalIntent(intentId);
        CapitalIntentStatus previousStatus = intent.status;
        uint40 applicableDeadline;
        if (previousStatus == CapitalIntentStatus.PendingEvaluation) {
            applicableDeadline = intent.deadline;
        } else if (previousStatus == CapitalIntentStatus.Approved) {
            applicableDeadline = intent.authorizationDeadline;
        } else {
            revert CapitalIntentNotExpirable(
                intentId, previousStatus, applicableDeadline, block.timestamp
            );
        }
        if (block.timestamp < applicableDeadline) {
            revert CapitalIntentNotExpirable(
                intentId, previousStatus, applicableDeadline, block.timestamp
            );
        }

        intent.status = CapitalIntentStatus.Expired;
        emit CapitalIntentExpired(intentId, intent.trader, previousStatus, applicableDeadline);
    }

    function consumeCapitalExecution(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization
    ) external whenNotPaused nonReentrant returns (bytes32 executionCommitment) {
        CapitalIntentRecord storage intent = _getCapitalIntent(authorization.intentId);
        _requireStatus(authorization.intentId, intent, CapitalIntentStatus.Approved);

        if (msg.sender != authorization.vaultExecutionManager) {
            revert UnauthorizedExecutionConsumer(msg.sender, authorization.vaultExecutionManager);
        }
        if (!approvedExecutionManagers[msg.sender]) {
            revert ExecutionManagerNotAuthorized(msg.sender);
        }
        _requireQualificationVersion(intent.trader, intent.qualificationVersion);
        if (block.timestamp < authorization.validAfter) {
            revert AuthorizationNotYetActive(authorization.validAfter, block.timestamp);
        }
        if (block.timestamp >= authorization.deadline) {
            revert AuthorizationExpired(authorization.deadline, block.timestamp);
        }

        executionCommitment = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);
        bytes32 approvedCommitment = _evaluations[authorization.intentId].executionCommitment;
        if (executionCommitment != approvedCommitment) {
            revert ExecutionCommitmentMismatch(executionCommitment, approvedCommitment);
        }
        if (_consumedCommitments[executionCommitment]) {
            revert ExecutionCommitmentAlreadyConsumed(executionCommitment);
        }
        if (consumedAuthorizationNonces[authorization.authorizationNonce]) {
            revert AuthorizationNonceAlreadyConsumed(authorization.authorizationNonce);
        }

        _consumedCommitments[executionCommitment] = true;
        consumedAuthorizationNonces[authorization.authorizationNonce] = true;
        intent.status = CapitalIntentStatus.Consumed;

        emit CapitalExecutionConsumed(
            authorization.intentId,
            intent.trader,
            executionCommitment,
            msg.sender,
            authorization.executor,
            authorization.authorizationNonce
        );
    }

    function existsCapitalIntent(bytes32 intentId) external view returns (bool) {
        return _capitalIntents[intentId].status != CapitalIntentStatus.Unset;
    }

    function getCapitalIntentIdentity(bytes32 intentId)
        external
        view
        returns (CapitalIntentIdentity memory identity)
    {
        CapitalIntentRecord storage intent = _getCapitalIntent(intentId);
        return CapitalIntentIdentity({
            trader: intent.trader,
            operatorAtSubmission: intent.operatorAtSubmission,
            marketIdHandle: intent.marketIdHandle,
            timeframeKey: intent.timeframeKey,
            payloadHash: intent.payloadHash
        });
    }

    function getCapitalIntentState(bytes32 intentId)
        external
        view
        returns (CapitalIntentState memory state)
    {
        CapitalIntentRecord storage intent = _getCapitalIntent(intentId);
        return CapitalIntentState({
            deadline: intent.deadline,
            createdAt: intent.createdAt,
            authorizationDeadline: intent.authorizationDeadline,
            traderNonce: intent.traderNonce,
            qualificationVersion: intent.qualificationVersion,
            authorizationNonce: intent.authorizationNonce,
            componentCount: intent.componentCount,
            status: intent.status
        });
    }

    function getCapitalIntentComponents(bytes32 intentId)
        external
        view
        returns (bytes32[] memory componentHandles)
    {
        _getCapitalIntent(intentId);
        return _capitalIntentComponents[intentId];
    }

    function getCapitalEvaluation(bytes32 intentId)
        external
        view
        returns (EvaluationRecord memory evaluation)
    {
        CapitalIntentRecord storage intent = _getCapitalIntent(intentId);
        bool hasEvaluation = _evaluations[intentId].evidenceHash != bytes32(0);
        if (!hasEvaluation) {
            revert InvalidCapitalIntentStatus(intentId, intent.status);
        }
        return _evaluations[intentId];
    }

    function getApprovedExecutionCommitment(bytes32 intentId)
        external
        view
        returns (bytes32 executionCommitment)
    {
        CapitalIntentRecord storage intent = _getCapitalIntent(intentId);
        executionCommitment = _evaluations[intentId].executionCommitment;
        if (executionCommitment == bytes32(0)) {
            revert InvalidCapitalIntentStatus(intentId, intent.status);
        }
    }

    function isExecutionConsumed(bytes32 executionCommitment) external view returns (bool) {
        return _consumedCommitments[executionCommitment];
    }

    function _validateInitialization(InitializationParams calldata params) private view {
        _requireNonZero(params.initialDefaultAdmin, "initialDefaultAdmin");
        _requireNonZero(params.initialPauser, "initialPauser");
        if (params.initialFheOperator == address(0)) revert ZeroFheOperator();
        if (
            params.qualificationRegistry == address(0)
                || params.qualificationRegistry.code.length == 0
        ) {
            revert InvalidQualificationRegistry(params.qualificationRegistry);
        }
    }

    function _getActiveQualification(address trader)
        private
        view
        returns (IAlphaEngineTraderQualificationRegistry.Qualification memory qualification)
    {
        if (!qualificationRegistry.existsQualification(trader)) revert TraderNotQualified(trader);
        qualification = qualificationRegistry.getQualification(trader);
        if (!qualificationRegistry.isQualifiedAtVersion(trader, qualification.version)) {
            revert QualificationVersionNotActive(trader, qualification.version);
        }
    }

    function _requireQualificationVersion(address trader, uint64 qualificationVersion)
        private
        view
    {
        if (!qualificationRegistry.isQualifiedAtVersion(trader, qualificationVersion)) {
            revert QualificationVersionNotActive(trader, qualificationVersion);
        }
    }

    function _validateAuthorization(
        bytes32 intentId,
        CapitalIntentRecord storage intent,
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization
    ) private view {
        if (
            authorization.chainId != block.chainid
                || authorization.capitalStrategyManager != address(this)
                || authorization.intentId != intentId || authorization.trader != intent.trader
        ) {
            revert InvalidAuthorizationDomain(
                authorization.chainId,
                authorization.capitalStrategyManager,
                authorization.intentId,
                authorization.trader
            );
        }
        if (authorization.qualificationVersion != intent.qualificationVersion) {
            revert InvalidAuthorizationQualification(
                authorization.qualificationVersion, intent.qualificationVersion
            );
        }
        if (
            authorization.vaultExecutionManager == address(0)
                || authorization.vaultExecutionManager.code.length == 0
        ) {
            revert InvalidVaultExecutionManager(authorization.vaultExecutionManager);
        }
        if (!approvedExecutionManagers[authorization.vaultExecutionManager]) {
            revert ExecutionManagerNotAuthorized(authorization.vaultExecutionManager);
        }
        if (authorization.fundVault == address(0) || authorization.fundVault.code.length == 0) {
            revert InvalidFundVault(authorization.fundVault);
        }
        if (authorization.executor == address(0)) revert ZeroExecutor();

        uint64 expectedNonce = nextAuthorizationNonce;
        if (expectedNonce == type(uint64).max) revert AuthorizationNonceExhausted();
        if (authorization.authorizationNonce != expectedNonce) {
            revert AuthorizationNonceMismatch(authorization.authorizationNonce, expectedNonce);
        }
        if (
            authorization.validAfter >= authorization.deadline
                || authorization.deadline <= block.timestamp
        ) {
            revert InvalidAuthorizationWindow(authorization.validAfter, authorization.deadline);
        }
        uint40 authorizationWindow = authorization.deadline - authorization.validAfter;
        if (authorizationWindow > MAX_AUTHORIZATION_WINDOW) {
            revert AuthorizationWindowTooLong(authorizationWindow, MAX_AUTHORIZATION_WINDOW);
        }
        if (authorization.deadline > intent.deadline) {
            revert AuthorizationDeadlineExceedsIntent(authorization.deadline, intent.deadline);
        }
        if (
            authorization.policyRoot == bytes32(0) || authorization.policyVersion == 0
                || authorization.riskPolicyVersion == 0
        ) {
            revert InvalidAuthorizationPolicy(
                authorization.policyRoot,
                authorization.policyVersion,
                authorization.riskPolicyVersion
            );
        }
        if (authorization.callsHash == bytes32(0)) revert ZeroCallsHash();
        if (authorization.riskEnvelopeHash == bytes32(0)) revert ZeroRiskEnvelopeHash();
        if (authorization.submissionPayloadHash != intent.payloadHash) {
            revert SubmissionPayloadHashMismatch(
                authorization.submissionPayloadHash, intent.payloadHash
            );
        }
        if (authorization.evaluationEvidenceHash == bytes32(0)) revert ZeroEvidenceHash();
    }

    function _internalizeMarket(InEuint128 calldata encryptedMarketId, address operator)
        private
        returns (bytes32 marketIdHandle)
    {
        euint128 internalizedMarketId = FHE.asEuint128(encryptedMarketId);
        marketIdHandle = FHE.unwrap(internalizedMarketId);
        if (marketIdHandle == bytes32(0)) revert ZeroEncryptedHandle("marketId", 0);
        FHE.allowThis(internalizedMarketId);
        FHE.allow(internalizedMarketId, operator);
    }

    function _internalizeComponents(
        bytes32 intentId,
        InEuint128[] calldata encryptedComponents,
        address operator
    ) private returns (bytes32[] memory componentHandles) {
        uint256 componentCount = encryptedComponents.length;
        componentHandles = new bytes32[](componentCount);
        bytes32[] storage storedComponents = _capitalIntentComponents[intentId];
        for (uint256 index = 0; index < componentCount; ++index) {
            euint128 internalizedComponent = FHE.asEuint128(encryptedComponents[index]);
            bytes32 componentHandle = FHE.unwrap(internalizedComponent);
            if (componentHandle == bytes32(0)) {
                revert ZeroEncryptedHandle("component", index);
            }
            FHE.allowThis(internalizedComponent);
            FHE.allow(internalizedComponent, operator);
            componentHandles[index] = componentHandle;
            storedComponents.push(componentHandle);
        }
    }

    function _internalizeScores(address trader, EvaluationScoreSubmission calldata scores)
        private
        returns (bytes32[3] memory scoreHandles)
    {
        InEuint32[3] memory encryptedScores =
            [scores.realSisterScore, scores.perturbationP25Score, scores.stressP25Score];
        for (uint256 index = 0; index < encryptedScores.length; ++index) {
            euint32 internalizedScore = FHE.asEuint32(encryptedScores[index]);
            bytes32 scoreHandle = FHE.unwrap(internalizedScore);
            if (scoreHandle == bytes32(0)) {
                revert ZeroEncryptedHandle("evaluationScore", index);
            }
            FHE.allowThis(internalizedScore);
            FHE.allow(internalizedScore, trader);
            scoreHandles[index] = scoreHandle;
        }
    }

    function _getCapitalIntent(bytes32 intentId)
        private
        view
        returns (CapitalIntentRecord storage intent)
    {
        intent = _capitalIntents[intentId];
        if (intent.status == CapitalIntentStatus.Unset) revert CapitalIntentNotFound(intentId);
    }

    function _requireStatus(
        bytes32 intentId,
        CapitalIntentRecord storage intent,
        CapitalIntentStatus expected
    ) private view {
        if (intent.status != expected) revert InvalidCapitalIntentStatus(intentId, intent.status);
    }

    function _requireNonZero(address account, bytes32 field) private pure {
        if (account == address(0)) revert ZeroInitializationAddress(field);
    }
}
