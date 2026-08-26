// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {Utils} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";
import {AlphaEngineStrategyHashLib} from "src/libraries/AlphaEngineStrategyHashLib.sol";
import {AlphaEngineCompetitionStrategyManager} from
    "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {AlphaEngineTraderQualificationRegistry} from
    "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
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
        InEuint128 memory market = createInEuint128(7, trader);
        InEuint128[] memory components = _components(trader, 100, 200);
        bytes32 expectedSubmissionId = AlphaEngineStrategyHashLib.hashCompetitionSubmissionId(
            block.chainid, address(manager), competitionId, trader, 0
        );

        vm.prank(trader);
        bytes32 submissionId =
            manager.submitCompetitionStrategy(competitionId, market, TIMEFRAME_KEY, components);

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
        assertEq(identity.marketIdHandle, bytes32(market.ctHash));
        assertEq(state.componentCount, 2);
        assertEq(handles[0], bytes32(components[0].ctHash));
        assertEq(handles[1], bytes32(components[1].ctHash));

        bytes32 expectedPayloadHash = AlphaEngineStrategyHashLib.hashCompetitionPayload(
            AlphaEngineStrategyHashLib.CompetitionPayloadV1({
                chainId: block.chainid,
                manager: address(manager),
                submissionId: submissionId,
                competitionId: competitionId,
                trader: trader,
                traderNonce: 0,
                marketIdHandle: bytes32(market.ctHash),
                timeframeKey: TIMEFRAME_KEY,
                evaluationDeadline: manager.getCompetition(competitionId).evaluationDeadline,
                componentsHash: AlphaEngineStrategyHashLib.hashComponents(handles)
            })
        );
        assertEq(identity.payloadHash, expectedPayloadHash);

        assertTrue(taskManager.isAllowed(market.ctHash, address(manager)));
        assertTrue(taskManager.isAllowed(market.ctHash, fheOperator));
        assertTrue(taskManager.isAllowed(components[0].ctHash, address(manager)));
        assertTrue(taskManager.isAllowed(components[0].ctHash, fheOperator));
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

    function test_duplicateActiveSubmissionAndInvalidSubmissionInputsRevert() public {
        bytes32 competitionId = _createCompetition(1);
        bytes32 submissionId = _submit(competitionId, trader, 1, 10);
        InEuint128 memory duplicateMarket = createInEuint128(2, trader);
        InEuint128[] memory duplicateComponents = _components(trader, 20, 30);

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.ActiveSubmissionAlreadyExists.selector,
                competitionId,
                trader,
                submissionId
            )
        );
        manager.submitCompetitionStrategy(
            competitionId, duplicateMarket, TIMEFRAME_KEY, duplicateComponents
        );

        InEuint128 memory secondMarket = createInEuint128(2, secondTrader);
        InEuint128[] memory secondComponents = _components(secondTrader, 20, 30);
        vm.prank(secondTrader);
        vm.expectRevert(AlphaEngineCompetitionStrategyManager.ZeroTimeframeKey.selector);
        manager.submitCompetitionStrategy(competitionId, secondMarket, bytes32(0), secondComponents);

        InEuint128[] memory noComponents = new InEuint128[](0);
        InEuint128 memory thirdMarket = createInEuint128(3, secondTrader);
        vm.prank(secondTrader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidComponentCount.selector, 0
            )
        );
        manager.submitCompetitionStrategy(competitionId, thirdMarket, TIMEFRAME_KEY, noComponents);
    }

    function test_zeroCanonicalHandleFailsLoudly() public {
        bytes32 competitionId = _createCompetition(1);
        bytes memory signature = abi.encode(trader, uint128(7), uint256(0));
        taskManager.registerInput(0, trader, 0, Utils.EUINT128_TFHE, 7, signature);
        InEuint128 memory zeroHandleInput = InEuint128({
            ctHash: 0,
            securityZone: 0,
            utype: Utils.EUINT128_TFHE,
            signature: signature
        });
        InEuint128[] memory components = _components(trader, 1, 2);

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.ZeroEncryptedHandle.selector,
                bytes32("marketId"),
                0
            )
        );
        manager.submitCompetitionStrategy(competitionId, zeroHandleInput, TIMEFRAME_KEY, components);
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
            bytes32(scores.realSisterScore.ctHash),
            bytes32(scores.perturbationP25Score.ctHash),
            bytes32(scores.stressP25Score.ctHash),
            EVIDENCE_HASH
        );
        vm.prank(evaluator);
        manager.recordEvaluation(submissionId, scores, 1, EVIDENCE_HASH);

        AlphaEngineCompetitionStrategyManager.EvaluationRecord memory evaluation =
            manager.getEvaluation(submissionId);
        assertEq(evaluation.realSisterScoreHandle, bytes32(scores.realSisterScore.ctHash));
        assertEq(evaluation.evidenceHash, EVIDENCE_HASH);
        assertEq(manager.submissionByRank(competitionId, 1), submissionId);
        assertTrue(taskManager.isAllowed(scores.realSisterScore.ctHash, address(manager)));
        assertTrue(taskManager.isAllowed(scores.realSisterScore.ctHash, trader));
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
            bytes32(encryptedScores.realSisterScore.ctHash),
            bytes32(encryptedScores.perturbationP25Score.ctHash),
            bytes32(encryptedScores.stressP25Score.ctHash)
        );
        vm.prank(scoreRevealer);
        (uint16 nextRank, uint16 requestedCount) =
            manager.requestCompetitionScoreReveal(competitionId, 1, 32);

        assertEq(nextRank, 2);
        assertEq(requestedCount, 1);
        assertEq(taskManager.decryptRequestCount(encryptedScores.realSisterScore.ctHash), 1);
        assertEq(taskManager.decryptRequestCount(encryptedScores.perturbationP25Score.ctHash), 1);
        assertEq(taskManager.decryptRequestCount(encryptedScores.stressP25Score.ctHash), 1);
        assertEq(
            taskManager.lastDecryptRequestor(encryptedScores.realSisterScore.ctHash),
            address(manager)
        );

        AlphaEngineCompetitionStrategyManager.PublicEvaluationScores memory pendingScores =
            manager.getPublicEvaluationScores(submissionId);
        assertFalse(pendingScores.realSisterScoreReady);
        assertFalse(pendingScores.perturbationP25ScoreReady);
        assertFalse(pendingScores.stressP25ScoreReady);

        taskManager.publishDecryptResult(encryptedScores.realSisterScore.ctHash, 115, "");
        AlphaEngineCompetitionStrategyManager.PublicEvaluationScores memory partialScores =
            manager.getPublicEvaluationScores(submissionId);
        assertEq(partialScores.realSisterScore, 115);
        assertTrue(partialScores.realSisterScoreReady);
        assertFalse(partialScores.perturbationP25ScoreReady);
        assertFalse(partialScores.stressP25ScoreReady);

        uint256[] memory handles = new uint256[](2);
        handles[0] = encryptedScores.perturbationP25Score.ctHash;
        handles[1] = encryptedScores.stressP25Score.ctHash;
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
                AlphaEngineCompetitionStrategyManager.InvalidScoreRevealBatchSize.selector, 0, 32
            )
        );
        manager.requestCompetitionScoreReveal(competitionId, 1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidScoreRevealBatchSize.selector, 33, 32
            )
        );
        manager.requestCompetitionScoreReveal(competitionId, 1, 33);
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
        assertEq(taskManager.decryptRequestCount(firstRankScores.realSisterScore.ctHash), 1);
        assertEq(taskManager.decryptRequestCount(secondRankScores.realSisterScore.ctHash), 0);

        vm.prank(scoreRevealer);
        (nextRank, requestedCount) =
            manager.requestCompetitionScoreReveal(competitionId, nextRank, 32);
        assertEq(nextRank, 3);
        assertEq(requestedCount, 1);
        assertEq(taskManager.decryptRequestCount(secondRankScores.realSisterScore.ctHash), 1);
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

    function test_operatorRotationRequiresPausedGovernanceAndOnlyAffectsFutureSubmissions()
        public
    {
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

    function _createCompetition(uint16 qualificationSlots)
        private
        returns (bytes32 competitionId)
    {
        vm.prank(creator);
        return manager.createCompetition(_config(qualificationSlots));
    }

    function _submit(bytes32 competitionId, address account, uint128 market, uint128 component)
        private
        returns (bytes32 submissionId)
    {
        InEuint128 memory encryptedMarket = createInEuint128(market, account);
        InEuint128[] memory encryptedComponents = _components(account, component, component ^ 1);
        vm.prank(account);
        return manager.submitCompetitionStrategy(
            competitionId, encryptedMarket, TIMEFRAME_KEY, encryptedComponents
        );
    }

    function _components(address account, uint128 first, uint128 second)
        private
        returns (InEuint128[] memory components)
    {
        components = new InEuint128[](2);
        components[0] = createInEuint128(first, account);
        components[1] = createInEuint128(second, account);
    }

    function _scores(uint32 first, uint32 second, uint32 third)
        private
        returns (AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores)
    {
        return AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission({
            realSisterScore: createInEuint32(first, evaluator),
            perturbationP25Score: createInEuint32(second, evaluator),
            stressP25Score: createInEuint32(third, evaluator)
        });
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
