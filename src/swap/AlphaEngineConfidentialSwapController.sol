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
import {FHE, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {
    IAlphaEngineConfidentialAssetRegistry
} from "../interfaces/IAlphaEngineConfidentialAssetRegistry.sol";
import {
    IAlphaEngineConfidentialSwapController
} from "../interfaces/IAlphaEngineConfidentialSwapController.sol";
import {
    IAlphaEngineConfidentialSwapEscrow
} from "../interfaces/IAlphaEngineConfidentialSwapEscrow.sol";
import {AlphaEngineExecutionHashLib} from "../libraries/AlphaEngineExecutionHashLib.sol";
import {AlphaEngineStrategyHashLib} from "../libraries/AlphaEngineStrategyHashLib.sol";

/// @title AlphaEngineConfidentialSwapController
/// @notice Owns bound confidential-swap submission, execution, refund, and replay state.
/// @dev This contract never holds tokens. Every intent pins its escrow, executor, output wrapper,
///      execution-data hash, salted minimum-output commitment, nonce, and deadline at submission.
contract AlphaEngineConfidentialSwapController is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IAlphaEngineConfidentialSwapController
{
    uint48 public constant DEFAULT_ADMIN_DELAY = 48 hours;
    uint16 public constant DEFAULT_SWAP_INTENTS_PER_WINDOW = 120;
    uint16 public constant MAX_CONFIGURABLE_SWAP_INTENTS_PER_WINDOW = 512;
    uint16 public constant DEFAULT_SWAP_INTENTS_PER_SECOND = 2;
    uint16 public constant DEFAULT_SWAP_BURST = 24;
    uint256 public constant SWAP_INTENT_WINDOW = 60 seconds;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant SWAP_OPERATOR_ROLE = keccak256("SWAP_OPERATOR_ROLE");

    struct InitializationParams {
        address initialDefaultAdmin;
        address initialPauser;
        address initialSwapOperator;
    }

    error ZeroInitializationAddress(bytes32 field);
    error InvalidSwapEscrow(address escrow);
    error EscrowControllerMismatch(address escrow, address expected, address actual);
    error EscrowPaused(address escrow);
    error InvalidSwapExecutor(address executor);
    error ExecutorCallerMismatch(address executor, address expected, address actual);
    error SwapConfigurationUnchanged(address escrow, address executor);
    error SwapConfigurationIncomplete();
    error ZeroInputWrapper();
    error ZeroOutputWrapper();
    error WrapperNotRegistered(address wrapper);
    error ZeroRouteKey();
    error ZeroExecutionDataHash();
    error ZeroMinimumOutputCommitment();
    error ZeroMinimumOutputSalt();
    error DeadlineNotInFuture(uint40 deadline, uint256 currentTimestamp);
    error TraderNonceExhausted(address trader);
    error ActiveSwapIntentExists(address trader, bytes32 intentId);
    error SwapIntentRateLimitExceeded(uint256 nextAvailableAt);
    error SwapIntentBurstLimitExceeded(uint256 nextAvailableAt);
    error InvalidSwapIntentRateLimit(uint16 perMinute, uint16 perSecond, uint16 burst);
    error SwapIntentNotFound(bytes32 intentId);
    error InvalidSwapIntentStatus(bytes32 intentId, SwapIntentStatus status);
    error SwapIntentExpired(bytes32 intentId, uint40 deadline, uint256 currentTimestamp);
    error SwapIntentRefundUnavailable(bytes32 intentId, uint40 deadline, uint256 currentTimestamp);
    error ExecutionDataHashMismatch(bytes32 supplied, bytes32 expected);
    error MinimumOutputCommitmentMismatch(bytes32 supplied, bytes32 expected);
    error ZeroDecryptedInputAmount();
    error EscrowLockMismatch(bytes32 intentId);

    event SwapConfigurationUpdated(
        address indexed previousEscrow,
        address indexed newEscrow,
        address previousExecutor,
        address newExecutor
    );
    event SwapIntentRateLimitUpdated(uint16 perMinute, uint16 perSecond, uint16 burst);
    event ConfidentialSwapSubmitted(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed inputWrapper,
        address outputWrapper,
        address escrow,
        address executor,
        bytes32 routeKey,
        bytes32 lockedAmountHandle,
        bytes32 unshieldRequestHandle,
        uint40 deadline,
        bytes32 payloadHash,
        uint64 traderNonce
    );
    event ConfidentialSwapExecutionCommitted(
        bytes32 indexed intentId,
        bytes32 indexed executionDataHash,
        bytes32 indexed minimumOutputCommitment
    );
    event ConfidentialSwapExecuted(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed operator,
        address outputWrapper,
        uint64 decryptedInputAmount,
        uint256 outputUnderlyingAmount,
        bytes32 shieldedOutputHandle
    );
    event ConfidentialSwapRefunded(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed actor,
        address inputWrapper,
        uint64 decryptedInputAmount,
        bytes32 refundedShieldedHandle
    );

    address public swapEscrow;
    address public swapExecutor;

    mapping(bytes32 intentId => SwapIntentRecord record) private _swapIntents;
    mapping(address trader => uint64 nonce) public traderNonces;

    mapping(address trader => bytes32 intentId) public activeSwapIntentOf;
    mapping(uint256 ringIndex => uint40 submittedAt) private _recentSwapIntentTimes;
    uint256 public submittedSwapIntentCount;
    uint16 public maxSwapIntentsPerWindow;
    uint16 public swapIntentsPerSecond;
    uint16 public swapBurst;
    uint16 public availableSwapTokens;
    uint40 public swapTokensUpdatedAt;

    /// @dev Eight repository-owned storage slots plus this gap reserve 50 slots.
    uint256[42] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitializationParams calldata params) external initializer {
        if (params.initialDefaultAdmin == address(0)) {
            revert ZeroInitializationAddress("DEFAULT_ADMIN");
        }
        if (params.initialPauser == address(0)) {
            revert ZeroInitializationAddress("PAUSER");
        }
        if (params.initialSwapOperator == address(0)) {
            revert ZeroInitializationAddress("SWAP_OPERATOR");
        }

        __AccessControlDefaultAdminRules_init(DEFAULT_ADMIN_DELAY, params.initialDefaultAdmin);
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(PAUSER_ROLE, params.initialPauser);
        _grantRole(SWAP_OPERATOR_ROLE, params.initialSwapOperator);
        maxSwapIntentsPerWindow = DEFAULT_SWAP_INTENTS_PER_WINDOW;
        swapIntentsPerSecond = DEFAULT_SWAP_INTENTS_PER_SECOND;
        swapBurst = DEFAULT_SWAP_BURST;
        availableSwapTokens = DEFAULT_SWAP_BURST;
        swapTokensUpdatedAt = uint40(block.timestamp);
        _pause();
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address escrow = swapEscrow;
        address executor = swapExecutor;
        if (escrow == address(0) || executor == address(0)) {
            revert SwapConfigurationIncomplete();
        }
        _validateSwapConfiguration(escrow, executor);
        if (IAlphaEngineConfidentialSwapEscrow(escrow).paused()) {
            revert EscrowPaused(escrow);
        }
        _unpause();
    }

    /// @notice Atomically changes the pair used only by future submissions.
    function setSwapConfiguration(address newEscrow, address newExecutor)
        external
        whenPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _validateSwapConfiguration(newEscrow, newExecutor);
        address previousEscrow = swapEscrow;
        address previousExecutor = swapExecutor;
        if (newEscrow == previousEscrow && newExecutor == previousExecutor) {
            revert SwapConfigurationUnchanged(newEscrow, newExecutor);
        }

        swapEscrow = newEscrow;
        swapExecutor = newExecutor;
        emit SwapConfigurationUpdated(previousEscrow, newEscrow, previousExecutor, newExecutor);
    }

    function setSwapRateLimits(uint16 perMinute, uint16 perSecond, uint16 burst)
        external
        whenPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (
            perMinute == 0 || perMinute > MAX_CONFIGURABLE_SWAP_INTENTS_PER_WINDOW || perSecond == 0
                || perSecond > 16 || burst < perSecond || burst > 128
        ) {
            revert InvalidSwapIntentRateLimit(perMinute, perSecond, burst);
        }
        maxSwapIntentsPerWindow = perMinute;
        swapIntentsPerSecond = perSecond;
        swapBurst = burst;
        availableSwapTokens = burst;
        swapTokensUpdatedAt = uint40(block.timestamp);
        emit SwapIntentRateLimitUpdated(perMinute, perSecond, burst);
    }

    function submitSwapIntent(SwapIntentSubmission calldata submission)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 intentId)
    {
        _validateSubmission(submission);

        bytes32 activeIntentId = activeSwapIntentOf[msg.sender];
        if (activeIntentId != bytes32(0)) {
            revert ActiveSwapIntentExists(msg.sender, activeIntentId);
        }
        uint256 count = submittedSwapIntentCount;
        uint256 limit = maxSwapIntentsPerWindow;
        if (limit == 0 || swapIntentsPerSecond == 0 || swapBurst == 0) {
            revert InvalidSwapIntentRateLimit(
                maxSwapIntentsPerWindow, swapIntentsPerSecond, swapBurst
            );
        }
        if (count >= limit) {
            uint256 oldest =
                _recentSwapIntentTimes[(count - limit) % MAX_CONFIGURABLE_SWAP_INTENTS_PER_WINDOW];
            if (block.timestamp < oldest + SWAP_INTENT_WINDOW) {
                revert SwapIntentRateLimitExceeded(oldest + SWAP_INTENT_WINDOW);
            }
        }
        uint256 elapsed = block.timestamp - swapTokensUpdatedAt;
        uint256 replenished = uint256(availableSwapTokens) + elapsed * swapIntentsPerSecond;
        uint256 tokens = replenished > swapBurst ? swapBurst : replenished;
        if (tokens == 0) revert SwapIntentBurstLimitExceeded(block.timestamp + 1);

        address escrow = swapEscrow;
        address executor = swapExecutor;
        uint64 traderNonce = traderNonces[msg.sender];
        if (traderNonce == type(uint64).max) revert TraderNonceExhausted(msg.sender);
        intentId = AlphaEngineStrategyHashLib.hashSwapIntentId(
            block.chainid, address(this), msg.sender, traderNonce
        );

        euint64 internalizedInputAmount =
            FHE.asEuint64(submission.encryptedInputAmount, submission.inputProof);
        FHE.allowThis(internalizedInputAmount);
        FHE.allow(internalizedInputAmount, escrow);

        euint64 lockedAmount = IAlphaEngineConfidentialSwapEscrow(escrow)
            .lockForSwapIntent(
                intentId, msg.sender, submission.inputWrapper, internalizedInputAmount
            );
        IAlphaEngineConfidentialSwapEscrow.SwapIntentLock memory intentLock =
            IAlphaEngineConfidentialSwapEscrow(escrow).getSwapIntentLock(intentId);
        if (
            intentLock.account != msg.sender || intentLock.wrapper != submission.inputWrapper
                || euint64.unwrap(intentLock.lockedAmount) != euint64.unwrap(lockedAmount)
                || intentLock.status
                    != IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested
        ) {
            revert EscrowLockMismatch(intentId);
        }

        bytes32 lockedAmountHandle = euint64.unwrap(lockedAmount);
        bytes32 unshieldRequestHandle = euint64.unwrap(intentLock.unshieldRequestHandle);
        bytes32 payloadHash = AlphaEngineStrategyHashLib.hashSwapPayload(
            AlphaEngineStrategyHashLib.SwapPayloadV1({
                chainId: block.chainid,
                controller: address(this),
                intentId: intentId,
                trader: msg.sender,
                traderNonce: traderNonce,
                escrow: escrow,
                executor: executor,
                inputWrapper: submission.inputWrapper,
                outputWrapper: submission.outputWrapper,
                routeKey: submission.routeKey,
                executionDataHash: submission.executionDataHash,
                minimumOutputCommitment: submission.minimumOutputCommitment,
                deadline: submission.deadline,
                lockedAmountHandle: lockedAmountHandle,
                unshieldRequestHandle: unshieldRequestHandle
            })
        );

        _swapIntents[intentId] = SwapIntentRecord({
            trader: msg.sender,
            escrow: escrow,
            executor: executor,
            inputWrapper: submission.inputWrapper,
            outputWrapper: submission.outputWrapper,
            routeKey: submission.routeKey,
            executionDataHash: submission.executionDataHash,
            minimumOutputCommitment: submission.minimumOutputCommitment,
            lockedAmountHandle: lockedAmountHandle,
            unshieldRequestHandle: unshieldRequestHandle,
            payloadHash: payloadHash,
            deadline: submission.deadline,
            createdAt: uint40(block.timestamp),
            traderNonce: traderNonce,
            status: SwapIntentStatus.Active
        });
        traderNonces[msg.sender] = traderNonce + 1;
        activeSwapIntentOf[msg.sender] = intentId;
        _recentSwapIntentTimes[count % MAX_CONFIGURABLE_SWAP_INTENTS_PER_WINDOW] =
            uint40(block.timestamp);
        submittedSwapIntentCount = count + 1;
        availableSwapTokens = uint16(tokens - 1);
        swapTokensUpdatedAt = uint40(block.timestamp);

        emit ConfidentialSwapSubmitted(
            intentId,
            msg.sender,
            submission.inputWrapper,
            submission.outputWrapper,
            escrow,
            executor,
            submission.routeKey,
            lockedAmountHandle,
            unshieldRequestHandle,
            submission.deadline,
            payloadHash,
            traderNonce
        );
        emit ConfidentialSwapExecutionCommitted(
            intentId, submission.executionDataHash, submission.minimumOutputCommitment
        );
    }

    function executeSwapIntent(
        bytes32 intentId,
        uint64 decryptedInputAmount,
        uint256 minimumOutput,
        bytes32 minimumOutputSalt,
        bytes calldata decryptionProof,
        bytes calldata executionData
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(SWAP_OPERATOR_ROLE)
        returns (uint256 outputUnderlyingAmount, bytes32 shieldedOutputHandle)
    {
        SwapIntentRecord storage record = _activeSwapIntent(intentId);
        if (record.deadline <= block.timestamp) {
            revert SwapIntentExpired(intentId, record.deadline, block.timestamp);
        }
        if (decryptedInputAmount == 0) revert ZeroDecryptedInputAmount();
        if (minimumOutputSalt == bytes32(0)) revert ZeroMinimumOutputSalt();

        bytes32 suppliedExecutionDataHash = keccak256(executionData);
        if (suppliedExecutionDataHash != record.executionDataHash) {
            revert ExecutionDataHashMismatch(suppliedExecutionDataHash, record.executionDataHash);
        }
        bytes32 suppliedMinimumOutputCommitment = AlphaEngineExecutionHashLib.hashSwapMinimumOutput(
            intentId, minimumOutput, minimumOutputSalt
        );
        if (suppliedMinimumOutputCommitment != record.minimumOutputCommitment) {
            revert MinimumOutputCommitmentMismatch(
                suppliedMinimumOutputCommitment, record.minimumOutputCommitment
            );
        }

        record.status = SwapIntentStatus.Executed;
        delete activeSwapIntentOf[record.trader];
        (outputUnderlyingAmount, shieldedOutputHandle) = IAlphaEngineConfidentialSwapEscrow(
                record.escrow
            )
            .settleSwapIntent(
                intentId,
                record.executor,
                record.outputWrapper,
                decryptedInputAmount,
                minimumOutput,
                decryptionProof,
                executionData
            );

        emit ConfidentialSwapExecuted(
            intentId,
            record.trader,
            msg.sender,
            record.outputWrapper,
            decryptedInputAmount,
            outputUnderlyingAmount,
            shieldedOutputHandle
        );
    }

    function refundSwapIntent(
        bytes32 intentId,
        uint64 decryptedInputAmount,
        bytes calldata decryptionProof
    ) external nonReentrant returns (bytes32 refundedShieldedHandle) {
        SwapIntentRecord storage record = _activeSwapIntent(intentId);
        if (
            decryptedInputAmount != 0 && !paused()
                && !IAlphaEngineConfidentialSwapEscrow(record.escrow).paused()
                && record.deadline > block.timestamp
        ) {
            revert SwapIntentRefundUnavailable(intentId, record.deadline, block.timestamp);
        }

        record.status = SwapIntentStatus.Refunded;
        delete activeSwapIntentOf[record.trader];
        refundedShieldedHandle = IAlphaEngineConfidentialSwapEscrow(record.escrow)
            .refundSwapIntent(intentId, decryptedInputAmount, decryptionProof);

        emit ConfidentialSwapRefunded(
            intentId,
            record.trader,
            msg.sender,
            record.inputWrapper,
            decryptedInputAmount,
            refundedShieldedHandle
        );
    }

    function existsSwapIntent(bytes32 intentId) external view returns (bool) {
        return _swapIntents[intentId].status != SwapIntentStatus.Unset;
    }

    function getSwapIntent(bytes32 intentId)
        external
        view
        returns (SwapIntentRecord memory record)
    {
        record = _swapIntents[intentId];
        if (record.status == SwapIntentStatus.Unset) revert SwapIntentNotFound(intentId);
    }

    function computeSwapIntentId(address trader, uint64 traderNonce)
        external
        view
        returns (bytes32 intentId)
    {
        return AlphaEngineStrategyHashLib.hashSwapIntentId(
            block.chainid, address(this), trader, traderNonce
        );
    }

    function computeMinimumOutputCommitment(
        bytes32 intentId,
        uint256 minimumOutput,
        bytes32 minimumOutputSalt
    ) external pure returns (bytes32 commitment) {
        return AlphaEngineExecutionHashLib.hashSwapMinimumOutput(
            intentId, minimumOutput, minimumOutputSalt
        );
    }

    function _activeSwapIntent(bytes32 intentId)
        private
        view
        returns (SwapIntentRecord storage record)
    {
        record = _swapIntents[intentId];
        if (record.status == SwapIntentStatus.Unset) revert SwapIntentNotFound(intentId);
        if (record.status != SwapIntentStatus.Active) {
            revert InvalidSwapIntentStatus(intentId, record.status);
        }
    }

    function _validateSubmission(SwapIntentSubmission calldata submission) private view {
        if (submission.inputWrapper == address(0)) revert ZeroInputWrapper();
        if (submission.outputWrapper == address(0)) revert ZeroOutputWrapper();
        if (submission.routeKey == bytes32(0)) revert ZeroRouteKey();
        if (submission.executionDataHash == bytes32(0)) revert ZeroExecutionDataHash();
        if (submission.minimumOutputCommitment == bytes32(0)) {
            revert ZeroMinimumOutputCommitment();
        }
        if (submission.deadline <= block.timestamp) {
            revert DeadlineNotInFuture(submission.deadline, block.timestamp);
        }

        address escrow = swapEscrow;
        address executor = swapExecutor;
        if (escrow == address(0) || executor == address(0)) {
            revert SwapConfigurationIncomplete();
        }
        address registry = IAlphaEngineConfidentialSwapEscrow(escrow).assetRegistry();
        _requireRegisteredWrapper(registry, submission.inputWrapper);
        _requireRegisteredWrapper(registry, submission.outputWrapper);
    }

    function _requireRegisteredWrapper(address registry, address wrapper) private view {
        if (
            IAlphaEngineConfidentialAssetRegistry(registry).underlyingForWrapper(wrapper)
                == address(0)
        ) {
            revert WrapperNotRegistered(wrapper);
        }
    }

    function _validateSwapConfiguration(address escrow, address executor) private view {
        if (escrow == address(0) || escrow.code.length == 0) {
            revert InvalidSwapEscrow(escrow);
        }
        address configuredController = _readAddress(escrow, "swapController()");
        if (configuredController != address(this)) {
            revert EscrowControllerMismatch(escrow, address(this), configuredController);
        }
        if (executor == address(0) || executor.code.length == 0) {
            revert InvalidSwapExecutor(executor);
        }
        address authorizedCaller = _readAddress(executor, "authorizedCaller()");
        if (authorizedCaller != escrow) {
            revert ExecutorCallerMismatch(executor, escrow, authorizedCaller);
        }
    }

    function _readAddress(address target, string memory signature)
        private
        view
        returns (address value)
    {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSignature(signature));
        if (!success || result.length != 32) return address(0);
        return abi.decode(result, (address));
    }
}
