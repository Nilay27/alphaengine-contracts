// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {externalEuint32, externalEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {Utils} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";
import {AlphaEngineStrategyHashLib} from "src/libraries/AlphaEngineStrategyHashLib.sol";
import {
    AlphaEngineCompetitionStrategyManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {
    AlphaEngineTraderQualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
import {MockCoFheTaskManager} from "test/mocks/MockCoFheTaskManager.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";

contract AlphaEngineCompetitionStrategyManagerUnitTest is MockCoFheTest {
    AlphaEngineTraderQualificationRegistry private registry;
    AlphaEngineCompetitionStrategyManager private implementation;
    AlphaEngineCompetitionStrategyManager private manager;

    address private admin = makeAddr("admin");
    address private pauser = makeAddr("pauser");
    address private revoker = makeAddr("revoker");
    address private creator = makeAddr("creator");
    address private canceller = makeAddr("canceller");
    address private evaluator = makeAddr("evaluator");
    address private finalizer = makeAddr("finalizer");
    address private qualifier = makeAddr("qualifier");
    address private scoreRevealer = makeAddr("scoreRevealer");
    address private fheOperator = makeAddr("fheOperator");
    address private nextFheOperator = makeAddr("nextFheOperator");
    address private trader = makeAddr("trader");
    address private secondTrader = makeAddr("secondTrader");
    address private stranger = makeAddr("stranger");

    bytes32 private constant RULES_HASH = keccak256("rules");
    bytes32 private constant TIMEFRAME_KEY = keccak256("1h");
    bytes32 private constant EVIDENCE_HASH = keccak256("evidence");
    bytes32 private constant ISSUER_ROLE = keccak256("QUALIFICATION_ISSUER_ROLE");
    bytes32 private constant CREATOR_ROLE = keccak256("COMPETITION_CREATOR_ROLE");
    bytes32 private constant CANCELLER_ROLE = keccak256("COMPETITION_CANCELLER_ROLE");
    bytes32 private constant EVALUATOR_ROLE = keccak256("EVALUATOR_ROLE");
    bytes32 private constant FINALIZER_ROLE = keccak256("FINALIZER_ROLE");
    bytes32 private constant QUALIFIER_ROLE = keccak256("QUALIFIER_ROLE");
    bytes32 private constant SCORE_REVEALER_ROLE = keccak256("SCORE_REVEALER_ROLE");

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
    event SubmissionLimitsUpdated(uint16 limit, uint32 windowSeconds);
    event CompetitionStrategySuperseded(
        bytes32 indexed previousSubmissionId,
        bytes32 indexed replacementSubmissionId,
        bytes32 indexed competitionId,
        address trader
    );

    function setUp() public {
        _installMockTaskManager();
        registry = _deployRegistry();

        implementation = new AlphaEngineCompetitionStrategyManager();
        AlphaEngineCompetitionStrategyManager.InitializationParams memory params = _params();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(AlphaEngineCompetitionStrategyManager.initialize, (params))
        );
        manager = AlphaEngineCompetitionStrategyManager(address(proxy));

        vm.startPrank(admin);
        registry.grantRole(ISSUER_ROLE, address(manager));
        manager.grantRole(CREATOR_ROLE, creator);
        manager.grantRole(CANCELLER_ROLE, canceller);
        manager.grantRole(EVALUATOR_ROLE, evaluator);
        manager.grantRole(FINALIZER_ROLE, finalizer);
        manager.grantRole(QUALIFIER_ROLE, qualifier);
        manager.grantRole(SCORE_REVEALER_ROLE, scoreRevealer);
        registry.unpause();
        manager.unpause();
        vm.stopPrank();
    }

    function test_constructorDisablesImplementationInitializer() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(_params());
    }

    function test_initializeSetsDependenciesAndStartsPausedWithoutOperationalRoles() public {
        AlphaEngineCompetitionStrategyManager freshImplementation =
            new AlphaEngineCompetitionStrategyManager();
        AlphaEngineCompetitionStrategyManager.InitializationParams memory params = _params();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(freshImplementation),
            admin,
            abi.encodeCall(AlphaEngineCompetitionStrategyManager.initialize, (params))
        );
        AlphaEngineCompetitionStrategyManager freshManager =
            AlphaEngineCompetitionStrategyManager(address(proxy));

        assertTrue(freshManager.paused());
        assertEq(address(freshManager.qualificationRegistry()), address(registry));
        assertEq(freshManager.fheOperator(), fheOperator);
        assertEq(freshManager.defaultAdmin(), admin);
        assertEq(freshManager.defaultAdminDelay(), 48 hours);
        assertEq(freshManager.submissionLimit(), 3);
        assertEq(freshManager.submissionWindowSeconds(), 5 minutes);
        assertTrue(freshManager.hasRole(freshManager.PAUSER_ROLE(), pauser));
        assertFalse(freshManager.hasRole(freshManager.COMPETITION_CREATOR_ROLE(), creator));
        assertFalse(freshManager.hasRole(freshManager.COMPETITION_CANCELLER_ROLE(), canceller));
        assertFalse(freshManager.hasRole(freshManager.EVALUATOR_ROLE(), evaluator));
        assertFalse(freshManager.hasRole(freshManager.FINALIZER_ROLE(), finalizer));
        assertFalse(freshManager.hasRole(freshManager.QUALIFIER_ROLE(), qualifier));
        assertFalse(freshManager.hasRole(freshManager.SCORE_REVEALER_ROLE(), scoreRevealer));
    }

    function test_initializeRejectsZeroRoleAndInvalidRegistry() public {
        AlphaEngineCompetitionStrategyManager.InitializationParams memory params = _params();
        params.initialPauser = address(0);
        _expectInitializeRevert(
            params,
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.ZeroInitializationAddress.selector,
                bytes32("initialPauser")
            )
        );

        params = _params();
        params.initialFheOperator = address(0);
        _expectInitializeRevert(
            params,
            abi.encodeWithSelector(AlphaEngineCompetitionStrategyManager.ZeroFheOperator.selector)
        );

        params = _params();
        params.qualificationRegistry = stranger;
        _expectInitializeRevert(
            params,
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidQualificationRegistry.selector,
                stranger
            )
        );
    }

    function test_createCompetitionUsesDomainSeparatedIdAndIncrementsNonce() public {
        AlphaEngineCompetitionStrategyManager.CompetitionConfig memory config = _config(2);
        bytes32 expectedId = AlphaEngineStrategyHashLib.hashCompetitionId(
            block.chainid, address(manager), 0, RULES_HASH
        );

        vm.expectEmit(true, true, true, true);
        emit CompetitionCreated(
            expectedId,
            0,
            RULES_HASH,
            config.submissionDeadline,
            config.evaluationDeadline,
            config.qualificationValidUntil,
            config.qualificationSlots
        );
        vm.prank(creator);
        bytes32 competitionId = manager.createCompetition(config);

        assertEq(competitionId, expectedId);
        assertEq(manager.competitionNonce(), 1);
        assertTrue(manager.existsCompetition(competitionId));
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            manager.getCompetition(competitionId);
        assertEq(
            uint8(competition.status),
            uint8(AlphaEngineCompetitionStrategyManager.CompetitionStatus.Active)
        );
        assertEq(competition.competitionNonce, 0);
        assertEq(competition.rulesHash, RULES_HASH);
    }

    function test_createCompetitionValidatesRoleAndSchedule() public {
        AlphaEngineCompetitionStrategyManager.CompetitionConfig memory config = _config(1);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, CREATOR_ROLE
            )
        );
        manager.createCompetition(config);

        config.rulesHash = bytes32(0);
        vm.prank(creator);
        vm.expectRevert(AlphaEngineCompetitionStrategyManager.ZeroRulesHash.selector);
        manager.createCompetition(config);

        config = _config(0);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidQualificationSlots.selector, 0
            )
        );
        manager.createCompetition(config);

        config = _config(1);
        config.evaluationDeadline = config.submissionDeadline;
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidCompetitionSchedule.selector,
                config.submissionDeadline,
                config.evaluationDeadline,
                config.qualificationValidUntil
            )
        );
        manager.createCompetition(config);
    }

    function test_submitStoresCanonicalHandlesPermissionsPayloadAndNonce() public {
        bytes32 competitionId = _createCompetition(2);
        externalEuint128 market = createExternalEuint128(7, trader);
        externalEuint128[] memory components = _components(trader, 100, 200);
        bytes32 expectedSubmissionId = AlphaEngineStrategyHashLib.hashCompetitionSubmissionId(
            block.chainid, address(manager), competitionId, trader, 0
        );

        vm.prank(trader);
        bytes32 submissionId = manager.submitCompetitionStrategy(
            competitionId,
            TIMEFRAME_KEY,
            market,
            components,
            _strategyProof(address(manager), market, components)
        );

        assertEq(submissionId, expectedSubmissionId);
        assertEq(manager.traderNonces(trader), 1);
        assertEq(manager.activeSubmissionByTrader(competitionId, trader), submissionId);

        AlphaEngineCompetitionStrategyManager.SubmissionIdentity memory identity =
            manager.getSubmissionIdentity(submissionId);
        AlphaEngineCompetitionStrategyManager.SubmissionState memory state =
            manager.getSubmissionState(submissionId);
        bytes32[] memory handles = manager.getSubmissionComponents(submissionId);
        assertEq(identity.trader, trader);
        assertEq(identity.operatorAtSubmission, fheOperator);
        assertEq(identity.marketIdHandle, externalEuint128.unwrap(market));
        assertEq(state.componentCount, 2);
        assertEq(handles[0], externalEuint128.unwrap(components[0]));
        assertEq(handles[1], externalEuint128.unwrap(components[1]));

        bytes32 expectedPayloadHash = AlphaEngineStrategyHashLib.hashCompetitionPayload(
            AlphaEngineStrategyHashLib.CompetitionPayloadV1({
                chainId: block.chainid,
                manager: address(manager),
                submissionId: submissionId,
                competitionId: competitionId,
                trader: trader,
                traderNonce: 0,
                marketIdHandle: externalEuint128.unwrap(market),
                timeframeKey: TIMEFRAME_KEY,
                evaluationDeadline: manager.getCompetition(competitionId).evaluationDeadline,
                componentsHash: AlphaEngineStrategyHashLib.hashComponents(handles)
            })
        );
        assertEq(identity.payloadHash, expectedPayloadHash);

        assertTrue(
            taskManager.isAllowed(uint256(externalEuint128.unwrap(market)), address(manager))
        );
        assertTrue(taskManager.isAllowed(uint256(externalEuint128.unwrap(market)), fheOperator));
        assertTrue(
            taskManager.isAllowed(uint256(externalEuint128.unwrap(components[0])), address(manager))
        );
        assertTrue(
            taskManager.isAllowed(uint256(externalEuint128.unwrap(components[0])), fheOperator)
        );
    }

    function test_maximumSubmissionUsesOneBatchAndScoresUseOneBatch() public {
        bytes32 competitionId = _createCompetition(1);
        externalEuint128 market = createExternalEuint128(7, trader);
        externalEuint128[] memory components = new externalEuint128[](16);
        for (uint256 i; i < 16; ++i) {
            components[i] = createExternalEuint128(uint128(i + 1), trader);
        }
        vm.recordLogs();
        vm.prank(trader);
        bytes32 submissionId = manager.submitCompetitionStrategy(
            competitionId,
            TIMEFRAME_KEY,
            market,
            components,
            _strategyProof(address(manager), market, components)
        );
        assertEq(taskManager.batchVerificationCount(), 1);
        assertEq(taskManager.lastBatchSize(), 17);
        assertEq(manager.getSubmissionComponents(submissionId).length, 16);
        assertGt(vm.getRecordedLogs().length, 0);

        _beginEvaluation(competitionId);
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(90, 80, 70);
        vm.prank(evaluator);
        manager.recordEvaluation(submissionId, scores, 1, EVIDENCE_HASH);
        assertEq(taskManager.batchVerificationCount(), 2);
        assertEq(taskManager.lastBatchSize(), 3);
        assertFalse(
            taskManager.isPubliclyAllowed(uint256(externalEuint32.unwrap(scores.realSisterScore)))
        );
    }

    function test_batchProofRejectsWrongConsumerOrderAndChainWithoutPartialState() public {
        bytes32 competitionId = _createCompetition(1);
        externalEuint128 market = createExternalEuint128(7, trader);
        externalEuint128[] memory components = _components(trader, 100, 200);
        bytes memory wrongConsumerProof =
            _strategyProof(address(implementation), market, components);
        vm.prank(trader);
        vm.expectPartialRevert(MockCoFheTaskManager.InvalidSigner.selector);
        manager.submitCompetitionStrategy(
            competitionId, TIMEFRAME_KEY, market, components, wrongConsumerProof
        );

        bytes memory proof = _strategyProof(address(manager), market, components);
        (components[0], components[1]) = (components[1], components[0]);
        vm.prank(trader);
        vm.expectPartialRevert(MockCoFheTaskManager.InvalidSigner.selector);
        manager.submitCompetitionStrategy(competitionId, TIMEFRAME_KEY, market, components, proof);
        (components[0], components[1]) = (components[1], components[0]);

        uint256 originalChainId = block.chainid;
        vm.chainId(originalChainId + 1);
        vm.prank(trader);
        vm.expectPartialRevert(MockCoFheTaskManager.InvalidSigner.selector);
        manager.submitCompetitionStrategy(competitionId, TIMEFRAME_KEY, market, components, proof);
        vm.chainId(originalChainId);
        assertEq(manager.traderNonces(trader), 0);
        assertEq(manager.activeSubmissionByTrader(competitionId, trader), bytes32(0));
        assertEq(taskManager.batchVerificationCount(), 0);
        assertFalse(
            taskManager.isAllowed(uint256(externalEuint128.unwrap(market)), address(manager))
        );
    }

    function test_cancelWhilePausedClearsActiveSlotAndAllowsFreshNonce() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 firstSubmissionId = _submit(competitionId, trader, 1, 10);

        vm.prank(pauser);
        manager.pause();
        vm.expectEmit(true, true, true, true);
        emit CompetitionStrategyCancelled(firstSubmissionId, competitionId, trader);
        vm.prank(trader);
        manager.cancelCompetitionSubmission(firstSubmissionId);

        assertEq(manager.activeSubmissionByTrader(competitionId, trader), bytes32(0));
        assertEq(
            uint8(manager.getSubmissionState(firstSubmissionId).status),
            uint8(AlphaEngineCompetitionStrategyManager.SubmissionStatus.Cancelled)
        );

        vm.prank(admin);
        manager.unpause();
        bytes32 secondSubmissionId = _submit(competitionId, trader, 2, 20);
        assertNotEq(secondSubmissionId, firstSubmissionId);
        assertEq(manager.traderNonces(trader), 2);
    }

    function test_replacementPreservesHistoryAndOnlyLatestCanBeRanked() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 first = _submit(competitionId, trader, 1, 10);
        bytes32 oldPayload = manager.getSubmissionIdentity(first).payloadHash;
        bytes32 expectedReplacement = AlphaEngineStrategyHashLib.hashCompetitionSubmissionId(
            block.chainid, address(manager), competitionId, trader, 1
        );
        externalEuint128 market = createExternalEuint128(2, trader);
        externalEuint128[] memory components = _components(trader, 20, 30);
        bytes memory proof = _strategyProof(address(manager), market, components);
        vm.expectEmit(true, true, true, true);
        emit CompetitionStrategySuperseded(first, expectedReplacement, competitionId, trader);
        vm.prank(trader);
        bytes32 latest = manager.submitCompetitionStrategy(
            competitionId, TIMEFRAME_KEY, market, components, proof
        );
        assertEq(latest, expectedReplacement);
        assertEq(manager.activeSubmissionByTrader(competitionId, trader), latest);
        assertEq(manager.getCompetition(competitionId).activeSubmissionCount, 1);
        assertEq(
            uint8(manager.getSubmissionState(first).status),
            uint8(AlphaEngineCompetitionStrategyManager.SubmissionStatus.Superseded)
        );
        assertEq(manager.getSubmissionIdentity(first).payloadHash, oldPayload);
        assertEq(manager.getSubmissionComponents(first).length, 2);

        _beginEvaluation(competitionId);
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(1, 2, 3);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.SubmissionNotSubmitted.selector,
                first,
                AlphaEngineCompetitionStrategyManager.SubmissionStatus.Superseded
            )
        );
        vm.prank(evaluator);
        manager.recordEvaluation(first, scores, 1, EVIDENCE_HASH);
        vm.prank(evaluator);
        manager.recordEvaluation(latest, scores, 1, EVIDENCE_HASH);
        vm.prank(finalizer);
        manager.finalizeCompetition(competitionId);
        vm.prank(qualifier);
        manager.publishTraderQualification(latest);
        assertEq(manager.getCompetition(competitionId).evaluatedCount, 1);
        assertEq(manager.getCompetition(competitionId).publishedQualificationCount, 1);
        assertTrue(registry.isQualified(trader));
    }

    function test_threeImmediateSubmissionsAcrossMarketsThenRejectBeforeFhe() public {
        bytes32 competitionId = _createCompetition(1);
        for (uint128 i = 1; i <= 3; ++i) {
            _submit(competitionId, trader, i, i * 10);
        }
        (bool allowed, uint256 nextAllowedAt) = manager.getSubmissionAllowance(trader);
        assertFalse(allowed);
        assertEq(nextAllowedAt, block.timestamp + 5 minutes);
        uint256 verified = taskManager.batchVerificationCount();
        externalEuint128[] memory components = new externalEuint128[](1);
        // Invalid FHE handles/proof would fail if admission reached the Task Manager.
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.SubmissionAllowanceExceeded.selector,
                trader,
                nextAllowedAt
            )
        );
        vm.prank(trader);
        manager.submitCompetitionStrategy(
            competitionId, TIMEFRAME_KEY, externalEuint128.wrap(bytes32(0)), components, ""
        );
        assertEq(taskManager.batchVerificationCount(), verified);
        assertEq(manager.traderNonces(trader), 3);
        assertEq(manager.getCompetition(competitionId).activeSubmissionCount, 1);
        _submit(competitionId, secondTrader, 1, 10);
    }

    function test_rollingWindowExpiresOneSlotAtExactBoundary() public {
        bytes32 competitionId = _createCompetition(1);
        uint256 start = vm.getBlockTimestamp();
        _submit(competitionId, trader, 1, 10);
        vm.warp(start + 100);
        _submit(competitionId, trader, 1, 20);
        vm.warp(start + 200);
        _submit(competitionId, trader, 1, 30);
        vm.warp(start + 299);
        (bool allowed, uint256 nextAllowedAt) = manager.getSubmissionAllowance(trader);
        assertFalse(allowed);
        assertEq(nextAllowedAt, start + 300);
        vm.warp(start + 300);
        (allowed, nextAllowedAt) = manager.getSubmissionAllowance(trader);
        assertTrue(allowed);
        assertEq(nextAllowedAt, 0);
        _submit(competitionId, trader, 1, 40);
        (allowed, nextAllowedAt) = manager.getSubmissionAllowance(trader);
        assertFalse(allowed);
        assertEq(nextAllowedAt, start + 400);
    }

    function test_cancellationAndCompetitionSwitchDoNotRestoreAllowance() public {
        bytes32 firstCompetition = _createCompetition(1);
        bytes32 first = _submit(firstCompetition, trader, 1, 10);
        vm.prank(trader);
        manager.cancelCompetitionSubmission(first);
        bytes32 secondCompetition = _createCompetition(1);
        _submit(secondCompetition, trader, 2, 20);
        _submit(secondCompetition, trader, 3, 30);
        (bool allowed,) = manager.getSubmissionAllowance(trader);
        assertFalse(allowed);
        assertEq(manager.getCompetition(firstCompetition).activeSubmissionCount, 0);
        assertEq(manager.getCompetition(secondCompetition).activeSubmissionCount, 1);
    }

    function test_supersededCancellationCannotClearLatestSlot() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 first = _submit(competitionId, trader, 1, 10);
        bytes32 latest = _submit(competitionId, trader, 2, 20);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.SubmissionNotSubmitted.selector,
                first,
                AlphaEngineCompetitionStrategyManager.SubmissionStatus.Superseded
            )
        );
        vm.prank(trader);
        manager.cancelCompetitionSubmission(first);
        assertEq(manager.activeSubmissionByTrader(competitionId, trader), latest);
        vm.prank(trader);
        manager.cancelCompetitionSubmission(latest);
        assertEq(manager.activeSubmissionByTrader(competitionId, trader), bytes32(0));
        (bool allowed,) = manager.getSubmissionAllowance(trader);
        assertTrue(allowed);
    }

    function test_failedReplacementPreservesSlotNonceAndAllowance() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 first = _submit(competitionId, trader, 1, 10);
        externalEuint128 market = createExternalEuint128(2, trader);
        externalEuint128[] memory components = _components(trader, 20, 30);
        bytes memory proof = _strategyProof(address(implementation), market, components);
        vm.expectPartialRevert(MockCoFheTaskManager.InvalidSigner.selector);
        vm.prank(trader);
        manager.submitCompetitionStrategy(competitionId, TIMEFRAME_KEY, market, components, proof);
        assertEq(manager.activeSubmissionByTrader(competitionId, trader), first);
        assertEq(
            uint8(manager.getSubmissionState(first).status),
            uint8(AlphaEngineCompetitionStrategyManager.SubmissionStatus.Submitted)
        );
        assertEq(manager.traderNonces(trader), 1);
        (bool allowed,) = manager.getSubmissionAllowance(trader);
        assertTrue(allowed);
        assertEq(taskManager.batchVerificationCount(), 1);
    }

    function test_limitsAreConfiguredWhilePausedWithoutResettingHistory() public {
        bytes32 competitionId = _createCompetition(1);
        _submit(competitionId, trader, 1, 10);
        _submit(competitionId, trader, 2, 20);
        vm.prank(admin);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        manager.updateSubmissionLimits(4, 300);
        vm.prank(pauser);
        manager.pause();
        vm.expectEmit(false, false, false, true);
        emit SubmissionLimitsUpdated(1, 600);
        vm.prank(admin);
        manager.updateSubmissionLimits(1, 600);
        (bool allowed, uint256 nextAllowedAt) = manager.getSubmissionAllowance(trader);
        assertFalse(allowed);
        assertEq(nextAllowedAt, block.timestamp + 600);
        vm.prank(admin);
        manager.updateSubmissionLimits(4, 300);
        (allowed,) = manager.getSubmissionAllowance(trader);
        assertTrue(allowed);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidSubmissionLimits.selector,
                uint16(0),
                uint32(300)
            )
        );
        vm.prank(admin);
        manager.updateSubmissionLimits(0, 300);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidSubmissionLimits.selector,
                uint16(257),
                uint32(300)
            )
        );
        vm.prank(admin);
        manager.updateSubmissionLimits(257, 300);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidSubmissionLimits.selector,
                uint16(3),
                uint32(0)
            )
        );
        vm.prank(admin);
        manager.updateSubmissionLimits(3, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0)
            )
        );
        vm.prank(stranger);
        manager.updateSubmissionLimits(3, 300);
    }

    function test_submissionHistoryWrapsWithoutLosingRollingLimit() public {
        vm.prank(pauser);
        manager.pause();
        vm.prank(admin);
        manager.updateSubmissionLimits(3, 1);
        vm.prank(admin);
        manager.unpause();
        bytes32 competitionId = _createCompetition(1);
        for (uint128 i; i < 270; ++i) {
            if (i % 3 == 0) vm.warp(vm.getBlockTimestamp() + 1);
            _submit(competitionId, trader, 1, i + 1);
        }
        (bool allowed, uint256 nextAllowedAt) = manager.getSubmissionAllowance(trader);
        assertFalse(allowed);
        assertEq(nextAllowedAt, block.timestamp + 1);
        assertEq(manager.getCompetition(competitionId).activeSubmissionCount, 1);
    }

    function test_existingTraderCanReplaceAtCompetitionCapacity() public {
        bytes32 competitionId = _createCompetition(1);
        for (uint16 i; i < 256; ++i) {
            _submit(competitionId, address(uint160(0x1000 + i)), 1, i + 1);
        }
        address firstTrader = address(0x1000);
        bytes32 previous = manager.activeSubmissionByTrader(competitionId, firstTrader);
        bytes32 latest = _submit(competitionId, firstTrader, 2, 42);
        assertEq(manager.getCompetition(competitionId).activeSubmissionCount, 256);
        assertEq(manager.activeSubmissionByTrader(competitionId, firstTrader), latest);
        assertEq(
            uint8(manager.getSubmissionState(previous).status),
            uint8(AlphaEngineCompetitionStrategyManager.SubmissionStatus.Superseded)
        );
        externalEuint128[] memory components = new externalEuint128[](1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.MaximumActiveSubmissionsReached.selector,
                competitionId
            )
        );
        vm.prank(stranger);
        manager.submitCompetitionStrategy(
            competitionId, TIMEFRAME_KEY, externalEuint128.wrap(bytes32(0)), components, ""
        );
    }

    function test_deadlineFreezesFinalEntryBeforeFheVerification() public {
        bytes32 competitionId = _createCompetition(1);
        _submit(competitionId, trader, 1, 10);
        bytes32 latest = _submit(competitionId, trader, 2, 20);
        uint40 deadline = manager.getCompetition(competitionId).submissionDeadline;
        vm.warp(deadline);
        externalEuint128[] memory components = new externalEuint128[](1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionSubmissionClosed.selector,
                competitionId,
                deadline,
                uint256(deadline)
            )
        );
        vm.prank(trader);
        manager.submitCompetitionStrategy(
            competitionId, TIMEFRAME_KEY, externalEuint128.wrap(bytes32(0)), components, ""
        );
        assertEq(manager.activeSubmissionByTrader(competitionId, trader), latest);
        assertEq(taskManager.batchVerificationCount(), 2);
    }

    function test_invalidSubmissionInputsRevert() public {
        bytes32 competitionId = _createCompetition(1);

        externalEuint128 secondMarket = createExternalEuint128(2, secondTrader);
        externalEuint128[] memory secondComponents = _components(secondTrader, 20, 30);
        vm.prank(secondTrader);
        vm.expectRevert(AlphaEngineCompetitionStrategyManager.ZeroTimeframeKey.selector);
        manager.submitCompetitionStrategy(
            competitionId,
            bytes32(0),
            secondMarket,
            secondComponents,
            _strategyProof(address(manager), secondMarket, secondComponents)
        );

        externalEuint128[] memory noComponents = new externalEuint128[](0);
        externalEuint128 thirdMarket = createExternalEuint128(3, secondTrader);
        vm.prank(secondTrader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidComponentCount.selector, 0
            )
        );
        manager.submitCompetitionStrategy(
            competitionId,
            TIMEFRAME_KEY,
            thirdMarket,
            noComponents,
            _strategyProof(address(manager), thirdMarket, noComponents)
        );
    }

    function test_unconfiguredUpgradeAllowanceFailsClosed() public {
        // New packed configuration occupies the first slot after the timestamp mapping.
        vm.store(address(manager), bytes32(uint256(12)), bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidSubmissionLimits.selector,
                uint16(0),
                uint32(0)
            )
        );
        manager.getSubmissionAllowance(trader);
    }

    function test_legacyNonceDoesNotInventAdmissionHistory() public {
        vm.store(address(manager), keccak256(abi.encode(trader, uint256(6))), bytes32(uint256(300)));
        (bool allowed,) = manager.getSubmissionAllowance(trader);
        assertTrue(allowed);
        bytes32 competitionId = _createCompetition(1);
        for (uint128 i; i < 3; ++i) {
            _submit(competitionId, trader, i + 1, i + 1);
        }
        (allowed,) = manager.getSubmissionAllowance(trader);
        assertFalse(allowed);
        assertEq(manager.traderNonces(trader), 303);
    }

    function test_zeroTimestampRemainsARealAdmissionRecord() public {
        vm.warp(0);
        bytes32 competitionId = _createCompetition(1);
        for (uint128 i; i < 3; ++i) {
            _submit(competitionId, trader, i + 1, i + 1);
        }
        (bool allowed, uint256 nextAllowedAt) = manager.getSubmissionAllowance(trader);
        assertFalse(allowed);
        assertEq(nextAllowedAt, 300);
    }

    function test_zeroCanonicalHandleFailsLoudly() public {
        bytes32 competitionId = _createCompetition(1);
        taskManager.registerInput(0, trader, 0, Utils.EUINT128_TFHE, 7);
        _inputSenders[bytes32(0)] = trader;
        externalEuint128 zeroHandleInput = externalEuint128.wrap(bytes32(0));
        externalEuint128[] memory components = _components(trader, 1, 2);

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.ZeroEncryptedHandle.selector,
                bytes32("marketId"),
                0
            )
        );
        manager.submitCompetitionStrategy(
            competitionId,
            TIMEFRAME_KEY,
            zeroHandleInput,
            components,
            _strategyProof(address(manager), zeroHandleInput, components)
        );
    }

    function test_evaluationLifecycleStoresScoresPermissionsAndUniqueRank() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 submissionId = _submit(competitionId, trader, 1, 10);
        _beginEvaluation(competitionId);
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(100, 90, 80);

        vm.expectEmit(true, true, true, true);
        emit CompetitionEvaluationRecorded(
            submissionId,
            competitionId,
            trader,
            1,
            externalEuint32.unwrap(scores.realSisterScore),
            externalEuint32.unwrap(scores.perturbationP25Score),
            externalEuint32.unwrap(scores.stressP25Score),
            EVIDENCE_HASH
        );
        vm.prank(evaluator);
        manager.recordEvaluation(submissionId, scores, 1, EVIDENCE_HASH);

        AlphaEngineCompetitionStrategyManager.EvaluationRecord memory evaluation =
            manager.getEvaluation(submissionId);
        assertEq(evaluation.realSisterScoreHandle, externalEuint32.unwrap(scores.realSisterScore));
        assertEq(evaluation.evidenceHash, EVIDENCE_HASH);
        assertEq(manager.submissionByRank(competitionId, 1), submissionId);
        assertTrue(
            taskManager.isAllowed(
                uint256(externalEuint32.unwrap(scores.realSisterScore)), address(manager)
            )
        );
        assertTrue(
            taskManager.isAllowed(uint256(externalEuint32.unwrap(scores.realSisterScore)), trader)
        );
    }

    function test_rankMustBeBoundedUniqueAndEvaluationOneShot() public {
        bytes32 competitionId = _createCompetition(2);
        bytes32 firstSubmissionId = _submit(competitionId, trader, 1, 10);
        bytes32 secondSubmissionId = _submit(competitionId, secondTrader, 2, 20);
        _beginEvaluation(competitionId);
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory invalidRankScores =
            _scores(1, 2, 3);

        vm.prank(evaluator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidRank.selector, competitionId, 0, 2
            )
        );
        manager.recordEvaluation(firstSubmissionId, invalidRankScores, 0, EVIDENCE_HASH);

        _evaluate(firstSubmissionId, 1, 100);
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory duplicateRankScores =
            _scores(4, 5, 6);
        vm.prank(evaluator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.RankAlreadyAssigned.selector,
                competitionId,
                1,
                firstSubmissionId
            )
        );
        manager.recordEvaluation(secondSubmissionId, duplicateRankScores, 1, EVIDENCE_HASH);

        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory repeatedScores =
            _scores(7, 8, 9);
        vm.prank(evaluator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.SubmissionNotSubmitted.selector,
                firstSubmissionId,
                AlphaEngineCompetitionStrategyManager.SubmissionStatus.Evaluated
            )
        );
        manager.recordEvaluation(firstSubmissionId, repeatedScores, 2, EVIDENCE_HASH);
    }

    function test_finalizeRequiresEveryActiveSubmissionEvaluated() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 firstSubmissionId = _submit(competitionId, trader, 1, 10);
        bytes32 secondSubmissionId = _submit(competitionId, secondTrader, 2, 20);
        _beginEvaluation(competitionId);
        _evaluate(firstSubmissionId, 1, 100);

        vm.prank(finalizer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionEvaluationIncomplete.selector,
                competitionId,
                1,
                2
            )
        );
        manager.finalizeCompetition(competitionId);

        _evaluate(secondSubmissionId, 2, 200);
        vm.expectEmit(true, false, false, true);
        emit CompetitionFinalized(competitionId, 2, 1);
        vm.prank(finalizer);
        manager.finalizeCompetition(competitionId);
    }

    function test_scoreRevealPacingIsGlobalAndQualificationDoesNotWait() public {
        bytes32 firstCompetition = _createCompetition(1);
        bytes32 secondCompetition = _createCompetition(1);
        bytes32 first = _submit(firstCompetition, trader, 1, 10);
        bytes32 second = _submit(secondCompetition, secondTrader, 2, 20);
        _beginEvaluation(firstCompetition);
        _beginEvaluation(secondCompetition);
        _evaluate(first, 1, 100);
        _evaluate(second, 1, 200);
        vm.startPrank(finalizer);
        manager.finalizeCompetition(firstCompetition);
        manager.finalizeCompetition(secondCompetition);
        vm.stopPrank();
        vm.prank(qualifier);
        manager.publishTraderQualification(second);
        assertTrue(manager.getSubmissionState(second).qualificationPublished);
        assertEq(manager.scoreRevealedThrough(secondCompetition), 0);
        vm.prank(scoreRevealer);
        manager.requestCompetitionScoreReveal(firstCompetition, 1, 1);
        uint40 available = manager.nextScoreRevealAt();
        assertEq(available, block.timestamp + 5 seconds);
        vm.prank(scoreRevealer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.ScoreRevealCursorMismatch.selector,
                firstCompetition,
                1,
                2
            )
        );
        manager.requestCompetitionScoreReveal(firstCompetition, 1, 1);
        vm.prank(scoreRevealer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.ScoreRevealNotAvailable.selector, available
            )
        );
        manager.requestCompetitionScoreReveal(secondCompetition, 1, 1);
        assertEq(manager.scoreRevealedThrough(secondCompetition), 0);
        vm.warp(available - 1);
        vm.prank(scoreRevealer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.ScoreRevealNotAvailable.selector, available
            )
        );
        manager.requestCompetitionScoreReveal(secondCompetition, 1, 1);
        vm.warp(available);
        vm.prank(scoreRevealer);
        manager.requestCompetitionScoreReveal(secondCompetition, 1, 1);
        assertEq(manager.scoreRevealedThrough(secondCompetition), 1);
    }

    function test_fullCompetitionRevealsEachScoreOnceIn32PacedBatches() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32[] memory submissions = new bytes32[](256);
        for (uint16 i; i < 256; ++i) {
            submissions[i] = _submit(
                competitionId, address(uint160(0x7000 + i)), uint128(i + 1), uint128(i + 10)
            );
        }
        _beginEvaluation(competitionId);
        for (uint16 i; i < 256; ++i) {
            _evaluate(submissions[i], i + 1, uint32(i + 100));
        }
        vm.prank(finalizer);
        manager.finalizeCompetition(competitionId);
        vm.prank(scoreRevealer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.ScoreRevealCursorMismatch.selector,
                competitionId,
                2,
                1
            )
        );
        manager.requestCompetitionScoreReveal(competitionId, 2, 8);
        uint256 firstAt = vm.getBlockTimestamp();
        for (uint16 start = 1; start <= 256; start += 8) {
            if (block.timestamp < manager.nextScoreRevealAt()) {
                vm.warp(manager.nextScoreRevealAt());
            }
            vm.prank(scoreRevealer);
            (uint16 next, uint16 count) =
                manager.requestCompetitionScoreReveal(competitionId, start, 8);
            assertEq(next, start + 8);
            assertEq(count, 8);
            assertEq(manager.scoreRevealedThrough(competitionId), next - 1);
        }
        assertEq(vm.getBlockTimestamp() - firstAt, 155);
        for (uint16 i; i < 256; ++i) {
            AlphaEngineCompetitionStrategyManager.EvaluationRecord memory evaluation =
                manager.getEvaluation(submissions[i]);
            assertEq(taskManager.publicAllowCount(uint256(evaluation.realSisterScoreHandle)), 1);
            assertEq(
                taskManager.publicAllowCount(uint256(evaluation.perturbationP25ScoreHandle)), 1
            );
            assertEq(taskManager.publicAllowCount(uint256(evaluation.stressP25ScoreHandle)), 1);
        }
        vm.prank(scoreRevealer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.ScoreRevealCursorMismatch.selector,
                competitionId,
                1,
                257
            )
        );
        manager.requestCompetitionScoreReveal(competitionId, 1, 8);
    }

    function test_failedRevealRollsBackCursorPacingAndEarlierGrants() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 submission = _submit(competitionId, trader, 1, 10);
        _beginEvaluation(competitionId);
        _evaluate(submission, 1, 100);
        vm.prank(finalizer);
        manager.finalizeCompetition(competitionId);
        AlphaEngineCompetitionStrategyManager.EvaluationRecord memory evaluation =
            manager.getEvaluation(submission);
        bytes memory failure = abi.encodeWithSignature(
            "SenderNotAllowed(uint256,address)",
            uint256(evaluation.stressP25ScoreHandle),
            address(manager)
        );
        vm.mockCallRevert(
            address(taskManager),
            abi.encodeWithSelector(
                taskManager.allowGlobal.selector, uint256(evaluation.stressP25ScoreHandle)
            ),
            failure
        );
        vm.prank(scoreRevealer);
        vm.expectRevert(failure);
        manager.requestCompetitionScoreReveal(competitionId, 1, 1);
        assertEq(manager.scoreRevealedThrough(competitionId), 0);
        assertEq(manager.nextScoreRevealAt(), 0);
        assertEq(taskManager.publicAllowCount(uint256(evaluation.realSisterScoreHandle)), 0);
        assertEq(taskManager.publicAllowCount(uint256(evaluation.perturbationP25ScoreHandle)), 0);
        vm.clearMockedCalls();
        vm.prank(scoreRevealer);
        manager.requestCompetitionScoreReveal(competitionId, 1, 1);
        assertEq(manager.scoreRevealedThrough(competitionId), 1);
    }

    function test_scoreRevealRequestsAsyncDecryptionsAndExposesPublishedResults() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 submissionId = _submit(competitionId, trader, 1, 10);
        _beginEvaluation(competitionId);
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory encryptedScores =
            _scores(115, 82, 74);
        vm.prank(evaluator);
        manager.recordEvaluation(submissionId, encryptedScores, 1, EVIDENCE_HASH);
        vm.prank(finalizer);
        manager.finalizeCompetition(competitionId);

        vm.expectEmit(true, true, true, true);
        emit CompetitionScoreRevealRequested(
            competitionId,
            submissionId,
            trader,
            1,
            externalEuint32.unwrap(encryptedScores.realSisterScore),
            externalEuint32.unwrap(encryptedScores.perturbationP25Score),
            externalEuint32.unwrap(encryptedScores.stressP25Score)
        );
        vm.prank(scoreRevealer);
        (uint16 nextRank, uint16 requestedCount) =
            manager.requestCompetitionScoreReveal(competitionId, 1, 8);

        assertEq(nextRank, 2);
        assertEq(requestedCount, 1);
        assertEq(
            taskManager.publicAllowCount(
                uint256(externalEuint32.unwrap(encryptedScores.realSisterScore))
            ),
            1
        );
        assertEq(
            taskManager.publicAllowCount(
                uint256(externalEuint32.unwrap(encryptedScores.perturbationP25Score))
            ),
            1
        );
        assertEq(
            taskManager.publicAllowCount(
                uint256(externalEuint32.unwrap(encryptedScores.stressP25Score))
            ),
            1
        );
        assertEq(
            taskManager.lastPublicAllower(
                uint256(externalEuint32.unwrap(encryptedScores.realSisterScore))
            ),
            address(manager)
        );

        AlphaEngineCompetitionStrategyManager.PublicEvaluationScores memory pendingScores =
            manager.getPublicEvaluationScores(submissionId);
        assertFalse(pendingScores.realSisterScoreReady);
        assertFalse(pendingScores.perturbationP25ScoreReady);
        assertFalse(pendingScores.stressP25ScoreReady);

        taskManager.publishDecryptResult(
            uint256(externalEuint32.unwrap(encryptedScores.realSisterScore)), 115, ""
        );
        AlphaEngineCompetitionStrategyManager.PublicEvaluationScores memory partialScores =
            manager.getPublicEvaluationScores(submissionId);
        assertEq(partialScores.realSisterScore, 115);
        assertTrue(partialScores.realSisterScoreReady);
        assertFalse(partialScores.perturbationP25ScoreReady);
        assertFalse(partialScores.stressP25ScoreReady);

        uint256[] memory handles = new uint256[](2);
        handles[0] = uint256(externalEuint32.unwrap(encryptedScores.perturbationP25Score));
        handles[1] = uint256(externalEuint32.unwrap(encryptedScores.stressP25Score));
        uint256[] memory plaintextScores = new uint256[](2);
        plaintextScores[0] = 82;
        plaintextScores[1] = 74;
        taskManager.publishDecryptResultBatch(handles, plaintextScores, new bytes[](2));

        AlphaEngineCompetitionStrategyManager.PublicEvaluationScores memory publicScores =
            manager.getPublicEvaluationScores(submissionId);
        assertEq(publicScores.realSisterScore, 115);
        assertEq(publicScores.perturbationP25Score, 82);
        assertEq(publicScores.stressP25Score, 74);
        assertTrue(publicScores.realSisterScoreReady);
        assertTrue(publicScores.perturbationP25ScoreReady);
        assertTrue(publicScores.stressP25ScoreReady);
    }

    function test_scoreRevealRequiresFinalizationRoleAndBoundedRange() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 submissionId = _submit(competitionId, trader, 1, 10);
        _beginEvaluation(competitionId);
        _evaluate(submissionId, 1, 100);

        vm.prank(scoreRevealer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionNotFinalized.selector,
                competitionId,
                AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating
            )
        );
        manager.requestCompetitionScoreReveal(competitionId, 1, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionNotFinalized.selector,
                competitionId,
                AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating
            )
        );
        manager.getPublicEvaluationScores(submissionId);

        vm.prank(finalizer);
        manager.finalizeCompetition(competitionId);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                SCORE_REVEALER_ROLE
            )
        );
        manager.requestCompetitionScoreReveal(competitionId, 1, 1);

        vm.startPrank(scoreRevealer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidScoreRevealStartRank.selector,
                competitionId,
                0,
                1
            )
        );
        manager.requestCompetitionScoreReveal(competitionId, 0, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidScoreRevealStartRank.selector,
                competitionId,
                2,
                1
            )
        );
        manager.requestCompetitionScoreReveal(competitionId, 2, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidScoreRevealBatchSize.selector, 0, 8
            )
        );
        manager.requestCompetitionScoreReveal(competitionId, 1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidScoreRevealBatchSize.selector, 9, 8
            )
        );
        manager.requestCompetitionScoreReveal(competitionId, 1, 9);
        vm.stopPrank();

        bytes32 secondCompetitionId = _createCompetition(1);
        bytes32 cancelledSubmissionId = _submit(secondCompetitionId, trader, 2, 20);
        vm.prank(trader);
        manager.cancelCompetitionSubmission(cancelledSubmissionId);
        bytes32 evaluatedSubmissionId = _submit(secondCompetitionId, secondTrader, 3, 30);
        _beginEvaluation(secondCompetitionId);
        _evaluate(evaluatedSubmissionId, 1, 200);
        vm.prank(finalizer);
        manager.finalizeCompetition(secondCompetitionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.SubmissionNotSubmitted.selector,
                cancelledSubmissionId,
                AlphaEngineCompetitionStrategyManager.SubmissionStatus.Cancelled
            )
        );
        manager.getPublicEvaluationScores(cancelledSubmissionId);
    }

    function test_scoreRevealPaginationUsesFinalRankOrder() public {
        bytes32 competitionId = _createCompetition(2);
        bytes32 firstSubmissionId = _submit(competitionId, trader, 1, 10);
        bytes32 secondSubmissionId = _submit(competitionId, secondTrader, 2, 20);
        _beginEvaluation(competitionId);

        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory secondRankScores =
            _scores(80, 70, 60);
        vm.prank(evaluator);
        manager.recordEvaluation(firstSubmissionId, secondRankScores, 2, EVIDENCE_HASH);
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory firstRankScores =
            _scores(110, 100, 90);
        vm.prank(evaluator);
        manager.recordEvaluation(secondSubmissionId, firstRankScores, 1, EVIDENCE_HASH);
        vm.prank(finalizer);
        manager.finalizeCompetition(competitionId);

        vm.prank(scoreRevealer);
        (uint16 nextRank, uint16 requestedCount) =
            manager.requestCompetitionScoreReveal(competitionId, 1, 1);
        assertEq(nextRank, 2);
        assertEq(requestedCount, 1);
        assertEq(
            taskManager.publicAllowCount(
                uint256(externalEuint32.unwrap(firstRankScores.realSisterScore))
            ),
            1
        );
        assertEq(
            taskManager.publicAllowCount(
                uint256(externalEuint32.unwrap(secondRankScores.realSisterScore))
            ),
            0
        );

        vm.warp(manager.nextScoreRevealAt());
        vm.prank(scoreRevealer);
        (nextRank, requestedCount) =
            manager.requestCompetitionScoreReveal(competitionId, nextRank, 8);
        assertEq(nextRank, 3);
        assertEq(requestedCount, 1);
        assertEq(
            taskManager.publicAllowCount(
                uint256(externalEuint32.unwrap(secondRankScores.realSisterScore))
            ),
            1
        );
    }

    function test_publishQualificationOnlyAfterFinalizationAndOnlyForEligibleRank() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 winnerSubmissionId = _submit(competitionId, trader, 1, 10);
        bytes32 loserSubmissionId = _submit(competitionId, secondTrader, 2, 20);
        _beginEvaluation(competitionId);
        _evaluate(winnerSubmissionId, 1, 100);
        _evaluate(loserSubmissionId, 2, 200);

        vm.prank(qualifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionNotFinalized.selector,
                competitionId,
                AlphaEngineCompetitionStrategyManager.CompetitionStatus.Evaluating
            )
        );
        manager.publishTraderQualification(winnerSubmissionId);

        vm.prank(finalizer);
        manager.finalizeCompetition(competitionId);
        uint40 validUntil = manager.getCompetition(competitionId).qualificationValidUntil;

        vm.expectEmit(true, true, true, true);
        emit TraderQualificationPublished(
            competitionId, winnerSubmissionId, trader, 1, 1, validUntil, EVIDENCE_HASH
        );
        vm.prank(qualifier);
        uint64 version = manager.publishTraderQualification(winnerSubmissionId);
        assertEq(version, 1);
        assertTrue(registry.isQualifiedAtVersion(trader, 1));

        vm.prank(qualifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.SubmissionNotEligible.selector,
                loserSubmissionId,
                2,
                1
            )
        );
        manager.publishTraderQualification(loserSubmissionId);

        vm.prank(qualifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.QualificationAlreadyPublished.selector,
                winnerSubmissionId
            )
        );
        manager.publishTraderQualification(winnerSubmissionId);
    }

    function test_beginEvaluationEnforcesWindowAndExpiredCompetitionCanBeCancelled() public {
        bytes32 competitionId = _createCompetition(1);
        _submit(competitionId, trader, 1, 10);
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            manager.getCompetition(competitionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.CompetitionEvaluationNotStarted.selector,
                competitionId,
                competition.submissionDeadline,
                block.timestamp
            )
        );
        manager.beginEvaluation(competitionId);

        vm.warp(competition.evaluationDeadline + 1);
        vm.expectEmit(true, true, false, true);
        emit CompetitionCancelled(competitionId, stranger);
        vm.prank(stranger);
        manager.cancelExpiredCompetition(competitionId);
        assertEq(
            uint8(manager.getCompetition(competitionId).status),
            uint8(AlphaEngineCompetitionStrategyManager.CompetitionStatus.Cancelled)
        );
    }

    function test_emergencyCancellerCanCancelWhilePaused() public {
        bytes32 competitionId = _createCompetition(1);
        vm.prank(pauser);
        manager.pause();

        vm.expectEmit(true, true, false, true);
        emit CompetitionCancelled(competitionId, canceller);
        vm.prank(canceller);
        manager.cancelCompetition(competitionId);
    }

    function test_operatorRotationRequiresPausedGovernanceAndOnlyAffectsFutureSubmissions() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 firstSubmissionId = _submit(competitionId, trader, 1, 10);

        vm.prank(admin);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        manager.updateFheOperator(nextFheOperator);

        vm.prank(pauser);
        manager.pause();
        vm.expectEmit(true, true, false, true);
        emit FheOperatorUpdated(fheOperator, nextFheOperator);
        vm.prank(admin);
        manager.updateFheOperator(nextFheOperator);
        vm.prank(admin);
        manager.unpause();

        bytes32 secondSubmissionId = _submit(competitionId, secondTrader, 2, 20);
        assertEq(manager.getSubmissionIdentity(firstSubmissionId).operatorAtSubmission, fheOperator);
        assertEq(
            manager.getSubmissionIdentity(secondSubmissionId).operatorAtSubmission, nextFheOperator
        );
    }

    function testFuzz_submissionNonceAndIdAreUniqueAfterCancellation(
        uint128 marketA,
        uint128 marketB
    ) public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 firstId = _submit(competitionId, trader, marketA, 10);
        vm.prank(trader);
        manager.cancelCompetitionSubmission(firstId);
        bytes32 secondId = _submit(competitionId, trader, marketB, 20);

        assertNotEq(firstId, secondId);
        assertEq(manager.getSubmissionState(firstId).traderNonce, 0);
        assertEq(manager.getSubmissionState(secondId).traderNonce, 1);
        assertEq(manager.traderNonces(trader), 2);
    }

    function _deployRegistry() private returns (AlphaEngineTraderQualificationRegistry deployed) {
        AlphaEngineTraderQualificationRegistry registryImplementation =
            new AlphaEngineTraderQualificationRegistry();
        TransparentUpgradeableProxy registryProxy = new TransparentUpgradeableProxy(
            address(registryImplementation),
            admin,
            abi.encodeCall(
                AlphaEngineTraderQualificationRegistry.initialize, (admin, pauser, revoker)
            )
        );
        return AlphaEngineTraderQualificationRegistry(address(registryProxy));
    }

    function _params()
        private
        view
        returns (AlphaEngineCompetitionStrategyManager.InitializationParams memory params)
    {
        return AlphaEngineCompetitionStrategyManager.InitializationParams({
            initialDefaultAdmin: admin,
            initialPauser: pauser,
            initialFheOperator: fheOperator,
            qualificationRegistry: address(registry)
        });
    }

    function _config(uint16 qualificationSlots)
        private
        view
        returns (AlphaEngineCompetitionStrategyManager.CompetitionConfig memory config)
    {
        return AlphaEngineCompetitionStrategyManager.CompetitionConfig({
            rulesHash: RULES_HASH,
            submissionDeadline: uint40(block.timestamp) + 1 days,
            evaluationDeadline: uint40(block.timestamp) + 2 days,
            qualificationValidUntil: uint40(block.timestamp) + 30 days,
            qualificationSlots: qualificationSlots
        });
    }

    function _createCompetition(uint16 qualificationSlots) private returns (bytes32 competitionId) {
        vm.prank(creator);
        return manager.createCompetition(_config(qualificationSlots));
    }

    function _submit(bytes32 competitionId, address account, uint128 market, uint128 component)
        private
        returns (bytes32 submissionId)
    {
        externalEuint128 encryptedMarket = createExternalEuint128(market, account);
        externalEuint128[] memory encryptedComponents =
            _components(account, component, component ^ 1);
        vm.prank(account);
        return manager.submitCompetitionStrategy(
            competitionId,
            TIMEFRAME_KEY,
            encryptedMarket,
            encryptedComponents,
            _strategyProof(address(manager), encryptedMarket, encryptedComponents)
        );
    }

    function _components(address account, uint128 first, uint128 second)
        private
        returns (externalEuint128[] memory components)
    {
        components = new externalEuint128[](2);
        components[0] = createExternalEuint128(first, account);
        components[1] = createExternalEuint128(second, account);
    }

    function _scores(uint32 first, uint32 second, uint32 third)
        private
        returns (AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores)
    {
        return _withScoreProof(
            address(manager),
            AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission({
                realSisterScore: createExternalEuint32(first, evaluator),
                perturbationP25Score: createExternalEuint32(second, evaluator),
                stressP25Score: createExternalEuint32(third, evaluator),
                inputProof: ""
            })
        );
    }

    function _beginEvaluation(bytes32 competitionId) private {
        AlphaEngineCompetitionStrategyManager.CompetitionRecord memory competition =
            manager.getCompetition(competitionId);
        vm.warp(competition.submissionDeadline);
        vm.expectEmit(true, true, false, true);
        emit CompetitionEvaluationStarted(competitionId, address(this));
        manager.beginEvaluation(competitionId);
    }

    function _evaluate(bytes32 submissionId, uint16 rank, uint32 score) private {
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores =
            _scores(score, score + 1, score + 2);
        vm.prank(evaluator);
        manager.recordEvaluation(submissionId, scores, rank, EVIDENCE_HASH);
    }

    function _expectInitializeRevert(
        AlphaEngineCompetitionStrategyManager.InitializationParams memory params,
        bytes memory revertData
    ) private {
        AlphaEngineCompetitionStrategyManager freshImplementation =
            new AlphaEngineCompetitionStrategyManager();
        vm.expectRevert(revertData);
        new TransparentUpgradeableProxy(
            address(freshImplementation),
            admin,
            abi.encodeCall(AlphaEngineCompetitionStrategyManager.initialize, (params))
        );
    }
}
