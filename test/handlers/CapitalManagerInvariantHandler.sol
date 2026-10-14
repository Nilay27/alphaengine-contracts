// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {externalEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {
    IAlphaEngineTraderQualificationRegistry
} from "src/interfaces/IAlphaEngineTraderQualificationRegistry.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";
import {
    AlphaEngineCapitalStrategyManager
} from "src/strategy/AlphaEngineCapitalStrategyManager.sol";
import {
    AlphaEngineTraderQualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockFundVault, MockVaultExecutionManager} from "test/mocks/MockVaultExecutionManager.sol";

contract CapitalManagerInvariantHandler is MockCoFheTest {
    uint256 public constant TRADER_COUNT = 4;
    bytes32 private constant TIMEFRAME_KEY = keccak256("1h");

    AlphaEngineCapitalStrategyManager public immutable MANAGER;
    AlphaEngineTraderQualificationRegistry public immutable REGISTRY;
    MockVaultExecutionManager public immutable EXECUTION_MANAGER;
    MockFundVault public immutable FUND_VAULT;

    bytes32[] private _intentIds;
    mapping(address trader => uint64 count) public successfulSubmissions;
    mapping(bytes32 intentId => uint64 version) public submittedQualificationVersion;
    mapping(bytes32 intentId => bytes32 commitment) public observedCommitment;
    mapping(bytes32 intentId => AlphaEngineExecutionHashLib.ExecutionCommitmentV1 authorization)
        private _authorizations;
    mapping(bytes32 intentId => uint8 terminalStatus) public observedTerminalStatus;
    mapping(uint64 nonce => bytes32 intentId) public observedIntentByAuthorizationNonce;

    uint64 public successfulApprovals;
    uint256 public successfulConsumptions;
    uint256 public verifiedRollbacks;
    uint256 public rejectedQualificationApprovals;
    uint256 public rejectedQualificationConsumptions;
    bool public terminalStateChanged;
    bool public duplicateAuthorizationNonce;
    bool public downstreamRollbackViolation;
    bool public invalidQualificationProgressed;

    constructor(
        AlphaEngineCapitalStrategyManager manager,
        AlphaEngineTraderQualificationRegistry registry,
        MockVaultExecutionManager executionManager,
        MockFundVault fundVault
    ) {
        MANAGER = manager;
        REGISTRY = registry;
        EXECUTION_MANAGER = executionManager;
        FUND_VAULT = fundVault;
        _bindMockTaskManager();
    }

    function submit(uint256 traderSeed, uint128 market, uint128 component) external {
        address trader = traderAt(traderSeed);
        if (!REGISTRY.isQualified(trader) || block.timestamp > type(uint40).max - 2 days) return;

        IAlphaEngineTraderQualificationRegistry.Qualification memory qualification =
            REGISTRY.getQualification(trader);
        uint40 proposedDeadline = uint40(block.timestamp) + 2 days;
        uint40 deadline = proposedDeadline < qualification.validUntil
            ? proposedDeadline
            : qualification.validUntil;
        if (deadline <= block.timestamp) return;

        externalEuint128 encryptedMarket = createExternalEuint128(market, trader);
        externalEuint128[] memory components = new externalEuint128[](2);
        components[0] = createExternalEuint128(component, trader);
        components[1] = createExternalEuint128(component ^ 1, trader);

        vm.prank(trader);
        bytes32 intentId = MANAGER.submitCapitalIntent(
            TIMEFRAME_KEY,
            deadline,
            encryptedMarket,
            components,
            _strategyProof(address(MANAGER), encryptedMarket, components)
        );
        _intentIds.push(intentId);
        successfulSubmissions[trader] += 1;
        submittedQualificationVersion[intentId] = qualification.version;
        _observeTerminal(intentId);
    }

    function cancel(uint256 intentSeed) external {
        bytes32 intentId = _intentAt(intentSeed);
        if (intentId == bytes32(0)) return;
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            MANAGER.getCapitalIntentState(intentId);
        if (state.status != AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation)
        {
            return;
        }
        address trader = MANAGER.getCapitalIntentIdentity(intentId).trader;
        vm.prank(trader);
        MANAGER.cancelCapitalIntent(intentId);
        _observeTerminal(intentId);
    }

    function reject(uint256 intentSeed, uint32 scoreSeed) external {
        bytes32 intentId = _intentAt(intentSeed);
        if (intentId == bytes32(0)) return;
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            MANAGER.getCapitalIntentState(intentId);
        if (
            state.status != AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation
                || block.timestamp >= state.deadline
        ) {
            return;
        }

        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(scoreSeed);
        MANAGER.rejectCapitalIntent(
            intentId,
            scores,
            keccak256(abi.encode("rejection evidence", intentId, scoreSeed)),
            keccak256(abi.encode("rejection reason", intentId, scoreSeed))
        );
        _observeTerminal(intentId);
    }

    function approve(uint256 intentSeed, uint32 scoreSeed) external {
        bytes32 intentId = _intentAt(intentSeed);
        if (intentId == bytes32(0)) return;
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            MANAGER.getCapitalIntentState(intentId);
        AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
            MANAGER.getCapitalIntentIdentity(intentId);
        if (
            state.status != AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation
                || block.timestamp >= state.deadline
                || !REGISTRY.isQualifiedAtVersion(identity.trader, state.qualificationVersion)
        ) {
            return;
        }

        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _buildAuthorization(intentId, identity, state, MANAGER.nextAuthorizationNonce());
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(scoreSeed);
        bytes32 commitment = MANAGER.approveCapitalIntent(intentId, scores, authorization);
        uint64 nonce = authorization.authorizationNonce;
        if (observedIntentByAuthorizationNonce[nonce] != bytes32(0)) {
            duplicateAuthorizationNonce = true;
        }
        observedIntentByAuthorizationNonce[nonce] = intentId;
        observedCommitment[intentId] = commitment;
        _authorizations[intentId] = authorization;
        successfulApprovals += 1;
        _observeTerminal(intentId);
    }

    function consume(uint256 intentSeed) external {
        bytes32 intentId = _intentAt(intentSeed);
        if (!_canConsume(intentId)) return;
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorizations[intentId];
        EXECUTION_MANAGER.consumeWithoutVaultAction(authorization);
        successfulConsumptions += 1;
        _observeTerminal(intentId);
    }

    function attemptFailingConsume(uint256 intentSeed) external {
        bytes32 intentId = _intentAt(intentSeed);
        if (!_canConsume(intentId)) return;
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorizations[intentId];
        bytes32 commitment = observedCommitment[intentId];
        AlphaEngineCapitalStrategyManager.CapitalIntentStatus previousStatus =
        MANAGER.getCapitalIntentState(intentId).status;

        try EXECUTION_MANAGER.executeThenRevert(authorization) {
            downstreamRollbackViolation = true;
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(MockVaultExecutionManager.ForcedDownstreamFailure.selector)
            );
            verifiedRollbacks += 1;
            if (
                MANAGER.getCapitalIntentState(intentId).status != previousStatus
                    || MANAGER.isExecutionConsumed(commitment)
                    || MANAGER.consumedAuthorizationNonces(authorization.authorizationNonce)
            ) {
                downstreamRollbackViolation = true;
            }
        }
        _observeTerminal(intentId);
    }

    function expire(uint256 intentSeed) external {
        bytes32 intentId = _intentAt(intentSeed);
        if (intentId == bytes32(0)) return;
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            MANAGER.getCapitalIntentState(intentId);
        uint40 deadline;
        if (state.status == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation)
        {
            deadline = state.deadline;
        } else if (state.status == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved) {
            deadline = state.authorizationDeadline;
        } else {
            return;
        }
        if (block.timestamp < deadline) vm.warp(deadline);
        MANAGER.expireCapitalIntent(intentId);
        _observeTerminal(intentId);
    }

    function revokeQualification(uint256 traderSeed) external {
        address trader = traderAt(traderSeed);
        if (!REGISTRY.isQualified(trader)) return;
        REGISTRY.revokeTrader(
            trader, keccak256(abi.encode("invariant revocation", trader, block.timestamp))
        );
        _observeAllTerminals();
    }

    function requalify(uint256 traderSeed, uint40 validityDelta) external {
        address trader = traderAt(traderSeed);
        if (REGISTRY.isQualified(trader) || block.timestamp > type(uint40).max - 30 days) return;
        validityDelta = uint40(bound(validityDelta, 1 days, 30 days));
        REGISTRY.qualifyTrader(
            trader,
            uint40(block.timestamp) + validityDelta,
            keccak256(abi.encode("invariant competition", trader, block.timestamp)),
            keccak256(abi.encode("invariant qualification", trader, block.timestamp))
        );
        _observeAllTerminals();
    }

    function attemptInvalidQualificationProgress(uint256 intentSeed, uint32 scoreSeed) external {
        bytes32 intentId = _intentAt(intentSeed);
        if (intentId == bytes32(0)) return;
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory beforeState =
            MANAGER.getCapitalIntentState(intentId);
        AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
            MANAGER.getCapitalIntentIdentity(intentId);
        if (REGISTRY.isQualifiedAtVersion(identity.trader, beforeState.qualificationVersion)) {
            return;
        }

        bytes32 beforeCommitment = observedCommitment[intentId];
        uint64 beforeAuthorizationNonce = MANAGER.nextAuthorizationNonce();
        if (
            beforeState.status
                    == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation
                && block.timestamp < beforeState.deadline
        ) {
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
                _buildAuthorization(intentId, identity, beforeState, beforeAuthorizationNonce);
            AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
                _scores(scoreSeed);
            try MANAGER.approveCapitalIntent(intentId, scores, authorization) {
                invalidQualificationProgressed = true;
            } catch (bytes memory reason) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(
                        AlphaEngineCapitalStrategyManager.QualificationVersionNotActive.selector,
                        identity.trader,
                        beforeState.qualificationVersion
                    )
                );
                rejectedQualificationApprovals += 1;
            }
        } else if (
            beforeState.status == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved
                && block.timestamp >= _authorizations[intentId].validAfter
                && block.timestamp < _authorizations[intentId].deadline
        ) {
            try EXECUTION_MANAGER.consumeWithoutVaultAction(_authorizations[intentId]) {
                invalidQualificationProgressed = true;
            } catch (bytes memory reason) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(
                        AlphaEngineCapitalStrategyManager.QualificationVersionNotActive.selector,
                        identity.trader,
                        beforeState.qualificationVersion
                    )
                );
                rejectedQualificationConsumptions += 1;
            }
        } else {
            return;
        }

        AlphaEngineCapitalStrategyManager.CapitalIntentState memory afterState =
            MANAGER.getCapitalIntentState(intentId);
        assertEq(keccak256(abi.encode(afterState)), keccak256(abi.encode(beforeState)));
        if (
            afterState.status != beforeState.status
                || observedCommitment[intentId] != beforeCommitment
                || MANAGER.nextAuthorizationNonce() != beforeAuthorizationNonce
                || MANAGER.isExecutionConsumed(beforeCommitment)
                || (beforeCommitment != bytes32(0)
                    && MANAGER.consumedAuthorizationNonces(beforeState.authorizationNonce))
        ) {
            invalidQualificationProgressed = true;
        }
        _observeTerminal(intentId);
    }

    function intentCount() external view returns (uint256) {
        return _intentIds.length;
    }

    function intentAt(uint256 index) external view returns (bytes32) {
        return _intentIds[index];
    }

    function authorizationFor(bytes32 intentId)
        external
        view
        returns (AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization)
    {
        return _authorizations[intentId];
    }

    function traderAt(uint256 seed) public pure returns (address) {
        return address(uint160(0x3000 + (seed % TRADER_COUNT)));
    }

    function _buildAuthorization(
        bytes32 intentId,
        AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity,
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state,
        uint64 authorizationNonce
    ) private view returns (AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory) {
        uint40 deadline = uint40(block.timestamp) + 1 hours;
        if (deadline > state.deadline) deadline = state.deadline;
        return AlphaEngineExecutionHashLib.ExecutionCommitmentV1({
            chainId: block.chainid,
            capitalStrategyManager: address(MANAGER),
            vaultExecutionManager: address(EXECUTION_MANAGER),
            fundVault: address(FUND_VAULT),
            intentId: intentId,
            trader: identity.trader,
            qualificationVersion: state.qualificationVersion,
            executor: address(this),
            authorizationNonce: authorizationNonce,
            validAfter: uint40(block.timestamp),
            deadline: deadline,
            policyRoot: keccak256(abi.encode("policy", intentId)),
            policyVersion: 1,
            callsHash: keccak256(abi.encode("calls", intentId)),
            riskEnvelopeHash: keccak256(abi.encode("risk", intentId)),
            riskPolicyVersion: 1,
            submissionPayloadHash: identity.payloadHash,
            evaluationEvidenceHash: keccak256(abi.encode("evaluation", intentId))
        });
    }

    function _scores(uint32 scoreSeed)
        private
        returns (AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory)
    {
        scoreSeed = uint32(bound(scoreSeed, 0, uint256(type(uint32).max) - 2));
        return _withScoreProof(
            address(MANAGER),
            AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission({
                realSisterScore: createExternalEuint32(scoreSeed, address(this)),
                perturbationP25Score: createExternalEuint32(scoreSeed + 1, address(this)),
                stressP25Score: createExternalEuint32(scoreSeed + 2, address(this)),
                inputProof: ""
            })
        );
    }

    function _canConsume(bytes32 intentId) private view returns (bool) {
        if (intentId == bytes32(0)) return false;
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            MANAGER.getCapitalIntentState(intentId);
        AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
            MANAGER.getCapitalIntentIdentity(intentId);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 storage authorization =
            _authorizations[intentId];
        return state.status == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved
            && REGISTRY.isQualifiedAtVersion(identity.trader, state.qualificationVersion)
            && block.timestamp >= authorization.validAfter
            && block.timestamp < authorization.deadline;
    }

    function _intentAt(uint256 seed) private view returns (bytes32) {
        uint256 length = _intentIds.length;
        return length == 0 ? bytes32(0) : _intentIds[seed % length];
    }

    function _observeAllTerminals() private {
        uint256 length = _intentIds.length;
        for (uint256 index = 0; index < length; ++index) {
            _observeTerminal(_intentIds[index]);
        }
    }

    function _observeTerminal(bytes32 intentId) private {
        uint8 currentStatus = uint8(MANAGER.getCapitalIntentState(intentId).status);
        uint8 previousTerminal = observedTerminalStatus[intentId];
        if (previousTerminal != 0 && currentStatus != previousTerminal) {
            terminalStateChanged = true;
        }
        if (_isTerminal(currentStatus) && previousTerminal == 0) {
            observedTerminalStatus[intentId] = currentStatus;
        }
    }

    function _isTerminal(uint8 status) private pure returns (bool) {
        return status == uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Cancelled)
            || status == uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Rejected)
            || status == uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Consumed)
            || status == uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Revoked)
            || status == uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Expired);
    }
}
