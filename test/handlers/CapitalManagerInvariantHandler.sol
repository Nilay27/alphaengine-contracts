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
    IAlphaEngineTraderQualificationRegistry
} from "src/interfaces/IAlphaEngineTraderQualificationRegistry.sol";
import {
    IAlphaEngineCapitalStrategyManager
} from "src/interfaces/IAlphaEngineCapitalStrategyManager.sol";
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
    MockVaultExecutionManager public immutable ALTERNATE_EXECUTION_MANAGER;
    address private immutable ADMIN;
    address private immutable PAUSER;

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
    uint256 public terminalRejections;
    uint256 public mutatedAuthorizationRejections;
    uint256 public timeBoundaryChecks;
    uint256 public governanceChecks;
    uint256 public upgradeChecks;

    constructor(
        AlphaEngineCapitalStrategyManager manager,
        AlphaEngineTraderQualificationRegistry registry,
        MockVaultExecutionManager executionManager,
        MockFundVault fundVault,
        address admin,
        address pauser
    ) {
        MANAGER = manager;
        REGISTRY = registry;
        EXECUTION_MANAGER = executionManager;
        FUND_VAULT = fundVault;
        ALTERNATE_EXECUTION_MANAGER =
            new MockVaultExecutionManager(IAlphaEngineCapitalStrategyManager(address(manager)));
        ADMIN = admin;
        PAUSER = pauser;
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
        _approve(intentSeed, scoreSeed, 0);
    }

    /// @dev QC-07: admit nontrivial future-start windows into the same randomized lifecycle.
    function approveFuture(uint256 intentSeed, uint32 scoreSeed, uint16 delaySeed) external {
        _approve(intentSeed, scoreSeed, uint40(1 + uint256(delaySeed) % 1800));
    }

    function _approve(uint256 intentSeed, uint32 scoreSeed, uint40 delay) private {
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
        if (block.timestamp + delay >= authorization.deadline) return;
        authorization.validAfter += delay;
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

    /// @dev QC-04/QC-05/QC-14: deliberately retry every terminal state and both replay domains.
    function attemptTerminalProgress(uint256 seed) external {
        bytes32 intentId = _intentAt(seed);
        if (intentId == bytes32(0)) return;
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            MANAGER.getCapitalIntentState(intentId);
        if (!_isTerminal(uint8(state.status))) return;
        bytes32 beforeHash = _snapshot(intentId);
        address trader = MANAGER.getCapitalIntentIdentity(intentId).trader;
        bytes memory failure = abi.encodeWithSelector(
            AlphaEngineCapitalStrategyManager.InvalidCapitalIntentStatus.selector,
            intentId,
            state.status
        );
        vm.expectRevert(failure);
        vm.prank(trader);
        MANAGER.cancelCapitalIntent(intentId);
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores = _scores(1);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization = _buildAuthorization(
            intentId,
            MANAGER.getCapitalIntentIdentity(intentId),
            state,
            MANAGER.nextAuthorizationNonce()
        );
        vm.expectRevert(failure);
        MANAGER.approveCapitalIntent(intentId, scores, authorization);
        vm.expectRevert(failure);
        MANAGER.rejectCapitalIntent(
            intentId, scores, keccak256("terminal evidence"), keccak256("terminal reason")
        );
        vm.expectRevert(failure);
        MANAGER.revokeCapitalIntent(intentId, keccak256("terminal revocation"));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.CapitalIntentNotExpirable.selector,
                intentId,
                state.status,
                uint40(0),
                block.timestamp
            )
        );
        MANAGER.expireCapitalIntent(intentId);
        if (observedCommitment[intentId] != bytes32(0)) {
            vm.expectRevert(failure);
            EXECUTION_MANAGER.consumeWithoutVaultAction(_authorizations[intentId]);
        }
        assertEq(_snapshot(intentId), beforeHash);
        ++terminalRejections;
    }

    /// @dev QC-07: inclusive validAfter and exclusive deadline, without rewinding the clock.
    function consumeAtBoundary(uint256 seed, uint8 boundary) external {
        bytes32 intentId = _intentAt(seed);
        if (intentId == bytes32(0)) return;
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            MANAGER.getCapitalIntentState(intentId);
        if (state.status != AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved) return;
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorizations[intentId];
        if (!REGISTRY.isQualifiedAtVersion(
                authorization.trader, authorization.qualificationVersion
            )) return;
        boundary %= 4;
        uint256 target = boundary == 0
            ? uint256(authorization.validAfter) - 1
            : boundary == 1
                ? authorization.validAfter
                : boundary == 2 ? uint256(authorization.deadline) - 1 : authorization.deadline;
        if (target < block.timestamp) return;
        vm.warp(target);
        bytes32 beforeHash = _snapshot(intentId);
        if (!REGISTRY.isQualifiedAtVersion(
                authorization.trader, authorization.qualificationVersion
            )) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCapitalStrategyManager.QualificationVersionNotActive.selector,
                    authorization.trader,
                    authorization.qualificationVersion
                )
            );
            EXECUTION_MANAGER.consumeWithoutVaultAction(authorization);
            assertEq(_snapshot(intentId), beforeHash);
            ++timeBoundaryChecks;
            return;
        }
        if (boundary == 0 || boundary == 3) {
            bytes memory failure = boundary == 0
                ? abi.encodeWithSelector(
                    AlphaEngineCapitalStrategyManager.AuthorizationNotYetActive.selector,
                    authorization.validAfter,
                    target
                )
                : abi.encodeWithSelector(
                    AlphaEngineCapitalStrategyManager.AuthorizationExpired.selector,
                    authorization.deadline,
                    target
                );
            vm.expectRevert(failure);
            EXECUTION_MANAGER.consumeWithoutVaultAction(authorization);
            assertEq(_snapshot(intentId), beforeHash);
        } else {
            EXECUTION_MANAGER.consumeWithoutVaultAction(authorization);
            ++successfulConsumptions;
            _observeTerminal(intentId);
        }
        ++timeBoundaryChecks;
    }

    /// @dev QC-13: mutate every hash-bearing field after approval, preserve the original on failure.
    function attemptMutatedConsume(uint256 seed, uint8 field) external {
        bytes32 intentId = _intentAt(seed);
        if (!_canConsume(intentId)) return;
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory changed = _authorizations[intentId];
        bytes32 beforeHash = _snapshot(intentId);
        field %= 19;
        if (field == 0) {
            changed.chainId ^= 1;
        } else if (field == 1) {
            changed.capitalStrategyManager = address(0xBAD1);
        } else if (field == 2) {
            changed.fundVault = address(0xBAD2);
        } else if (field == 3) {
            changed.trader = address(0xBAD3);
        } else if (field == 4) {
            changed.qualificationVersion ^= 1;
        } else if (field == 5) {
            changed.authorizationNonce ^= 1;
        } else if (field == 6) {
            changed.policyRoot = bytes32(uint256(changed.policyRoot) ^ 1);
        } else if (field == 7) {
            changed.policyVersion ^= 1;
        } else if (field == 8) {
            changed.callsHash = bytes32(uint256(changed.callsHash) ^ 1);
        } else if (field == 9) {
            changed.riskEnvelopeHash = bytes32(uint256(changed.riskEnvelopeHash) ^ 1);
        } else if (field == 10) {
            changed.riskPolicyVersion ^= 1;
        } else if (field == 11) {
            changed.submissionPayloadHash = bytes32(uint256(changed.submissionPayloadHash) ^ 1);
        } else if (field == 12) {
            changed.evaluationEvidenceHash = bytes32(uint256(changed.evaluationEvidenceHash) ^ 1);
        } else if (field == 13) {
            changed.validAfter = changed.validAfter == 0 ? 1 : changed.validAfter - 1;
        } else if (field == 14) {
            changed.deadline += 1;
        } else if (field == 15) {
            changed.executor = address(0xBAD4);
        } else if (field == 16) {
            changed.vaultExecutionManager = address(0xBAD5);
        } else if (field == 17) {
            changed.intentId = keccak256(abi.encode("unknown", intentId));
        } else {
            changed.validAfter = uint40(block.timestamp + 1);
        }
        bytes memory failure;
        if (field == 16) {
            failure = abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.UnauthorizedExecutionConsumer.selector,
                address(EXECUTION_MANAGER),
                changed.vaultExecutionManager
            );
        } else if (field == 17) {
            failure = abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.CapitalIntentNotFound.selector, changed.intentId
            );
        } else if (field == 18 || (field == 13 && changed.validAfter > block.timestamp)) {
            failure = abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.AuthorizationNotYetActive.selector,
                changed.validAfter,
                block.timestamp
            );
        } else {
            failure = abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ExecutionCommitmentMismatch.selector,
                AlphaEngineExecutionHashLib.hashExecutionCommitment(changed),
                observedCommitment[intentId]
            );
        }
        // Mock execution requires its caller match executor; call the actual capital consumer for field mutation.
        vm.expectRevert(failure);
        vm.prank(address(EXECUTION_MANAGER));
        MANAGER.consumeCapitalExecution(changed);
        assertEq(_snapshot(intentId), beforeHash);
        ++mutatedAuthorizationRejections;
    }

    /// @dev QC-08/QC-09/QC-10/QC-11: governance interleaves with live pending/approved records.
    function governanceCycle(uint256 seed, uint8 mode) external {
        bytes32 intentId = _intentAt(seed);
        if (intentId == bytes32(0)) return;
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            MANAGER.getCapitalIntentState(intentId);
        AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
            MANAGER.getCapitalIntentIdentity(intentId);
        bytes32 beforeHash = _snapshot(intentId);
        address oldOperator = MANAGER.fheOperator();
        vm.prank(PAUSER);
        MANAGER.pause();
        vm.prank(ADMIN);
        MANAGER.updateFheOperator(
            oldOperator == address(0xF1E1) ? address(0xF1E2) : address(0xF1E1)
        );
        assertEq(
            keccak256(abi.encode(MANAGER.getCapitalIntentIdentity(intentId))),
            keccak256(abi.encode(identity))
        );
        assertEq(_snapshot(intentId), beforeHash);
        mode %= 3;
        if (
            mode == 0
                && state.status
                    == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation
        ) {
            vm.prank(identity.trader);
            MANAGER.cancelCapitalIntent(intentId);
            _observeTerminal(intentId);
        } else if (
            mode == 1
                && state.status == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved
        ) {
            MANAGER.revokeCapitalIntent(intentId, keccak256("paused revocation"));
            _observeTerminal(intentId);
        } else if (
            state.status == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved
                && _canConsume(intentId)
        ) {
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            EXECUTION_MANAGER.consumeWithoutVaultAction(_authorizations[intentId]);
            assertEq(_snapshot(intentId), beforeHash);
        }
        vm.startPrank(ADMIN);
        MANAGER.setExecutionManagerAuthorization(address(EXECUTION_MANAGER), false);
        MANAGER.setExecutionManagerAuthorization(address(ALTERNATE_EXECUTION_MANAGER), true);
        MANAGER.unpause();
        vm.stopPrank();
        if (_canConsume(intentId)) {
            bytes32 deniedHash = _snapshot(intentId);
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCapitalStrategyManager.ExecutionManagerNotAuthorized.selector,
                    address(EXECUTION_MANAGER)
                )
            );
            EXECUTION_MANAGER.consumeWithoutVaultAction(_authorizations[intentId]);
            assertEq(_snapshot(intentId), deniedHash);
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCapitalStrategyManager.UnauthorizedExecutionConsumer.selector,
                    address(ALTERNATE_EXECUTION_MANAGER),
                    address(EXECUTION_MANAGER)
                )
            );
            ALTERNATE_EXECUTION_MANAGER.consumeWithoutVaultAction(_authorizations[intentId]);
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory changed =
                _authorizations[intentId];
            changed.vaultExecutionManager = address(ALTERNATE_EXECUTION_MANAGER);
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineCapitalStrategyManager.ExecutionCommitmentMismatch.selector,
                    AlphaEngineExecutionHashLib.hashExecutionCommitment(changed),
                    observedCommitment[intentId]
                )
            );
            ALTERNATE_EXECUTION_MANAGER.consumeWithoutVaultAction(changed);
            assertEq(_snapshot(intentId), deniedHash);
        }
        vm.startPrank(PAUSER);
        MANAGER.pause();
        vm.stopPrank();
        vm.startPrank(ADMIN);
        MANAGER.setExecutionManagerAuthorization(address(EXECUTION_MANAGER), true);
        MANAGER.setExecutionManagerAuthorization(address(ALTERNATE_EXECUTION_MANAGER), false);
        MANAGER.unpause();
        MANAGER.revokeRole(MANAGER.EVALUATOR_ROLE(), address(this));
        vm.stopPrank();
        if (state.status == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation)
        {
            AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores = _scores(1);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    address(this),
                    MANAGER.EVALUATOR_ROLE()
                )
            );
            MANAGER.rejectCapitalIntent(intentId, scores, keccak256("denied"), keccak256("reason"));
        }
        bytes32 evaluatorRole = MANAGER.EVALUATOR_ROLE();
        vm.prank(ADMIN);
        MANAGER.grantRole(evaluatorRole, address(this));
        ++governanceChecks;
    }

    /// @dev QC-15: storage/roles/replay state survive compatible upgrades and admin handover.
    function upgradeCycle() external {
        bytes32 beforeHash = _allSnapshot();
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
        address nextAdmin = address(0xCA015);
        address implementation = address(new AlphaEngineCapitalStrategyManager());
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
        ProxyAdmin registryAdmin = ProxyAdmin(
            address(
                uint160(
                    uint256(
                        vm.load(
                            address(REGISTRY),
                            bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
                        )
                    )
                )
            )
        );
        bytes32 qualificationSnapshot;
        for (uint256 i; i < TRADER_COUNT; ++i) {
            qualificationSnapshot = keccak256(
                abi.encode(qualificationSnapshot, REGISTRY.getQualification(traderAt(i)))
            );
        }
        address registryImplementation = address(new AlphaEngineTraderQualificationRegistry());
        vm.prank(ADMIN);
        registryAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(REGISTRY)), registryImplementation, ""
        );
        bytes32 afterQualificationSnapshot;
        for (uint256 i; i < TRADER_COUNT; ++i) {
            afterQualificationSnapshot = keccak256(
                abi.encode(afterQualificationSnapshot, REGISTRY.getQualification(traderAt(i)))
            );
        }
        assertEq(afterQualificationSnapshot, qualificationSnapshot);
        assertEq(_allSnapshot(), beforeHash);
        AlphaEngineCapitalStrategyManager.InitializationParams memory params =
            AlphaEngineCapitalStrategyManager.InitializationParams(
                ADMIN, PAUSER, MANAGER.fheOperator(), address(REGISTRY)
            );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        MANAGER.initialize(params);
        vm.prank(nextAdmin);
        proxyAdmin.transferOwnership(ADMIN);
        ++upgradeChecks;
    }

    function advanceTime(uint16 delta) external {
        vm.warp(block.timestamp + uint256(delta) % (3 days));
        _observeAllTerminals();
    }

    /// @dev QC-08: permissionless expiry remains live while risk-taking is paused.
    function expireWhilePaused(uint256 seed) external {
        bytes32 intentId = _intentAt(seed);
        if (intentId == bytes32(0)) return;
        AlphaEngineCapitalStrategyManager.CapitalIntentStatus status =
        MANAGER.getCapitalIntentState(intentId).status;
        if (
            status != AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation
                && status != AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved
        ) return;
        vm.prank(PAUSER);
        MANAGER.pause();
        this.expire(seed);
        assertEq(
            uint8(MANAGER.getCapitalIntentState(intentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Expired)
        );
        vm.prank(ADMIN);
        MANAGER.unpause();
        this.attemptTerminalProgress(seed);
        ++governanceChecks;
    }

    /// @dev QC-02/QC-11/QC-14: registry administration is exercised while real capital records remain live.
    function registryGovernanceCycle(uint256 seed) external {
        bytes32 intentId = _intentAt(seed);
        if (intentId == bytes32(0)) return;
        address trader = MANAGER.getCapitalIntentIdentity(intentId).trader;
        if (!REGISTRY.isQualified(trader)) return;
        bytes32 beforeHash = _snapshot(intentId);
        bytes32 qualificationHash = keccak256(abi.encode(REGISTRY.getQualification(trader)));
        vm.prank(PAUSER);
        REGISTRY.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        REGISTRY.qualifyTrader(
            trader,
            uint40(block.timestamp + 90 days),
            keccak256("paused source"),
            keccak256("paused evidence")
        );
        assertEq(_snapshot(intentId), beforeHash);
        assertEq(keccak256(abi.encode(REGISTRY.getQualification(trader))), qualificationHash);
        REGISTRY.revokeTrader(trader, keccak256("paused registry invalidation"));
        vm.startPrank(ADMIN);
        REGISTRY.unpause();
        REGISTRY.revokeRole(REGISTRY.QUALIFICATION_ISSUER_ROLE(), address(this));
        REGISTRY.revokeRole(REGISTRY.QUALIFICATION_REVOKER_ROLE(), address(this));
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                REGISTRY.QUALIFICATION_ISSUER_ROLE()
            )
        );
        REGISTRY.qualifyTrader(
            trader, uint40(block.timestamp + 1 days), keccak256("source"), keccak256("evidence")
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                REGISTRY.QUALIFICATION_REVOKER_ROLE()
            )
        );
        REGISTRY.revokeTrader(trader, keccak256("denied revocation"));
        vm.startPrank(ADMIN);
        REGISTRY.grantRole(REGISTRY.QUALIFICATION_ISSUER_ROLE(), address(this));
        REGISTRY.grantRole(REGISTRY.QUALIFICATION_REVOKER_ROLE(), address(this));
        vm.stopPrank();
        REGISTRY.qualifyTrader(
            trader,
            uint40(block.timestamp + 30 days),
            keccak256("fresh source"),
            keccak256("fresh evidence")
        );
        this.attemptInvalidQualificationProgress(seed, 1);
        ++governanceChecks;
    }

    /// @dev QC-03/QC-14: expire at the exact boundary, requalify, reject old approved work, then consume fresh work.
    function qualificationExpiryCycle(uint256 seed, uint16 delta) external {
        address trader = traderAt(seed);
        if (REGISTRY.isQualified(trader)) {
            REGISTRY.revokeTrader(trader, keccak256("expiry fixture reset"));
        }
        uint40 expiry = uint40(block.timestamp + 2 + uint256(delta) % 3598);
        uint64 version = REGISTRY.qualifyTrader(
            trader, expiry, keccak256("expiry source"), keccak256("expiry evidence")
        );
        uint256 index = _intentIds.length;
        this.submit(seed, uint128(seed), 1);
        this.approve(index, 1);
        bytes32 id = _intentIds[index];
        assertEq(_authorizations[id].deadline, expiry);
        vm.warp(uint256(expiry) - 1);
        assertTrue(REGISTRY.isQualifiedAtVersion(trader, version));
        vm.warp(expiry);
        assertFalse(REGISTRY.isQualifiedAtVersion(trader, version));
        bytes32 beforeHash = _snapshot(id);
        bytes memory failure = abi.encodeWithSelector(
            AlphaEngineCapitalStrategyManager.QualificationVersionNotActive.selector,
            trader,
            version
        );
        vm.expectRevert(failure);
        EXECUTION_MANAGER.consumeWithoutVaultAction(_authorizations[id]);
        assertEq(_snapshot(id), beforeHash);
        uint64 freshVersion = REGISTRY.qualifyTrader(
            trader,
            uint40(block.timestamp + 1 days),
            keccak256("new source"),
            keccak256("new evidence")
        );
        assertEq(freshVersion, version + 1);
        vm.expectRevert(failure);
        EXECUTION_MANAGER.consumeWithoutVaultAction(_authorizations[id]);
        assertEq(_snapshot(id), beforeHash);
        uint256 freshIndex = _intentIds.length;
        this.submit(seed, uint128(seed), 1);
        this.approve(freshIndex, 1);
        this.consume(freshIndex);
        assertEq(
            uint8(MANAGER.getCapitalIntentState(_intentIds[freshIndex]).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Consumed)
        );
        ++timeBoundaryChecks;
    }

    function _snapshot(bytes32 intentId) private view returns (bytes32) {
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            MANAGER.getCapitalIntentState(intentId);
        bytes32 snapshot = keccak256(
            abi.encode(
                state,
                MANAGER.getCapitalIntentIdentity(intentId),
                MANAGER.getCapitalIntentComponents(intentId),
                MANAGER.nextAuthorizationNonce(),
                MANAGER.traderNonces(MANAGER.getCapitalIntentIdentity(intentId).trader),
                MANAGER.isExecutionConsumed(observedCommitment[intentId]),
                MANAGER.consumedAuthorizationNonces(state.authorizationNonce),
                EXECUTION_MANAGER.successfulExecutions(),
                EXECUTION_MANAGER.lastExecutionCommitment()
            )
        );
        if (
            observedCommitment[intentId] != bytes32(0)
                || state.status == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Rejected
        ) {
            snapshot = keccak256(abi.encode(snapshot, MANAGER.getCapitalEvaluation(intentId)));
        }
        return snapshot;
    }

    function _allSnapshot() private view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                MANAGER.defaultAdmin(),
                MANAGER.paused(),
                MANAGER.fheOperator(),
                MANAGER.approvedExecutionManagers(address(EXECUTION_MANAGER)),
                MANAGER.hasRole(MANAGER.EVALUATOR_ROLE(), address(this))
            )
        );
        for (uint256 i; i < _intentIds.length; ++i) {
            result = keccak256(abi.encode(result, _snapshot(_intentIds[i])));
        }
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
