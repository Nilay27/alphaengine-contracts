// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {InEuint32, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {Utils} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAlphaEngineCapitalStrategyManager} from
    "src/interfaces/IAlphaEngineCapitalStrategyManager.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";
import {AlphaEngineStrategyHashLib} from "src/libraries/AlphaEngineStrategyHashLib.sol";
import {AlphaEngineCapitalStrategyManager} from "src/strategy/AlphaEngineCapitalStrategyManager.sol";
import {AlphaEngineTraderQualificationRegistry} from
    "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockFundVault, MockVaultExecutionManager} from "test/mocks/MockVaultExecutionManager.sol";

contract AlphaEngineCapitalStrategyManagerTest is MockCoFheTest {
    using stdStorage for StdStorage;

    bytes32 private constant TIMEFRAME_KEY = keccak256("1h");
    bytes32 private constant COMPETITION_ID = keccak256("competition");
    bytes32 private constant QUALIFICATION_EVIDENCE = keccak256("qualification evidence");
    bytes32 private constant EVALUATION_EVIDENCE = keccak256("evaluation evidence");
    bytes32 private constant REJECTION_REASON = keccak256("rejection reason");
    bytes32 private constant REVOCATION_REASON = keccak256("revocation reason");
    bytes32 private constant POLICY_ROOT = keccak256("policy root");
    bytes32 private constant CALLS_HASH = keccak256("calls hash");
    bytes32 private constant RISK_HASH = keccak256("risk hash");
    bytes32 private constant INITIAL_DEFAULT_ADMIN_FIELD = "initialDefaultAdmin";
    bytes32 private constant INITIAL_PAUSER_FIELD = "initialPauser";
    bytes32 private constant MARKET_ID_FIELD = "marketId";
    bytes32 private constant COMPONENT_FIELD = "component";
    bytes32 private constant EVALUATION_SCORE_FIELD = "evaluationScore";

    AlphaEngineTraderQualificationRegistry private registry;
    AlphaEngineCapitalStrategyManager private manager;
    MockVaultExecutionManager private executionManager;
    MockFundVault private fundVault;

    address private admin = makeAddr("admin");
    address private pauser = makeAddr("pauser");
    address private revoker = makeAddr("revoker");
    address private issuer = makeAddr("issuer");
    address private evaluator = makeAddr("evaluator");
    address private fheOperator = makeAddr("fheOperator");
    address private trader = makeAddr("trader");
    address private secondTrader = makeAddr("secondTrader");
    address private stranger = makeAddr("stranger");

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
        AlphaEngineCapitalStrategyManager.CapitalIntentStatus previousStatus,
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
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        _installMockTaskManager();
        registry = _deployRegistry();
        manager = _deployManager();
        executionManager =
            new MockVaultExecutionManager(IAlphaEngineCapitalStrategyManager(address(manager)));
        fundVault = new MockFundVault();

        vm.startPrank(admin);
        registry.grantRole(registry.QUALIFICATION_ISSUER_ROLE(), issuer);
        manager.grantRole(manager.EVALUATOR_ROLE(), evaluator);
        manager.grantRole(manager.REVOCER_ROLE(), revoker);
        manager.setExecutionManagerAuthorization(address(executionManager), true);
        registry.unpause();
        manager.unpause();
        vm.stopPrank();

        _qualify(trader, uint40(block.timestamp) + 30 days);
        _qualify(secondTrader, uint40(block.timestamp) + 30 days);
    }

    function test_constructorDisablesImplementationInitializer() public {
        AlphaEngineCapitalStrategyManager implementation = new AlphaEngineCapitalStrategyManager();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(_params());
    }

    function test_initializedDependenciesAndOperationalRoles() public view {
        assertEq(address(manager.qualificationRegistry()), address(registry));
        assertEq(manager.fheOperator(), fheOperator);
        assertFalse(manager.paused());
        assertEq(manager.defaultAdmin(), admin);
        assertTrue(manager.hasRole(manager.PAUSER_ROLE(), pauser));
        assertFalse(manager.hasRole(manager.EVALUATOR_ROLE(), admin));
        assertFalse(manager.hasRole(manager.REVOCER_ROLE(), admin));
    }

    function test_freshProxyStartsPaused() public {
        AlphaEngineCapitalStrategyManager freshManager = _deployManager();
        assertTrue(freshManager.paused());
    }

    function test_pauseAndUnpauseEmitStateParity() public {
        vm.expectEmit(true, false, false, true);
        emit Paused(pauser);
        vm.prank(pauser);
        manager.pause();
        assertTrue(manager.paused());

        vm.expectEmit(true, false, false, true);
        emit Unpaused(admin);
        vm.prank(admin);
        manager.unpause();
        assertFalse(manager.paused());
    }

    function test_pauseBlocksSubmissionEvaluationApprovalAndConsumption() public {
        bytes32 pendingIntentId = _submit(trader);
        (
            bytes32 approvedIntentId,
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization
        ) = _submitAndApprove(secondTrader);

        vm.prank(pauser);
        manager.pause();

        InEuint128 memory market = createInEuint128(1, trader);
        InEuint128[] memory components = _components(trader, 2, 3);
        vm.prank(trader);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        manager.submitCapitalIntent(
            market, TIMEFRAME_KEY, uint40(block.timestamp) + 1 days, components
        );

        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(evaluator, 4, 5, 6);
        vm.prank(evaluator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        manager.rejectCapitalIntent(pendingIntentId, scores, EVALUATION_EVIDENCE, REJECTION_REASON);

        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory pendingAuthorization =
            _authorization(pendingIntentId, trader, manager.nextAuthorizationNonce());
        vm.prank(evaluator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        manager.approveCapitalIntent(pendingIntentId, scores, pendingAuthorization);

        vm.prank(secondTrader);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        executionManager.consumeWithoutVaultAction(authorization);

        assertEq(
            uint8(manager.getCapitalIntentState(pendingIntentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation)
        );
        assertEq(
            uint8(manager.getCapitalIntentState(approvedIntentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved)
        );
    }

    function test_operationalRolesAreIndependentAndLeastPrivilege() public {
        bytes32 pendingIntentId = _submit(trader);
        bytes32 evaluatorRole = manager.EVALUATOR_ROLE();
        bytes32 revokerRole = manager.REVOCER_ROLE();
        bytes32 pauserRole = manager.PAUSER_ROLE();
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(evaluator, 1, 2, 3);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(pendingIntentId, trader, 0);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, evaluatorRole
            )
        );
        manager.rejectCapitalIntent(pendingIntentId, scores, EVALUATION_EVIDENCE, REJECTION_REASON);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, evaluatorRole
            )
        );
        manager.approveCapitalIntent(pendingIntentId, scores, authorization);

        (bytes32 approvedIntentId,) = _submitAndApprove(secondTrader);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, revokerRole
            )
        );
        manager.revokeCapitalIntent(approvedIntentId, REVOCATION_REASON);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, pauserRole
            )
        );
        manager.pause();
    }

    function test_initializeRejectsZeroAndInvalidDependencies() public {
        AlphaEngineCapitalStrategyManager.InitializationParams memory params = _params();
        params.initialDefaultAdmin = address(0);
        _expectInitializeRevert(
            params,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ZeroInitializationAddress.selector,
                INITIAL_DEFAULT_ADMIN_FIELD
            )
        );

        params = _params();
        params.initialPauser = address(0);
        _expectInitializeRevert(
            params,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ZeroInitializationAddress.selector,
                INITIAL_PAUSER_FIELD
            )
        );

        params = _params();
        params.initialFheOperator = address(0);
        _expectInitializeRevert(
            params,
            abi.encodeWithSelector(AlphaEngineCapitalStrategyManager.ZeroFheOperator.selector)
        );

        params = _params();
        params.qualificationRegistry = stranger;
        _expectInitializeRevert(
            params,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidQualificationRegistry.selector, stranger
            )
        );
    }

    function test_submitStoresCanonicalHandlesPermissionsPayloadAndNonce() public {
        uint40 deadline = uint40(block.timestamp) + 2 days;
        InEuint128 memory encryptedMarket = createInEuint128(11, trader);
        InEuint128[] memory components = _components(trader, 21, 22);
        bytes32 expectedIntentId = AlphaEngineStrategyHashLib.hashCapitalIntentId(
            block.chainid, address(manager), trader, 0
        );

        vm.recordLogs();
        vm.prank(trader);
        bytes32 intentId =
            manager.submitCapitalIntent(encryptedMarket, TIMEFRAME_KEY, deadline, components);

        assertEq(intentId, expectedIntentId);
        assertEq(manager.traderNonces(trader), 1);
        AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
            manager.getCapitalIntentIdentity(intentId);
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            manager.getCapitalIntentState(intentId);
        bytes32[] memory handles = manager.getCapitalIntentComponents(intentId);
        assertEq(identity.trader, trader);
        assertEq(identity.operatorAtSubmission, fheOperator);
        assertEq(identity.timeframeKey, TIMEFRAME_KEY);
        assertEq(state.deadline, deadline);
        assertEq(state.traderNonce, 0);
        assertEq(state.qualificationVersion, 1);
        assertEq(state.componentCount, 2);
        assertEq(
            uint8(state.status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation)
        );
        assertEq(handles.length, 2);

        bytes32 expectedPayloadHash = AlphaEngineStrategyHashLib.hashCapitalPayload(
            AlphaEngineStrategyHashLib.CapitalPayloadV1({
                chainId: block.chainid,
                manager: address(manager),
                intentId: intentId,
                trader: trader,
                traderNonce: 0,
                qualificationVersion: 1,
                marketIdHandle: identity.marketIdHandle,
                timeframeKey: TIMEFRAME_KEY,
                deadline: deadline,
                componentsHash: AlphaEngineStrategyHashLib.hashComponents(handles)
            })
        );
        assertEq(identity.payloadHash, expectedPayloadHash);
        _assertAllowed(identity.marketIdHandle, address(manager));
        _assertAllowed(identity.marketIdHandle, fheOperator);
        _assertAllowed(handles[0], address(manager));
        _assertAllowed(handles[0], fheOperator);
        _assertAllowed(handles[1], address(manager));
        _assertAllowed(handles[1], fheOperator);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(
            logs[0].topics[0],
            keccak256(
                "CapitalIntentSubmitted(bytes32,address,uint64,bytes32,bytes32,uint40,bytes32,uint64,address)"
            )
        );
        assertEq(logs[0].topics[1], intentId);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(trader))));
        assertEq(logs[0].topics[3], bytes32(uint256(1)));
        (
            bytes32 emittedMarketHandle,
            bytes32 emittedTimeframe,
            uint40 emittedDeadline,
            bytes32 emittedPayloadHash,
            uint64 emittedNonce,
            address emittedOperator
        ) = abi.decode(logs[0].data, (bytes32, bytes32, uint40, bytes32, uint64, address));
        assertEq(emittedMarketHandle, identity.marketIdHandle);
        assertEq(emittedTimeframe, TIMEFRAME_KEY);
        assertEq(emittedDeadline, deadline);
        assertEq(emittedPayloadHash, identity.payloadHash);
        assertEq(emittedNonce, 0);
        assertEq(emittedOperator, fheOperator);
        assertEq(logs[1].topics[0], keccak256("CapitalIntentComponents(bytes32,bytes32[])"));
        assertEq(logs[1].topics[1], intentId);
        assertEq(abi.decode(logs[1].data, (bytes32[])), handles);
    }

    function test_submissionRequiresCurrentQualificationAndBoundedInputs() public {
        InEuint128 memory market = createInEuint128(1, stranger);
        InEuint128[] memory components = _components(stranger, 2, 3);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.TraderNotQualified.selector, stranger
            )
        );
        manager.submitCapitalIntent(
            market, TIMEFRAME_KEY, uint40(block.timestamp) + 1 days, components
        );

        market = createInEuint128(1, trader);
        components = _components(trader, 2, 3);
        vm.startPrank(trader);
        vm.expectRevert(AlphaEngineCapitalStrategyManager.ZeroTimeframeKey.selector);
        manager.submitCapitalIntent(
            market, bytes32(0), uint40(block.timestamp) + 1 days, components
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.DeadlineNotInFuture.selector,
                uint40(block.timestamp),
                block.timestamp
            )
        );
        manager.submitCapitalIntent(market, TIMEFRAME_KEY, uint40(block.timestamp), components);

        InEuint128[] memory emptyComponents = new InEuint128[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidComponentCount.selector, 0
            )
        );
        manager.submitCapitalIntent(
            market, TIMEFRAME_KEY, uint40(block.timestamp) + 1 days, emptyComponents
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.DeadlineExceedsQualification.selector,
                uint40(block.timestamp) + 31 days,
                uint40(block.timestamp) + 30 days,
                uint64(1)
            )
        );
        manager.submitCapitalIntent(
            market, TIMEFRAME_KEY, uint40(block.timestamp) + 31 days, components
        );
        vm.stopPrank();
        assertEq(manager.traderNonces(trader), 0);
    }

    function test_cancelWorksWhilePausedAndIsTraderOnlyAndTerminal() public {
        bytes32 intentId = _submit(trader);
        vm.prank(pauser);
        manager.pause();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.UnauthorizedIntentCancellation.selector,
                stranger,
                intentId
            )
        );
        manager.cancelCapitalIntent(intentId);

        vm.expectEmit(true, true, false, true);
        emit CapitalIntentCancelled(intentId, trader);
        vm.prank(trader);
        manager.cancelCapitalIntent(intentId);
        assertEq(
            uint8(manager.getCapitalIntentState(intentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Cancelled)
        );

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidCapitalIntentStatus.selector,
                intentId,
                AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Cancelled
            )
        );
        manager.cancelCapitalIntent(intentId);
    }

    function test_rejectStoresEncryptedScoresPermissionsAndTerminalEvidence() public {
        bytes32 intentId = _submit(trader);
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(evaluator, 7, 8, 9);

        vm.recordLogs();
        vm.prank(evaluator);
        manager.rejectCapitalIntent(intentId, scores, EVALUATION_EVIDENCE, REJECTION_REASON);

        AlphaEngineCapitalStrategyManager.EvaluationRecord memory evaluation =
            manager.getCapitalEvaluation(intentId);
        assertEq(evaluation.evidenceHash, EVALUATION_EVIDENCE);
        assertEq(evaluation.reasonHash, REJECTION_REASON);
        assertEq(evaluation.executionCommitment, bytes32(0));
        _assertAllowed(evaluation.realSisterScoreHandle, address(manager));
        _assertAllowed(evaluation.realSisterScoreHandle, trader);
        _assertAllowed(evaluation.perturbationP25ScoreHandle, address(manager));
        _assertAllowed(evaluation.perturbationP25ScoreHandle, trader);
        _assertAllowed(evaluation.stressP25ScoreHandle, address(manager));
        _assertAllowed(evaluation.stressP25ScoreHandle, trader);
        assertEq(
            uint8(manager.getCapitalIntentState(intentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Rejected)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(
            logs[0].topics[0],
            keccak256(
                "CapitalEvaluationScoresRecorded(bytes32,address,bytes32,bytes32,bytes32,bytes32)"
            )
        );
        assertEq(logs[0].topics[1], intentId);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(trader))));
        assertEq(
            logs[0].data,
            abi.encode(
                evaluation.realSisterScoreHandle,
                evaluation.perturbationP25ScoreHandle,
                evaluation.stressP25ScoreHandle,
                EVALUATION_EVIDENCE
            )
        );
        assertEq(
            logs[1].topics[0], keccak256("CapitalIntentRejected(bytes32,address,bytes32,bytes32)")
        );
        assertEq(logs[1].topics[1], intentId);
        assertEq(logs[1].topics[2], bytes32(uint256(uint160(trader))));
        assertEq(logs[1].topics[3], EVALUATION_EVIDENCE);
        assertEq(logs[1].data, abi.encode(REJECTION_REASON));

        vm.prank(evaluator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidCapitalIntentStatus.selector,
                intentId,
                AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Rejected
            )
        );
        manager.rejectCapitalIntent(intentId, scores, EVALUATION_EVIDENCE, REJECTION_REASON);
    }

    function test_approveStoresOneExactCommitmentAndEvaluationPermissions() public {
        bytes32 intentId = _submit(trader);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(intentId, trader, 0);
        bytes32 expectedCommitment =
            AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);

        vm.recordLogs();
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(evaluator, 10, 11, 12);
        vm.prank(evaluator);
        bytes32 commitment = manager.approveCapitalIntent(intentId, scores, authorization);

        assertEq(commitment, expectedCommitment);
        assertEq(manager.getApprovedExecutionCommitment(intentId), expectedCommitment);
        assertEq(manager.intentByAuthorizationNonce(0), intentId);
        assertEq(manager.nextAuthorizationNonce(), 1);
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            manager.getCapitalIntentState(intentId);
        assertEq(state.authorizationNonce, 0);
        assertEq(state.authorizationDeadline, authorization.deadline);
        assertEq(
            uint8(state.status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved)
        );
        AlphaEngineCapitalStrategyManager.EvaluationRecord memory evaluation =
            manager.getCapitalEvaluation(intentId);
        assertEq(evaluation.evidenceHash, EVALUATION_EVIDENCE);
        assertEq(evaluation.executionCommitment, expectedCommitment);
        _assertAllowed(evaluation.realSisterScoreHandle, trader);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertEq(
            logs[0].topics[0],
            keccak256(
                "CapitalEvaluationScoresRecorded(bytes32,address,bytes32,bytes32,bytes32,bytes32)"
            )
        );
        assertEq(logs[0].topics[1], intentId);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(trader))));
        assertEq(
            logs[1].topics[0],
            keccak256(
                "CapitalIntentApproved(bytes32,address,bytes32,address,address,address,uint64,uint40,uint40)"
            )
        );
        assertEq(logs[1].topics[1], intentId);
        assertEq(logs[1].topics[2], bytes32(uint256(uint160(trader))));
        assertEq(logs[1].topics[3], expectedCommitment);
        assertEq(
            logs[1].data,
            abi.encode(
                address(executionManager),
                address(fundVault),
                trader,
                uint64(0),
                authorization.validAfter,
                authorization.deadline
            )
        );
        assertEq(
            logs[2].topics[0],
            keccak256(
                "CapitalExecutionPolicyCommitted(bytes32,bytes32,bytes32,uint64,bytes32,bytes32,uint64,bytes32)"
            )
        );
        assertEq(logs[2].topics[1], intentId);
        assertEq(logs[2].topics[2], expectedCommitment);
        assertEq(logs[2].topics[3], POLICY_ROOT);
        assertEq(
            logs[2].data,
            abi.encode(uint64(1), CALLS_HASH, RISK_HASH, uint64(1), EVALUATION_EVIDENCE)
        );
    }

    function test_approvalRejectsMutatedDomainsQualificationNonceAndCommitmentFields() public {
        bytes32 intentId = _submit(trader);
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(evaluator, 1, 2, 3);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(intentId, trader, 0);

        authorization.chainId += 1;
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidAuthorizationDomain.selector,
                authorization.chainId,
                authorization.capitalStrategyManager,
                authorization.intentId,
                authorization.trader
            )
        );
        authorization = _authorization(intentId, trader, 0);
        authorization.qualificationVersion = 2;
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidAuthorizationQualification.selector,
                uint64(2),
                uint64(1)
            )
        );
        authorization = _authorization(intentId, trader, 1);
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.AuthorizationNonceMismatch.selector,
                uint64(1),
                uint64(0)
            )
        );
        authorization = _authorization(intentId, trader, 0);
        authorization.vaultExecutionManager = stranger;
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidVaultExecutionManager.selector, stranger
            )
        );
        authorization = _authorization(intentId, trader, 0);
        authorization.fundVault = stranger;
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidFundVault.selector, stranger
            )
        );
        authorization = _authorization(intentId, trader, 0);
        authorization.executor = address(0);
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(AlphaEngineCapitalStrategyManager.ZeroExecutor.selector)
        );
        authorization = _authorization(intentId, trader, 0);
        authorization.deadline = authorization.validAfter + 1 hours + 1;
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.AuthorizationWindowTooLong.selector,
                uint40(1 hours + 1),
                uint40(1 hours)
            )
        );
        authorization = _authorization(intentId, trader, 0);
        authorization.submissionPayloadHash = keccak256("mutated payload");
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.SubmissionPayloadHashMismatch.selector,
                authorization.submissionPayloadHash,
                manager.getCapitalIntentIdentity(intentId).payloadHash
            )
        );
        authorization = _authorization(intentId, trader, 0);
        authorization.policyRoot = bytes32(0);
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidAuthorizationPolicy.selector,
                bytes32(0),
                uint64(1),
                uint64(1)
            )
        );
        authorization = _authorization(intentId, trader, 0);
        authorization.callsHash = bytes32(0);
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(AlphaEngineCapitalStrategyManager.ZeroCallsHash.selector)
        );
        authorization = _authorization(intentId, trader, 0);
        authorization.riskEnvelopeHash = bytes32(0);
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(AlphaEngineCapitalStrategyManager.ZeroRiskEnvelopeHash.selector)
        );
        authorization = _authorization(intentId, trader, 0);
        authorization.evaluationEvidenceHash = bytes32(0);
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(AlphaEngineCapitalStrategyManager.ZeroEvidenceHash.selector)
        );

        assertEq(manager.nextAuthorizationNonce(), 0);
        assertEq(
            uint8(manager.getCapitalIntentState(intentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation)
        );
    }

    function test_qualificationRevocationAndRequalificationCannotReviveOldIntent() public {
        bytes32 intentId = _submit(trader);
        vm.prank(revoker);
        registry.revokeTrader(trader, REVOCATION_REASON);

        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(intentId, trader, 0);
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory firstScores =
            _scores(evaluator, 1, 2, 3);
        vm.prank(evaluator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.QualificationVersionNotActive.selector,
                trader,
                uint64(1)
            )
        );
        manager.approveCapitalIntent(intentId, firstScores, authorization);

        _qualify(trader, uint40(block.timestamp) + 31 days);
        assertTrue(registry.isQualifiedAtVersion(trader, 3));
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory secondScores =
            _scores(evaluator, 4, 5, 6);
        vm.prank(evaluator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.QualificationVersionNotActive.selector,
                trader,
                uint64(1)
            )
        );
        manager.approveCapitalIntent(intentId, secondScores, authorization);
    }

    function test_exactManagerConsumesOnceAndRecordsReplayState() public {
        (bytes32 intentId, AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization) =
            _submitAndApprove(trader);
        bytes32 commitment = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);
        AlphaEngineExecutionHashLib.CallV1[] memory calls =
            new AlphaEngineExecutionHashLib.CallV1[](0);
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits =
            new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](0);
        bytes32[][] memory proofs = new bytes32[][](0);

        vm.expectEmit(true, true, true, true);
        emit CapitalExecutionConsumed(
            intentId,
            trader,
            commitment,
            address(executionManager),
            trader,
            authorization.authorizationNonce
        );
        vm.prank(trader);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertTrue(manager.isExecutionConsumed(commitment));
        assertTrue(manager.consumedAuthorizationNonces(authorization.authorizationNonce));
        assertEq(executionManager.lastExecutionCommitment(), commitment);
        assertEq(executionManager.successfulExecutions(), 1);
        assertEq(
            uint8(manager.getCapitalIntentState(intentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Consumed)
        );

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidCapitalIntentStatus.selector,
                intentId,
                AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Consumed
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
    }

    function test_downstreamFailureRollsBackConsumptionAtomically() public {
        (bytes32 intentId, AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization) =
            _submitAndApprove(trader);
        bytes32 commitment = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);

        vm.prank(trader);
        vm.expectRevert(MockVaultExecutionManager.ForcedDownstreamFailure.selector);
        executionManager.executeThenRevert(authorization);

        assertFalse(manager.isExecutionConsumed(commitment));
        assertFalse(manager.consumedAuthorizationNonces(authorization.authorizationNonce));
        assertEq(
            uint8(manager.getCapitalIntentState(intentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved)
        );
    }

    function test_consumptionRequiresExecutorWindowQualificationAndAuthorizedManager() public {
        (bytes32 intentId, AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization) =
            _submitAndApprove(trader);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockVaultExecutionManager.UnauthorizedExecutor.selector, stranger, trader
            )
        );
        executionManager.consumeWithoutVaultAction(authorization);

        vm.prank(pauser);
        manager.pause();
        vm.prank(admin);
        manager.setExecutionManagerAuthorization(address(executionManager), false);
        vm.prank(admin);
        manager.unpause();

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ExecutionManagerNotAuthorized.selector,
                address(executionManager)
            )
        );
        executionManager.consumeWithoutVaultAction(authorization);

        vm.prank(pauser);
        manager.pause();
        vm.prank(admin);
        manager.setExecutionManagerAuthorization(address(executionManager), true);
        vm.prank(admin);
        manager.unpause();

        vm.prank(revoker);
        registry.revokeTrader(trader, REVOCATION_REASON);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.QualificationVersionNotActive.selector,
                trader,
                uint64(1)
            )
        );
        executionManager.consumeWithoutVaultAction(authorization);
        assertEq(
            uint8(manager.getCapitalIntentState(intentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved)
        );
    }

    function test_futureAuthorizationAndExpiryBoundsConsumption() public {
        bytes32 intentId = _submit(trader);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(intentId, trader, 0);
        authorization.validAfter = uint40(block.timestamp) + 10 minutes;
        authorization.deadline = authorization.validAfter + 50 minutes;
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(evaluator, 1, 2, 3);
        vm.prank(evaluator);
        manager.approveCapitalIntent(intentId, scores, authorization);

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.AuthorizationNotYetActive.selector,
                authorization.validAfter,
                block.timestamp
            )
        );
        executionManager.consumeWithoutVaultAction(authorization);

        vm.warp(authorization.deadline);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.AuthorizationExpired.selector,
                authorization.deadline,
                block.timestamp
            )
        );
        executionManager.consumeWithoutVaultAction(authorization);
    }

    function test_revokeAndExpireRemainAvailableWhilePaused() public {
        (bytes32 approvedId, AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization)
        = _submitAndApprove(trader);
        bytes32 pendingId = _submit(secondTrader);
        vm.prank(pauser);
        manager.pause();

        bytes32 commitment = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);
        vm.expectEmit(true, true, true, true);
        emit CapitalIntentRevoked(approvedId, trader, commitment, REVOCATION_REASON);
        vm.prank(revoker);
        manager.revokeCapitalIntent(approvedId, REVOCATION_REASON);

        uint40 pendingDeadline = manager.getCapitalIntentState(pendingId).deadline;
        vm.warp(pendingDeadline);
        vm.expectEmit(true, true, false, true);
        emit CapitalIntentExpired(
            pendingId,
            secondTrader,
            AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation,
            pendingDeadline
        );
        manager.expireCapitalIntent(pendingId);
    }

    function test_approvedIntentExpiresAtAuthorizationDeadline() public {
        (bytes32 intentId, AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization) =
            _submitAndApprove(trader);
        vm.warp(authorization.deadline);
        vm.expectEmit(true, true, false, true);
        emit CapitalIntentExpired(
            intentId,
            trader,
            AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved,
            authorization.deadline
        );
        manager.expireCapitalIntent(intentId);
        assertEq(
            uint8(manager.getCapitalIntentState(intentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Expired)
        );
    }

    function test_operatorAndExecutionManagerChangesRequirePausedGovernance() public {
        address newOperator = makeAddr("newOperator");
        vm.prank(admin);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        manager.updateFheOperator(newOperator);

        vm.prank(pauser);
        manager.pause();
        vm.expectEmit(true, true, false, true);
        emit FheOperatorUpdated(fheOperator, newOperator);
        vm.prank(admin);
        manager.updateFheOperator(newOperator);
        assertEq(manager.fheOperator(), newOperator);

        MockVaultExecutionManager secondManager =
            new MockVaultExecutionManager(IAlphaEngineCapitalStrategyManager(address(manager)));
        vm.expectEmit(true, false, false, true);
        emit VaultExecutionManagerAuthorizationUpdated(address(secondManager), false, true);
        vm.prank(admin);
        manager.setExecutionManagerAuthorization(address(secondManager), true);
        assertTrue(manager.approvedExecutionManagers(address(secondManager)));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0)
            )
        );
        manager.setExecutionManagerAuthorization(address(secondManager), false);
    }

    function test_unknownGettersFailTypedAndManagerRejectsNativeTransfer() public {
        bytes32 unknownId = keccak256("unknown");
        assertFalse(manager.existsCapitalIntent(unknownId));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.CapitalIntentNotFound.selector, unknownId
            )
        );
        manager.getCapitalIntentIdentity(unknownId);

        (bool success,) = address(manager).call{value: 1}("");
        assertFalse(success);
        assertEq(address(manager).balance, 0);
    }

    function test_configurationRejectsInvalidUnchangedAndUnauthorizedUpdates() public {
        vm.prank(pauser);
        manager.pause();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidVaultExecutionManager.selector, address(0)
            )
        );
        manager.setExecutionManagerAuthorization(address(0), true);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidVaultExecutionManager.selector, stranger
            )
        );
        manager.setExecutionManagerAuthorization(stranger, true);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ExecutionManagerAuthorizationUnchanged.selector,
                address(executionManager),
                true
            )
        );
        manager.setExecutionManagerAuthorization(address(executionManager), true);

        vm.prank(admin);
        vm.expectRevert(AlphaEngineCapitalStrategyManager.ZeroFheOperator.selector);
        manager.updateFheOperator(address(0));
    }

    function test_expiredQualificationAndZeroCanonicalHandlesFailWithoutNonceChange() public {
        _qualify(stranger, uint40(block.timestamp) + 1);
        vm.warp(block.timestamp + 1);
        InEuint128 memory market = createInEuint128(1, stranger);
        InEuint128[] memory components = _components(stranger, 2, 3);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.QualificationVersionNotActive.selector,
                stranger,
                uint64(1)
            )
        );
        manager.submitCapitalIntent(
            market, TIMEFRAME_KEY, uint40(block.timestamp) + 1 days, components
        );

        bytes memory marketSignature = abi.encode(trader, uint128(7), uint256(0));
        taskManager.registerInput(0, trader, 0, Utils.EUINT128_TFHE, 7, marketSignature);
        InEuint128 memory zeroInput = InEuint128({
            ctHash: 0,
            securityZone: 0,
            utype: Utils.EUINT128_TFHE,
            signature: marketSignature
        });
        components = _components(trader, 4, 5);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ZeroEncryptedHandle.selector, MARKET_ID_FIELD, 0
            )
        );
        manager.submitCapitalIntent(
            zeroInput, TIMEFRAME_KEY, uint40(block.timestamp) + 1 days, components
        );

        market = createInEuint128(8, trader);
        components = new InEuint128[](1);
        components[0] = zeroInput;
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ZeroEncryptedHandle.selector, COMPONENT_FIELD, 0
            )
        );
        manager.submitCapitalIntent(
            market, TIMEFRAME_KEY, uint40(block.timestamp) + 1 days, components
        );
        assertEq(manager.traderNonces(trader), 0);
    }

    function test_rejectionAndEvaluationGetterFailureBranches() public {
        bytes32 intentId = _submit(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidCapitalIntentStatus.selector,
                intentId,
                AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation
            )
        );
        manager.getCapitalEvaluation(intentId);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidCapitalIntentStatus.selector,
                intentId,
                AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation
            )
        );
        manager.getApprovedExecutionCommitment(intentId);

        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(evaluator, 1, 2, 3);
        vm.prank(evaluator);
        vm.expectRevert(AlphaEngineCapitalStrategyManager.ZeroEvidenceHash.selector);
        manager.rejectCapitalIntent(intentId, scores, bytes32(0), REJECTION_REASON);

        vm.prank(evaluator);
        vm.expectRevert(AlphaEngineCapitalStrategyManager.ZeroReasonHash.selector);
        manager.rejectCapitalIntent(intentId, scores, EVALUATION_EVIDENCE, bytes32(0));

        uint40 deadline = manager.getCapitalIntentState(intentId).deadline;
        vm.warp(deadline);
        vm.prank(evaluator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.AuthorizationExpired.selector,
                deadline,
                block.timestamp
            )
        );
        manager.rejectCapitalIntent(intentId, scores, EVALUATION_EVIDENCE, REJECTION_REASON);
    }

    function test_expirationAndRevocationFailureBranches() public {
        bytes32 intentId = _submit(trader);
        uint40 deadline = manager.getCapitalIntentState(intentId).deadline;
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.CapitalIntentNotExpirable.selector,
                intentId,
                AlphaEngineCapitalStrategyManager.CapitalIntentStatus.PendingEvaluation,
                deadline,
                block.timestamp
            )
        );
        manager.expireCapitalIntent(intentId);

        vm.prank(revoker);
        vm.expectRevert(AlphaEngineCapitalStrategyManager.ZeroReasonHash.selector);
        manager.revokeCapitalIntent(intentId, bytes32(0));

        vm.prank(trader);
        manager.cancelCapitalIntent(intentId);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.CapitalIntentNotExpirable.selector,
                intentId,
                AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Cancelled,
                uint40(0),
                block.timestamp
            )
        );
        manager.expireCapitalIntent(intentId);
    }

    function test_approvalAdditionalAuthorizationFailureBranchesAndNonceExhaustion() public {
        bytes32 intentId = _submit(trader);
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(evaluator, 1, 2, 3);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(intentId, trader, 0);

        MockVaultExecutionManager unapprovedManager =
            new MockVaultExecutionManager(IAlphaEngineCapitalStrategyManager(address(manager)));
        authorization.vaultExecutionManager = address(unapprovedManager);
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ExecutionManagerNotAuthorized.selector,
                address(unapprovedManager)
            )
        );

        authorization = _authorization(intentId, trader, 0);
        authorization.deadline = authorization.validAfter;
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidAuthorizationWindow.selector,
                authorization.validAfter,
                authorization.deadline
            )
        );

        authorization = _authorization(intentId, trader, 0);
        uint40 intentDeadline = manager.getCapitalIntentState(intentId).deadline;
        authorization.validAfter = intentDeadline - 30 minutes;
        authorization.deadline = intentDeadline + 1;
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.AuthorizationDeadlineExceedsIntent.selector,
                authorization.deadline,
                intentDeadline
            )
        );

        bytes32 nonceSlot = bytes32(uint256(1));
        uint256 packedConfiguration = uint256(vm.load(address(manager), nonceSlot));
        uint256 nonceMask = uint256(type(uint64).max) << 160;
        vm.store(
            address(manager), nonceSlot, bytes32((packedConfiguration & ~nonceMask) | nonceMask)
        );
        authorization = _authorization(intentId, trader, type(uint64).max);
        _expectApprovalRevert(
            intentId,
            scores,
            authorization,
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.AuthorizationNonceExhausted.selector
            )
        );
    }

    function test_consumptionRejectsDirectCallerMutationAndBothReplayMarkers() public {
        (bytes32 intentId, AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization) =
            _submitAndApprove(trader);
        bytes32 commitment = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.UnauthorizedExecutionConsumer.selector,
                stranger,
                address(executionManager)
            )
        );
        manager.consumeCapitalExecution(authorization);

        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory mutatedAuthorization =
            authorization;
        bytes32 originalCallsHash = authorization.callsHash;
        mutatedAuthorization.callsHash = keccak256("mutated calls");
        bytes32 mutatedCommitment =
            AlphaEngineExecutionHashLib.hashExecutionCommitment(mutatedAuthorization);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ExecutionCommitmentMismatch.selector,
                mutatedCommitment,
                commitment
            )
        );
        executionManager.consumeWithoutVaultAction(mutatedAuthorization);
        authorization.callsHash = originalCallsHash;

        stdstore.target(address(manager)).sig(manager.isExecutionConsumed.selector).with_key(
            commitment
        ).checked_write(true);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ExecutionCommitmentAlreadyConsumed.selector,
                commitment
            )
        );
        executionManager.consumeWithoutVaultAction(authorization);
        stdstore.target(address(manager)).sig(manager.isExecutionConsumed.selector).with_key(
            commitment
        ).checked_write(false);

        stdstore.target(address(manager)).sig(manager.consumedAuthorizationNonces.selector).with_key(
            authorization.authorizationNonce
        ).checked_write(true);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.AuthorizationNonceAlreadyConsumed.selector,
                authorization.authorizationNonce
            )
        );
        executionManager.consumeWithoutVaultAction(authorization);
        assertEq(
            uint8(manager.getCapitalIntentState(intentId).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved)
        );
    }

    function test_zeroScoreHandleAndTraderNonceExhaustionFailLoudly() public {
        bytes32 intentId = _submit(trader);
        bytes memory scoreSignature = abi.encode(evaluator, uint32(7), uint256(0));
        taskManager.registerInput(0, evaluator, 0, Utils.EUINT32_TFHE, 7, scoreSignature);
        InEuint32 memory zeroScore = InEuint32({
            ctHash: 0,
            securityZone: 0,
            utype: Utils.EUINT32_TFHE,
            signature: scoreSignature
        });
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission({
            realSisterScore: zeroScore,
            perturbationP25Score: createInEuint32(8, evaluator),
            stressP25Score: createInEuint32(9, evaluator)
        });
        vm.prank(evaluator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.ZeroEncryptedHandle.selector,
                EVALUATION_SCORE_FIELD,
                0
            )
        );
        manager.rejectCapitalIntent(intentId, scores, EVALUATION_EVIDENCE, REJECTION_REASON);

        stdstore.target(address(manager)).sig(manager.traderNonces.selector).with_key(secondTrader)
            .checked_write(type(uint64).max);
        InEuint128 memory market = createInEuint128(1, secondTrader);
        InEuint128[] memory components = _components(secondTrader, 2, 3);
        vm.prank(secondTrader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.TraderNonceExhausted.selector, secondTrader
            )
        );
        manager.submitCapitalIntent(
            market, TIMEFRAME_KEY, uint40(block.timestamp) + 1 days, components
        );
    }

    function testFuzz_successfulSubmissionsUseIndependentMonotonicNonce(
        uint128 firstMarket,
        uint128 secondMarket,
        uint128 component
    ) public {
        bytes32 firstId = _submitWithValues(trader, firstMarket, component);
        bytes32 secondId = _submitWithValues(trader, secondMarket, component ^ 1);
        assertNotEq(firstId, secondId);
        assertEq(
            firstId,
            AlphaEngineStrategyHashLib.hashCapitalIntentId(
                block.chainid, address(manager), trader, 0
            )
        );
        assertEq(
            secondId,
            AlphaEngineStrategyHashLib.hashCapitalIntentId(
                block.chainid, address(manager), trader, 1
            )
        );
        assertEq(manager.traderNonces(trader), 2);
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

    function _deployManager() private returns (AlphaEngineCapitalStrategyManager deployed) {
        AlphaEngineCapitalStrategyManager implementation = new AlphaEngineCapitalStrategyManager();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(AlphaEngineCapitalStrategyManager.initialize, (_params()))
        );
        return AlphaEngineCapitalStrategyManager(address(proxy));
    }

    function _params()
        private
        view
        returns (AlphaEngineCapitalStrategyManager.InitializationParams memory params)
    {
        return AlphaEngineCapitalStrategyManager.InitializationParams({
            initialDefaultAdmin: admin,
            initialPauser: pauser,
            initialFheOperator: fheOperator,
            qualificationRegistry: address(registry)
        });
    }

    function _qualify(address account, uint40 validUntil) private returns (uint64 version) {
        vm.prank(issuer);
        return registry.qualifyTrader(account, validUntil, COMPETITION_ID, QUALIFICATION_EVIDENCE);
    }

    function _submit(address account) private returns (bytes32 intentId) {
        return _submitWithValues(account, 11, 21);
    }

    function _submitWithValues(address account, uint128 market, uint128 component)
        private
        returns (bytes32 intentId)
    {
        InEuint128 memory encryptedMarket = createInEuint128(market, account);
        InEuint128[] memory encryptedComponents = _components(account, component, component ^ 1);
        vm.prank(account);
        return manager.submitCapitalIntent(
            encryptedMarket, TIMEFRAME_KEY, uint40(block.timestamp) + 2 days, encryptedComponents
        );
    }

    function _submitAndApprove(address account)
        private
        returns (
            bytes32 intentId,
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization
        )
    {
        intentId = _submit(account);
        authorization = _authorization(intentId, account, manager.nextAuthorizationNonce());
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(evaluator, 10, 11, 12);
        vm.prank(evaluator);
        manager.approveCapitalIntent(intentId, scores, authorization);
    }

    function _authorization(bytes32 intentId, address account, uint64 authorizationNonce)
        private
        view
        returns (AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization)
    {
        AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
            manager.getCapitalIntentIdentity(intentId);
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            manager.getCapitalIntentState(intentId);
        return AlphaEngineExecutionHashLib.ExecutionCommitmentV1({
            chainId: block.chainid,
            capitalStrategyManager: address(manager),
            vaultExecutionManager: address(executionManager),
            fundVault: address(fundVault),
            intentId: intentId,
            trader: account,
            qualificationVersion: state.qualificationVersion,
            executor: account,
            authorizationNonce: authorizationNonce,
            validAfter: uint40(block.timestamp),
            deadline: uint40(block.timestamp) + 1 hours,
            policyRoot: POLICY_ROOT,
            policyVersion: 1,
            callsHash: CALLS_HASH,
            riskEnvelopeHash: RISK_HASH,
            riskPolicyVersion: 1,
            submissionPayloadHash: identity.payloadHash,
            evaluationEvidenceHash: EVALUATION_EVIDENCE
        });
    }

    function _components(address account, uint128 first, uint128 second)
        private
        returns (InEuint128[] memory components)
    {
        components = new InEuint128[](2);
        components[0] = createInEuint128(first, account);
        components[1] = createInEuint128(second, account);
    }

    function _scores(address sender, uint32 first, uint32 second, uint32 third)
        private
        returns (AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores)
    {
        return AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission({
            realSisterScore: createInEuint32(first, sender),
            perturbationP25Score: createInEuint32(second, sender),
            stressP25Score: createInEuint32(third, sender)
        });
    }

    function _expectApprovalRevert(
        bytes32 intentId,
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores,
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
        bytes memory revertData
    ) private {
        vm.prank(evaluator);
        vm.expectRevert(revertData);
        manager.approveCapitalIntent(intentId, scores, authorization);
    }

    function _assertAllowed(bytes32 handle, address account) private view {
        assertTrue(taskManager.isAllowed(uint256(handle), account));
    }

    function _expectInitializeRevert(
        AlphaEngineCapitalStrategyManager.InitializationParams memory params,
        bytes memory revertData
    ) private {
        AlphaEngineCapitalStrategyManager implementation = new AlphaEngineCapitalStrategyManager();
        vm.expectRevert(revertData);
        new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(AlphaEngineCapitalStrategyManager.initialize, (params))
        );
    }
}
