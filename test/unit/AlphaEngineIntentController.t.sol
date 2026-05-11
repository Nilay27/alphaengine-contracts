// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {InEuint32, InEuint64, InEuint128, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {FHERC20WrapperClaimHelper} from
    "fhenix-confidential-contracts/FHERC20/utils/FHERC20WrapperClaimHelper.sol";
import {AlphaEngineV4SwapExecutor} from "src/executors/AlphaEngineV4SwapExecutor.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {AlphaEngineIntentControllerTestBase} from
    "test/mocks/AlphaEngineIntentControllerTestBase.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AlphaEngineIntentControllerUnitTest is AlphaEngineIntentControllerTestBase {
    uint160 private constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    struct SwapFixture {
        AlphaEngineConfidentialVault vault;
        MockERC20 underlying;
        address wrapper;
    }

    struct SwapExecutionFixture {
        AlphaEngineConfidentialVault vault;
        MockERC20 inputUnderlying;
        address inputWrapper;
        MockERC20 outputUnderlying;
        address outputWrapper;
        PoolManager poolManager;
        PoolModifyLiquidityTest liquidityRouter;
        AlphaEngineV4SwapExecutor executor;
        PoolKey poolKey;
        bool zeroForOne;
    }

    event SwapExecutorUpdated(address indexed previousExecutor, address indexed newExecutor);
    event SwapIntentExecuted(
        bytes32 indexed intentId,
        address indexed operator,
        address indexed outputWrapper,
        bytes32 routeKey,
        uint64 decryptedInputAmount,
        uint256 outputUnderlyingAmount,
        bytes32 shieldedOutputHandle
    );
    event SwapIntentRefunded(
        bytes32 indexed intentId,
        address indexed actor,
        address indexed inputWrapper,
        uint64 decryptedInputAmount,
        bytes32 refundedShieldedHandle
    );
    event StrategyEvaluationScoresSubmitted(
        bytes32 indexed intentId,
        address indexed submitter,
        bytes32 realSisterScoreHandle,
        bytes32 perturbationP25ScoreHandle,
        bytes32 stressP25ScoreHandle
    );

    function test_constructorDisablesImplementationInitializer() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, listenerOperator);
    }

    function test_initializeSetsOwnerOperatorAndProxyAdmin() public view {
        assertEq(controller.owner(), owner);
        assertEq(controller.listenerOperator(), listenerOperator);
        assertTrue(_proxyAdmin() != address(0));
        assertEq(ProxyAdmin(_proxyAdmin()).owner(), owner);
    }

    function test_initializeRejectsZeroOwner() public {
        AlphaEngineIntentController newImplementation = new AlphaEngineIntentController();
        bytes memory initData =
            abi.encodeCall(AlphaEngineIntentController.initialize, (address(0), listenerOperator));

        vm.expectRevert(AlphaEngineIntentController.ZeroOwner.selector);
        new TransparentUpgradeableProxy(address(newImplementation), owner, initData);
    }

    function test_initializeRejectsZeroListenerOperator() public {
        AlphaEngineIntentController newImplementation = new AlphaEngineIntentController();
        bytes memory initData =
            abi.encodeCall(AlphaEngineIntentController.initialize, (owner, address(0)));

        vm.expectRevert(AlphaEngineIntentController.ZeroListenerOperator.selector);
        new TransparentUpgradeableProxy(address(newImplementation), owner, initData);
    }

    function test_reinitializeReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        controller.initialize(owner, listenerOperator);
    }

    function test_submitStrategyEvaluationScoresStoresEncryptedScoresAndAllowsSubmitter() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        AlphaEngineIntentController.EvaluationScoreSubmission memory scoreSubmission =
            _encryptedScoreSubmission(12_523, 11_523, 10_589);

        vm.expectEmit(true, true, false, true);
        emit StrategyEvaluationScoresSubmitted(
            intentId,
            submitter,
            bytes32(scoreSubmission.realSisterScore.ctHash),
            bytes32(scoreSubmission.perturbationP25Score.ctHash),
            bytes32(scoreSubmission.stressP25Score.ctHash)
        );

        vm.prank(listenerOperator);
        controller.submitStrategyEvaluationScores(intentId, scoreSubmission);

        AlphaEngineIntentController.EvaluationScoreRecord memory evaluationScoreRecord =
            controller.getEvaluationScores(intentId);
        assertEq(
            evaluationScoreRecord.realSisterScoreHandle,
            bytes32(scoreSubmission.realSisterScore.ctHash)
        );
        assertEq(
            evaluationScoreRecord.perturbationP25ScoreHandle,
            bytes32(scoreSubmission.perturbationP25Score.ctHash)
        );
        assertEq(
            evaluationScoreRecord.stressP25ScoreHandle,
            bytes32(scoreSubmission.stressP25Score.ctHash)
        );

        assertTrue(
            taskManager.isAllowed(
                uint256(evaluationScoreRecord.realSisterScoreHandle), address(controller)
            )
        );
        assertTrue(
            taskManager.isAllowed(
                uint256(evaluationScoreRecord.perturbationP25ScoreHandle), address(controller)
            )
        );
        assertTrue(
            taskManager.isAllowed(
                uint256(evaluationScoreRecord.stressP25ScoreHandle), address(controller)
            )
        );

        assertTrue(
            taskManager.isAllowed(uint256(evaluationScoreRecord.realSisterScoreHandle), submitter)
        );
        assertTrue(
            taskManager.isAllowed(
                uint256(evaluationScoreRecord.perturbationP25ScoreHandle), submitter
            )
        );
        assertTrue(
            taskManager.isAllowed(uint256(evaluationScoreRecord.stressP25ScoreHandle), submitter)
        );

        assertEq(mockStorage(uint256(evaluationScoreRecord.realSisterScoreHandle)), 12_523);
        assertEq(mockStorage(uint256(evaluationScoreRecord.perturbationP25ScoreHandle)), 11_523);
        assertEq(mockStorage(uint256(evaluationScoreRecord.stressP25ScoreHandle)), 10_589);

        assertFalse(taskManager.isAllowed(uint256(evaluationScoreRecord.realSisterScoreHandle), otherSubmitter));
        assertFalse(taskManager.isAllowed(uint256(evaluationScoreRecord.perturbationP25ScoreHandle), otherSubmitter));
        assertFalse(taskManager.isAllowed(uint256(evaluationScoreRecord.stressP25ScoreHandle), otherSubmitter));
    }

    function test_submitStrategyEvaluationScoresRejectsInvalidEncryptedScoreHandles() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        AlphaEngineIntentController.EvaluationScoreSubmission memory scoreSubmission =
            _encryptedScoreSubmission(1000, 1000, 1000);

        scoreSubmission.realSisterScore = InEuint32({
            // invalid because this encrypted input metadata no longer matches the registered source
            ctHash: scoreSubmission.realSisterScore.ctHash,
            securityZone: scoreSubmission.realSisterScore.securityZone + 1,
            utype: scoreSubmission.realSisterScore.utype,
            signature: scoreSubmission.realSisterScore.signature
        });

        vm.prank(listenerOperator);
        vm.expectRevert();
        controller.submitStrategyEvaluationScores(intentId, scoreSubmission);
    }

    function test_submitStrategyEvaluationScoresRejectsUnauthorizedCaller() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        AlphaEngineIntentController.EvaluationScoreSubmission memory scoreSubmission =
            _encryptedScoreSubmission(1000, 1000, 1000);

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.UnauthorizedListenerOperator.selector, outsider
            )
        );
        controller.submitStrategyEvaluationScores(
            intentId,
            scoreSubmission
        );
    }

    function test_submitStrategyEvaluationScoresRejectsDuplicateSubmissions() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        AlphaEngineIntentController.EvaluationScoreSubmission memory scoreSubmission =
            _encryptedScoreSubmission(10_000, 10_000, 10_000);

        vm.prank(listenerOperator);
        controller.submitStrategyEvaluationScores(
            intentId,
            scoreSubmission
        );

        vm.prank(listenerOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.EvaluationScoresAlreadySubmitted.selector, intentId
            )
        );
        controller.submitStrategyEvaluationScores(
            intentId,
            scoreSubmission
        );
    }

    function test_submitStrategyEvaluationScoresRejectsNonActiveIntent() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        AlphaEngineIntentController.EvaluationScoreSubmission memory scoreSubmission =
            _encryptedScoreSubmission(10_000, 10_000, 10_000);

        vm.prank(submitter);
        controller.cancelStrategyIntent(intentId);

        vm.prank(listenerOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.StrategyIntentNotActive.selector,
                intentId,
                AlphaEngineIntentController.IntentStatus.Cancelled
            )
        );
        controller.submitStrategyEvaluationScores(
            intentId,
            scoreSubmission
        );
    }

    function _encryptedScoreSubmission(uint32 realSister, uint32 perturbationP25, uint32 stress)
        internal
        returns (AlphaEngineIntentController.EvaluationScoreSubmission memory submission)
    {
        submission = AlphaEngineIntentController.EvaluationScoreSubmission({
            realSisterScore: createInEuint32(realSister, listenerOperator),
            perturbationP25Score: createInEuint32(perturbationP25, listenerOperator),
            stressP25Score: createInEuint32(stress, listenerOperator)
        });
    }

    function test_submitStoresMetadataHandlesPermissionsAndEvent() public {
        uint128[] memory values = new uint128[](2);
        values[0] = 125;
        values[1] = 250;
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory inputs = _inputs(values, submitter);
        uint40 deadline = _deadlineAhead(1 hours);

        vm.recordLogs();
        bytes32 intentId =
            _submit(submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, deadline);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        AlphaEngineIntentController.IntentRecord memory intentRecord =
            controller.getIntent(intentId);
        bytes32[] memory handles = controller.getIntentComponentHandles(intentId);
        bytes32 expectedPayloadHash = keccak256(
            abi.encode(intentRecord.marketIdHandle, DEFAULT_TIMEFRAME_KEY, deadline, handles)
        );

        assertEq(intentRecord.submitter, submitter);
        assertEq(mockStorage(uint256(intentRecord.marketIdHandle)), DEFAULT_MARKET_ID);
        assertEq(intentRecord.timeframeKey, DEFAULT_TIMEFRAME_KEY);
        assertEq(intentRecord.deadline, deadline);
        assertEq(intentRecord.createdAt, uint40(block.timestamp));
        assertEq(intentRecord.submitterNonce, 0);
        assertEq(intentRecord.componentCount, 2);
        assertEq(uint8(intentRecord.status), uint8(AlphaEngineIntentController.IntentStatus.Active));
        assertEq(intentRecord.payloadHash, expectedPayloadHash);
        assertEq(handles.length, 2);
        assertEq(controller.submitterNonces(submitter), 1);
        assertEq(
            intentId,
            keccak256(abi.encode(address(controller), block.chainid, submitter, uint64(0)))
        );
        assertTrue(taskManager.isAllowed(uint256(intentRecord.marketIdHandle), address(controller)));
        assertTrue(taskManager.isAllowed(uint256(intentRecord.marketIdHandle), listenerOperator));

        for (uint256 index = 0; index < handles.length; ++index) {
            assertTrue(taskManager.isAllowed(uint256(handles[index]), address(controller)));
            assertTrue(taskManager.isAllowed(uint256(handles[index]), listenerOperator));
            assertEq(mockStorage(uint256(handles[index])), values[index]);
        }

        _expectSubmittedLog(
            logs,
            intentId,
            submitter,
            intentRecord.marketIdHandle,
            DEFAULT_TIMEFRAME_KEY,
            handles,
            deadline,
            expectedPayloadHash,
            0
        );
    }

    function test_submitRejectsZeroTimeframeKey() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory inputs = _singleInput(100, submitter);

        vm.prank(submitter);
        vm.expectRevert(AlphaEngineIntentController.ZeroTimeframeKey.selector);
        controller.submitStrategyIntent(marketIdInput, bytes32(0), inputs, _deadlineAhead(1));
    }

    function test_submitRejectsPastDeadline() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory inputs = _singleInput(100, submitter);
        uint40 deadline = uint40(block.timestamp);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.DeadlineNotInFuture.selector,
                deadline,
                uint40(block.timestamp)
            )
        );
        controller.submitStrategyIntent(marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, deadline);
    }

    function test_submitRejectsZeroComponentCount() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory inputs = new InEuint128[](0);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineIntentController.InvalidComponentCount.selector, 0)
        );
        controller.submitStrategyIntent(
            marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1)
        );
    }

    function test_submitRejectsComponentCountAboveMaximum() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory inputs = new InEuint128[](17);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineIntentController.InvalidComponentCount.selector, 17)
        );
        controller.submitStrategyIntent(
            marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1)
        );
    }

    function test_pauseBlocksSubmitAndUnpauseRestoresSubmit() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Paused(owner);
        controller.pause();

        assertTrue(controller.paused());

        InEuint128[] memory inputs = _singleInput(100, submitter);
        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        controller.submitStrategyIntent(
            marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1)
        );

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Unpaused(owner);
        controller.unpause();

        assertFalse(controller.paused());

        bytes32 intentId =
            _submit(submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(2));
        assertEq(controller.getIntent(intentId).submitter, submitter);
    }

    function test_setListenerOperatorUpdatesStateAndEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ListenerOperatorUpdated(listenerOperator, updatedListenerOperator);
        controller.setListenerOperator(updatedListenerOperator);

        assertEq(controller.listenerOperator(), updatedListenerOperator);
    }

    function test_setListenerOperatorRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AlphaEngineIntentController.ZeroListenerOperator.selector);
        controller.setListenerOperator(address(0));
    }

    function test_setListenerOperatorRejectsUnauthorizedCaller() public {
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider)
        );
        controller.setListenerOperator(updatedListenerOperator);
    }

    function test_operatorRotationOnlyAffectsFutureSubmissions() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory firstInputs = _singleInput(111, submitter);
        bytes32 firstIntentId =
            _submit(submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, firstInputs, _deadlineAhead(1));
        bytes32[] memory firstHandles = controller.getIntentComponentHandles(firstIntentId);

        vm.prank(owner);
        controller.setListenerOperator(updatedListenerOperator);

        InEuint128[] memory secondInputs = _singleInput(222, submitter);
        bytes32 secondIntentId = _submit(
            submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, secondInputs, _deadlineAhead(2)
        );
        bytes32[] memory secondHandles = controller.getIntentComponentHandles(secondIntentId);

        assertTrue(taskManager.isAllowed(uint256(firstHandles[0]), listenerOperator));
        assertFalse(taskManager.isAllowed(uint256(firstHandles[0]), updatedListenerOperator));
        assertFalse(taskManager.isAllowed(uint256(secondHandles[0]), listenerOperator));
        assertTrue(taskManager.isAllowed(uint256(secondHandles[0]), updatedListenerOperator));
    }

    function test_setConfidentialVaultUpdatesStateAndEmitsEvent() public {
        AlphaEngineConfidentialVault newVault = _deployControllerVault();

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ConfidentialVaultUpdated(address(0), address(newVault));
        controller.setConfidentialVault(address(newVault));

        assertEq(controller.confidentialVault(), address(newVault));
    }

    function test_setConfidentialVaultRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AlphaEngineIntentController.ZeroConfidentialVault.selector);
        controller.setConfidentialVault(address(0));
    }

    function test_setConfidentialVaultRejectsNonContract() public {
        address invalidVault = makeAddr("invalidVault");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.InvalidConfidentialVault.selector, invalidVault
            )
        );
        controller.setConfidentialVault(invalidVault);
    }

    function test_setConfidentialVaultRejectsContractWithoutVaultSurface() public {
        MockERC20 invalidVault = new MockERC20("Invalid Vault", "BAD", 6);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.InvalidConfidentialVault.selector, address(invalidVault)
            )
        );
        controller.setConfidentialVault(address(invalidVault));
    }

    function test_setConfidentialVaultRejectsVaultForDifferentController() public {
        AlphaEngineConfidentialVault invalidVault = _deployVault(makeAddr("otherController"));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.InvalidConfidentialVault.selector, address(invalidVault)
            )
        );
        controller.setConfidentialVault(address(invalidVault));
    }

    function test_setConfidentialVaultRejectsUnauthorizedCaller() public {
        AlphaEngineConfidentialVault newVault = _deployControllerVault();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider)
        );
        controller.setConfidentialVault(address(newVault));
    }

    function test_setSwapExecutorUpdatesStateAndEmitsEvent() public {
        AlphaEngineV4SwapExecutor executor = new AlphaEngineV4SwapExecutor(
            IPoolManager(address(new PoolManager(owner))), owner, owner
        );

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit SwapExecutorUpdated(address(0), address(executor));
        controller.setSwapExecutor(address(executor));

        assertEq(controller.swapExecutor(), address(executor));
    }

    function test_setSwapExecutorRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AlphaEngineIntentController.ZeroSwapExecutor.selector);
        controller.setSwapExecutor(address(0));
    }

    function test_setSwapExecutorRejectsNonContract() public {
        address invalidExecutor = makeAddr("invalidExecutor");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.InvalidSwapExecutor.selector, invalidExecutor
            )
        );
        controller.setSwapExecutor(invalidExecutor);
    }

    function test_setSwapExecutorRejectsUnauthorizedCaller() public {
        AlphaEngineV4SwapExecutor executor = new AlphaEngineV4SwapExecutor(
            IPoolManager(address(new PoolManager(owner))), owner, owner
        );

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider)
        );
        controller.setSwapExecutor(address(executor));
    }

    function test_submitSwapIntentLocksVaultAndAutoRequestsUnshield() public {
        (SwapFixture memory fixture, InEuint64 memory encryptedInputAmount) =
            _prepareSwapFixture(100e6, 40e6);
        uint40 deadline = _deadlineAhead(1 hours);

        vm.recordLogs();
        bytes32 intentId = _submitSwap(
            submitter, fixture.wrapper, DEFAULT_SWAP_ROUTE_KEY, encryptedInputAmount, deadline
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        AlphaEngineIntentController.SwapIntentRecord memory swapRecord =
            controller.getSwapIntent(intentId);
        AlphaEngineConfidentialVault.SwapIntentLock memory vaultLock =
            fixture.vault.getSwapIntentLock(intentId);
        bytes32 expectedPayloadHash = keccak256(
            abi.encode(
                address(fixture.vault),
                fixture.wrapper,
                DEFAULT_SWAP_ROUTE_KEY,
                deadline,
                swapRecord.lockedAmountHandle,
                swapRecord.unshieldRequestHandle
            )
        );

        assertEq(swapRecord.submitter, submitter);
        assertEq(swapRecord.confidentialVault, address(fixture.vault));
        assertEq(swapRecord.inputWrapper, fixture.wrapper);
        assertEq(swapRecord.routeKey, DEFAULT_SWAP_ROUTE_KEY);
        assertTrue(swapRecord.lockedAmountHandle != bytes32(0));
        assertTrue(swapRecord.unshieldRequestHandle != bytes32(0));
        assertEq(swapRecord.deadline, deadline);
        assertEq(swapRecord.createdAt, uint40(block.timestamp));
        assertEq(swapRecord.submitterNonce, 0);
        assertEq(uint8(swapRecord.status), uint8(AlphaEngineIntentController.IntentStatus.Active));
        assertEq(swapRecord.payloadHash, expectedPayloadHash);
        assertEq(controller.submitterNonces(submitter), 1);
        assertEq(
            intentId,
            keccak256(abi.encode(address(controller), block.chainid, submitter, uint64(0)))
        );
        assertTrue(taskManager.isAllowed(encryptedInputAmount.ctHash, address(controller)));
        assertTrue(taskManager.isAllowed(encryptedInputAmount.ctHash, address(fixture.vault)));

        assertEq(vaultLock.account, submitter);
        assertEq(vaultLock.wrapper, fixture.wrapper);
        assertEq(euint64.unwrap(vaultLock.lockedAmount), swapRecord.lockedAmountHandle);
        assertEq(euint64.unwrap(vaultLock.unshieldRequestHandle), swapRecord.unshieldRequestHandle);
        assertEq(
            uint8(vaultLock.status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested)
        );
        assertEq(mockStorage(uint256(swapRecord.lockedAmountHandle)), 40e6);
        assertEq(mockStorage(uint256(swapRecord.unshieldRequestHandle)), 40e6);

        euint64 submitterBalance =
            AlphaEngineFHERC20ERC20Wrapper(fixture.wrapper).confidentialBalanceOf(submitter);
        euint64 vaultBalance = AlphaEngineFHERC20ERC20Wrapper(fixture.wrapper).confidentialBalanceOf(
            address(fixture.vault)
        );
        assertEq(mockStorage(uint256(euint64.unwrap(submitterBalance))), 60e6);
        assertEq(mockStorage(uint256(euint64.unwrap(vaultBalance))), 0);

        FHERC20WrapperClaimHelper.Claim memory claim = AlphaEngineFHERC20ERC20Wrapper(
            fixture.wrapper
        ).getClaim(swapRecord.unshieldRequestHandle);
        assertEq(claim.to, address(fixture.vault));
        assertEq(claim.ctHash, swapRecord.unshieldRequestHandle);
        assertEq(claim.requestedAmount, 0);
        assertFalse(claim.claimed);

        _expectSwapSubmittedLog(
            logs,
            intentId,
            submitter,
            fixture.wrapper,
            address(fixture.vault),
            DEFAULT_SWAP_ROUTE_KEY,
            swapRecord.lockedAmountHandle,
            swapRecord.unshieldRequestHandle,
            deadline,
            expectedPayloadHash,
            0
        );
    }

    function test_submitSwapIntentRejectsUnsetVault() public {
        InEuint64 memory encryptedInputAmount = createInEuint64(1, submitter);

        vm.prank(submitter);
        vm.expectRevert(AlphaEngineIntentController.ZeroConfidentialVault.selector);
        controller.submitSwapIntent(
            makeAddr("wrapper"), DEFAULT_SWAP_ROUTE_KEY, encryptedInputAmount, _deadlineAhead(1)
        );
    }

    function test_submitSwapIntentRejectsZeroInputWrapper() public {
        _configureControllerVault();
        InEuint64 memory encryptedInputAmount = createInEuint64(1, submitter);

        vm.prank(submitter);
        vm.expectRevert(AlphaEngineIntentController.ZeroInputWrapper.selector);
        controller.submitSwapIntent(
            address(0), DEFAULT_SWAP_ROUTE_KEY, encryptedInputAmount, _deadlineAhead(1)
        );
    }

    function test_submitSwapIntentRejectsZeroRouteKey() public {
        _configureControllerVault();
        InEuint64 memory encryptedInputAmount = createInEuint64(1, submitter);

        vm.prank(submitter);
        vm.expectRevert(AlphaEngineIntentController.ZeroSwapRouteKey.selector);
        controller.submitSwapIntent(
            makeAddr("wrapper"), bytes32(0), encryptedInputAmount, _deadlineAhead(1)
        );
    }

    function test_submitSwapIntentRejectsPastDeadline() public {
        _configureControllerVault();
        InEuint64 memory encryptedInputAmount = createInEuint64(1, submitter);
        uint40 deadline = uint40(block.timestamp);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.DeadlineNotInFuture.selector,
                deadline,
                uint40(block.timestamp)
            )
        );
        controller.submitSwapIntent(
            makeAddr("wrapper"), DEFAULT_SWAP_ROUTE_KEY, encryptedInputAmount, deadline
        );
    }

    function test_pauseBlocksSwapSubmitAndUnpauseRestoresSubmit() public {
        (SwapFixture memory fixture, InEuint64 memory encryptedInputAmount) =
            _prepareSwapFixture(100e6, 40e6);

        vm.prank(owner);
        controller.pause();

        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        controller.submitSwapIntent(
            fixture.wrapper, DEFAULT_SWAP_ROUTE_KEY, encryptedInputAmount, _deadlineAhead(1)
        );

        vm.prank(owner);
        controller.unpause();

        bytes32 intentId = _submitSwap(
            submitter,
            fixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            encryptedInputAmount,
            _deadlineAhead(2)
        );
        assertEq(controller.getSwapIntent(intentId).submitter, submitter);
    }

    function test_confidentialVaultRotationOnlyAffectsFutureSwapSubmissions() public {
        (SwapFixture memory firstFixture, InEuint64 memory firstInputAmount) =
            _prepareSwapFixture(100e6, 40e6);

        bytes32 firstIntentId = _submitSwap(
            submitter,
            firstFixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            firstInputAmount,
            _deadlineAhead(1)
        );

        (SwapFixture memory secondFixture, InEuint64 memory secondInputAmount) =
            _prepareSwapFixtureForSubmitter(otherSubmitter, 200e6, 60e6);

        bytes32 secondIntentId = _submitSwap(
            otherSubmitter,
            secondFixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            secondInputAmount,
            _deadlineAhead(2)
        );

        assertEq(
            controller.getSwapIntent(firstIntentId).confidentialVault, address(firstFixture.vault)
        );
        assertEq(
            controller.getSwapIntent(secondIntentId).confidentialVault, address(secondFixture.vault)
        );
        assertEq(controller.submitterNonces(submitter), 1);
        assertEq(controller.submitterNonces(otherSubmitter), 1);

        assertEq(
            uint8(firstFixture.vault.getSwapIntentLock(firstIntentId).status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested)
        );
        assertEq(
            uint8(secondFixture.vault.getSwapIntentLock(secondIntentId).status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested)
        );
    }

    function test_executeSwapIntentClaimsSwapsAndShieldsOutput() public {
        (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        ) = _prepareExecutableSwapIntent(100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6);

        vm.recordLogs();
        (uint256 outputUnderlyingAmount, bytes32 shieldedOutputHandle) =
        _executeSwapIntentWithDefaultRoute(
            listenerOperator, fixture, intentId, fixture.outputWrapper, decryptedInputAmount, 1
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        AlphaEngineIntentController.SwapIntentRecord memory swapRecord =
            controller.getSwapIntent(intentId);
        AlphaEngineConfidentialVault.SwapIntentLock memory vaultLock =
            fixture.vault.getSwapIntentLock(intentId);
        FHERC20WrapperClaimHelper.Claim memory inputClaim =
            AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper).getClaim(unshieldRequestHandle);

        assertEq(uint8(swapRecord.status), uint8(AlphaEngineIntentController.IntentStatus.Executed));
        assertEq(
            uint8(vaultLock.status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.Consumed)
        );
        assertTrue(inputClaim.claimed);
        assertEq(fixture.inputUnderlying.balanceOf(address(fixture.vault)), 0);
        assertEq(mockStorage(uint256(shieldedOutputHandle)), outputUnderlyingAmount);

        euint64 outputBalance =
            AlphaEngineFHERC20ERC20Wrapper(fixture.outputWrapper).confidentialBalanceOf(submitter);
        assertEq(mockStorage(uint256(euint64.unwrap(outputBalance))), outputUnderlyingAmount);
        assertEq(fixture.outputUnderlying.balanceOf(fixture.outputWrapper), outputUnderlyingAmount);

        _assertSwapExecutionLog(
            logs,
            intentId,
            listenerOperator,
            fixture.outputWrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            decryptedInputAmount,
            outputUnderlyingAmount,
            shieldedOutputHandle
        );
    }

    function test_executeSwapIntentRejectsUnauthorizedCaller() public {
        (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        ) = _prepareExecutableSwapIntent(100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6);
        assertTrue(unshieldRequestHandle != bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.UnauthorizedListenerOperator.selector, outsider
            )
        );
        _executeSwapIntentWithDefaultRoute(
            outsider, fixture, intentId, fixture.outputWrapper, decryptedInputAmount, 1
        );
    }

    function test_executeSwapIntentRejectsUnsetSwapExecutor() public {
        (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        ) = _prepareExecutableSwapIntentWithoutExecutor(
            100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6
        );
        assertTrue(unshieldRequestHandle != bytes32(0));

        vm.expectRevert(AlphaEngineIntentController.ZeroSwapExecutor.selector);
        _executeSwapIntentWithDefaultRoute(
            listenerOperator, fixture, intentId, fixture.outputWrapper, decryptedInputAmount, 1
        );
    }

    function test_executeSwapIntentRejectsUnknownIntent() public {
        PoolManager poolManager = new PoolManager(owner);
        AlphaEngineV4SwapExecutor executor = new AlphaEngineV4SwapExecutor(
            IPoolManager(address(poolManager)), owner, makeAddr("authorizedCaller")
        );

        vm.prank(owner);
        controller.setSwapExecutor(address(executor));

        vm.prank(listenerOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.SwapIntentNotFound.selector, keccak256("unknown-swap")
            )
        );
        controller.executeSwapIntent(
            keccak256("unknown-swap"), makeAddr("outputWrapper"), 1, 1, "", bytes("")
        );
    }

    function test_executeSwapIntentRejectsZeroOutputWrapper() public {
        (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        ) = _prepareExecutableSwapIntent(100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6);
        assertTrue(unshieldRequestHandle != bytes32(0));

        vm.expectRevert(AlphaEngineIntentController.ZeroOutputWrapper.selector);
        _executeSwapIntentWithDefaultRoute(
            listenerOperator, fixture, intentId, address(0), decryptedInputAmount, 1
        );
    }

    function test_executeSwapIntentRejectsExpiredIntent() public {
        (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        ) = _prepareExecutableSwapIntent(100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6);
        assertTrue(unshieldRequestHandle != bytes32(0));
        uint40 deadline = controller.getSwapIntent(intentId).deadline;
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.IntentExpired.selector,
                intentId,
                deadline,
                uint40(block.timestamp)
            )
        );
        _executeSwapIntentWithDefaultRoute(
            listenerOperator, fixture, intentId, fixture.outputWrapper, decryptedInputAmount, 1
        );
    }

    function test_executeSwapIntentRejectsAlreadyExecutedIntent() public {
        (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        ) = _prepareExecutableSwapIntent(100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6);
        assertTrue(unshieldRequestHandle != bytes32(0));

        _executeSwapIntentWithDefaultRoute(
            listenerOperator, fixture, intentId, fixture.outputWrapper, decryptedInputAmount, 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.SwapIntentNotActive.selector,
                intentId,
                AlphaEngineIntentController.IntentStatus.Executed
            )
        );
        _executeSwapIntentWithDefaultRoute(
            listenerOperator, fixture, intentId, fixture.outputWrapper, decryptedInputAmount, 1
        );
    }

    function test_refundSwapIntentAfterExpiryClaimsAndReshieldsInput() public {
        (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        ) = _prepareSwapExecutionFixture(100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6);
        _publishSwapDecryptResult(unshieldRequestHandle, decryptedInputAmount);
        uint40 deadline = controller.getSwapIntent(intentId).deadline;
        vm.warp(deadline);

        vm.recordLogs();
        bytes32 refundedShieldedHandle = _refundSwapIntent(intentId, decryptedInputAmount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        AlphaEngineIntentController.SwapIntentRecord memory swapRecord =
            controller.getSwapIntent(intentId);
        AlphaEngineConfidentialVault.SwapIntentLock memory vaultLock =
            fixture.vault.getSwapIntentLock(intentId);
        FHERC20WrapperClaimHelper.Claim memory inputClaim =
            AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper).getClaim(unshieldRequestHandle);
        euint64 inputBalance =
            AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper).confidentialBalanceOf(submitter);

        assertEq(uint8(swapRecord.status), uint8(AlphaEngineIntentController.IntentStatus.Refunded));
        assertEq(
            uint8(vaultLock.status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.Refunded)
        );
        assertTrue(inputClaim.claimed);
        assertEq(fixture.vault.liveSwapLockCount(), 0);
        assertEq(mockStorage(uint256(refundedShieldedHandle)), decryptedInputAmount);
        assertEq(mockStorage(uint256(euint64.unwrap(inputBalance))), 100e6);
        assertEq(fixture.inputUnderlying.balanceOf(address(fixture.vault)), 0);

        _assertSwapRefundLog(
            logs,
            intentId,
            address(this),
            fixture.inputWrapper,
            decryptedInputAmount,
            refundedShieldedHandle
        );
    }

    function test_refundSwapIntentAllowedWhileControllerPaused() public {
        (, bytes32 intentId, uint64 decryptedInputAmount, bytes32 unshieldRequestHandle) =
            _prepareSwapExecutionFixture(100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6);
        _publishSwapDecryptResult(unshieldRequestHandle, decryptedInputAmount);

        vm.prank(owner);
        controller.pause();

        bytes32 refundedShieldedHandle = _refundSwapIntent(intentId, decryptedInputAmount);

        assertTrue(refundedShieldedHandle != bytes32(0));
        assertEq(
            uint8(controller.getSwapIntent(intentId).status),
            uint8(AlphaEngineIntentController.IntentStatus.Refunded)
        );
    }

    function test_refundSwapIntentAllowedWhileVaultPaused() public {
        (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        ) = _prepareSwapExecutionFixture(100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6);
        _publishSwapDecryptResult(unshieldRequestHandle, decryptedInputAmount);

        vm.prank(owner);
        fixture.vault.pause();

        bytes32 refundedShieldedHandle = _refundSwapIntent(intentId, decryptedInputAmount);

        assertTrue(refundedShieldedHandle != bytes32(0));
        assertEq(
            uint8(controller.getSwapIntent(intentId).status),
            uint8(AlphaEngineIntentController.IntentStatus.Refunded)
        );
    }

    function test_refundSwapIntentRejectsBeforeExpiryWhenLive() public {
        (, bytes32 intentId, uint64 decryptedInputAmount, bytes32 unshieldRequestHandle) =
            _prepareSwapExecutionFixture(100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6);
        _publishSwapDecryptResult(unshieldRequestHandle, decryptedInputAmount);
        uint40 deadline = controller.getSwapIntent(intentId).deadline;

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.SwapIntentRefundUnavailable.selector,
                intentId,
                deadline,
                uint40(block.timestamp)
            )
        );
        _refundSwapIntent(intentId, decryptedInputAmount);
    }

    function test_refundSwapIntentRejectsUnknownIntent() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.SwapIntentNotFound.selector, keccak256("unknown-refund")
            )
        );
        _refundSwapIntent(keccak256("unknown-refund"), 1);
    }

    function test_refundSwapIntentRejectsAlreadyExecutedIntent() public {
        (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        ) = _prepareExecutableSwapIntent(100e6, 40e6, 2_000_000_000e6, 2_000_000_000e6);
        assertTrue(unshieldRequestHandle != bytes32(0));

        _executeSwapIntentWithDefaultRoute(
            listenerOperator, fixture, intentId, fixture.outputWrapper, decryptedInputAmount, 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.SwapIntentNotActive.selector,
                intentId,
                AlphaEngineIntentController.IntentStatus.Executed
            )
        );
        _refundSwapIntent(intentId, decryptedInputAmount);
    }

    function test_cancelAllowsSubmitterAndEmitsEvent() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        vm.prank(submitter);
        vm.expectEmit(true, true, false, false);
        emit StrategyIntentCancelled(intentId, submitter);
        controller.cancelStrategyIntent(intentId);

        assertEq(
            uint8(controller.getIntent(intentId).status),
            uint8(AlphaEngineIntentController.IntentStatus.Cancelled)
        );
    }

    function test_cancelAllowsOwnerWhilePaused() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        vm.prank(owner);
        controller.pause();

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit StrategyIntentCancelled(intentId, owner);
        controller.cancelStrategyIntent(intentId);

        assertEq(
            uint8(controller.getIntent(intentId).status),
            uint8(AlphaEngineIntentController.IntentStatus.Cancelled)
        );
    }

    function test_cancelRejectsUnauthorizedCaller() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.UnauthorizedCancel.selector, outsider, intentId
            )
        );
        controller.cancelStrategyIntent(intentId);
    }

    function test_cancelRejectsUnknownIntent() public {
        bytes32 unknownIntentId = keccak256("unknown-intent");

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.IntentNotFound.selector, unknownIntentId
            )
        );
        controller.cancelStrategyIntent(unknownIntentId);
    }

    function test_cancelRejectsAlreadyCancelledIntent() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        vm.prank(submitter);
        controller.cancelStrategyIntent(intentId);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.IntentAlreadyCancelled.selector, intentId
            )
        );
        controller.cancelStrategyIntent(intentId);
    }

    function test_gettersReturnDefaultsForUnknownIntent() public view {
        bytes32 unknownIntentId = keccak256("unknown-intent");
        AlphaEngineIntentController.IntentRecord memory intentRecord =
            controller.getIntent(unknownIntentId);
        bytes32[] memory componentHandles = controller.getIntentComponentHandles(unknownIntentId);
        AlphaEngineIntentController.SwapIntentRecord memory swapIntentRecord =
            controller.getSwapIntent(unknownIntentId);
        AlphaEngineIntentController.EvaluationScoreRecord memory evaluationScoreRecord =
            controller.getEvaluationScores(unknownIntentId);

        assertEq(intentRecord.submitter, address(0));
        assertEq(intentRecord.marketIdHandle, bytes32(0));
        assertEq(componentHandles.length, 0);
        assertEq(swapIntentRecord.submitter, address(0));
        assertEq(swapIntentRecord.confidentialVault, address(0));
        assertEq(swapIntentRecord.lockedAmountHandle, bytes32(0));
        assertEq(swapIntentRecord.unshieldRequestHandle, bytes32(0));
        assertEq(uint256(evaluationScoreRecord.realSisterScoreHandle), 0);
        assertEq(uint256(evaluationScoreRecord.perturbationP25ScoreHandle), 0);
        assertEq(uint256(evaluationScoreRecord.stressP25ScoreHandle), 0);
        assertTrue(!evaluationScoreRecord.submitted);
    }

    function _submitDefaultSwapIntent()
        private
        returns (SwapFixture memory fixture, bytes32 intentId)
    {
        InEuint64 memory encryptedInputAmount;
        (fixture, encryptedInputAmount) = _prepareSwapFixture(100e6, 40e6);
        intentId = _submitSwap(
            submitter,
            fixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            encryptedInputAmount,
            _deadlineAhead(1 hours)
        );
    }

    function _prepareSwapExecutionFixture(
        uint256 depositAmount,
        uint64 lockAmount,
        uint256 inputLiquidityAmount,
        uint256 outputLiquidityAmount
    )
        private
        returns (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        )
    {
        return _prepareSwapExecutionFixtureInternal(
            depositAmount, lockAmount, inputLiquidityAmount, outputLiquidityAmount, true
        );
    }

    function _prepareExecutableSwapIntent(
        uint256 depositAmount,
        uint64 lockAmount,
        uint256 inputLiquidityAmount,
        uint256 outputLiquidityAmount
    )
        private
        returns (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        )
    {
        (fixture, intentId, decryptedInputAmount, unshieldRequestHandle) =
        _prepareSwapExecutionFixture(
            depositAmount, lockAmount, inputLiquidityAmount, outputLiquidityAmount
        );
        _publishSwapDecryptResult(unshieldRequestHandle, decryptedInputAmount);
    }

    function _prepareSwapExecutionFixtureWithoutExecutor(
        uint256 depositAmount,
        uint64 lockAmount,
        uint256 inputLiquidityAmount,
        uint256 outputLiquidityAmount
    )
        private
        returns (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        )
    {
        return _prepareSwapExecutionFixtureInternal(
            depositAmount, lockAmount, inputLiquidityAmount, outputLiquidityAmount, false
        );
    }

    function _prepareExecutableSwapIntentWithoutExecutor(
        uint256 depositAmount,
        uint64 lockAmount,
        uint256 inputLiquidityAmount,
        uint256 outputLiquidityAmount
    )
        private
        returns (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        )
    {
        (fixture, intentId, decryptedInputAmount, unshieldRequestHandle) =
        _prepareSwapExecutionFixtureWithoutExecutor(
            depositAmount, lockAmount, inputLiquidityAmount, outputLiquidityAmount
        );
        _publishSwapDecryptResult(unshieldRequestHandle, decryptedInputAmount);
    }

    function _prepareSwapExecutionFixtureInternal(
        uint256 depositAmount,
        uint64 lockAmount,
        uint256 inputLiquidityAmount,
        uint256 outputLiquidityAmount,
        bool configureExecutor
    )
        private
        returns (
            SwapExecutionFixture memory fixture,
            bytes32 intentId,
            uint64 decryptedInputAmount,
            bytes32 unshieldRequestHandle
        )
    {
        fixture = _deploySwapExecutionFixture(
            inputLiquidityAmount, outputLiquidityAmount, configureExecutor
        );
        fixture.inputUnderlying.mint(submitter, depositAmount);

        vm.startPrank(submitter);
        fixture.inputUnderlying.approve(address(fixture.vault), depositAmount);
        fixture.vault.depositAndShield(address(fixture.inputUnderlying), depositAmount, submitter);
        AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper).setOperator(
            address(fixture.vault), uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        decryptedInputAmount = lockAmount;
        InEuint64 memory encryptedInputAmount = createInEuint64(lockAmount, submitter);
        intentId = _submitSwap(
            submitter,
            fixture.inputWrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            encryptedInputAmount,
            _deadlineAhead(1 hours)
        );
        unshieldRequestHandle = controller.getSwapIntent(intentId).unshieldRequestHandle;
    }

    function _prepareSwapFixture(uint256 depositAmount, uint64 lockAmount)
        private
        returns (SwapFixture memory fixture, InEuint64 memory encryptedInputAmount)
    {
        return _prepareSwapFixtureForSubmitter(submitter, depositAmount, lockAmount);
    }

    function _prepareSwapFixtureForSubmitter(
        address fixtureSubmitter,
        uint256 depositAmount,
        uint64 lockAmount
    ) private returns (SwapFixture memory fixture, InEuint64 memory encryptedInputAmount) {
        fixture = _deploySwapFixture();

        fixture.underlying.mint(fixtureSubmitter, depositAmount);

        vm.startPrank(fixtureSubmitter);
        fixture.underlying.approve(address(fixture.vault), depositAmount);
        fixture.vault.depositAndShield(address(fixture.underlying), depositAmount, fixtureSubmitter);
        AlphaEngineFHERC20ERC20Wrapper(fixture.wrapper).setOperator(
            address(fixture.vault), uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        encryptedInputAmount = createInEuint64(lockAmount, fixtureSubmitter);
    }

    function _deploySwapFixture() private returns (SwapFixture memory fixture) {
        fixture.underlying = new MockERC20("USD Coin", "USDC", 6);
        fixture.vault = _deployControllerVault();

        vm.startPrank(owner);
        fixture.wrapper =
            fixture.vault.createWrapper(address(fixture.underlying), "Encrypted USDC", "eUSDC", "");
        controller.setConfidentialVault(address(fixture.vault));
        vm.stopPrank();
    }

    function _configureControllerVault() private returns (AlphaEngineConfidentialVault vault) {
        vault = _deployControllerVault();
        vm.prank(owner);
        controller.setConfidentialVault(address(vault));
    }

    function _deploySwapExecutionFixture(
        uint256 inputLiquidityAmount,
        uint256 outputLiquidityAmount,
        bool configureExecutor
    ) private returns (SwapExecutionFixture memory fixture) {
        fixture.inputUnderlying = new MockERC20("USD Coin", "USDC", 6);
        fixture.outputUnderlying = new MockERC20("Tether USD", "USDT", 6);
        fixture.vault = _deployControllerVault();
        fixture.poolManager = new PoolManager(owner);
        fixture.liquidityRouter =
            new PoolModifyLiquidityTest(IPoolManager(address(fixture.poolManager)));

        vm.startPrank(owner);
        fixture.inputWrapper = fixture.vault.createWrapper(
            address(fixture.inputUnderlying), "Encrypted USDC", "eUSDC", ""
        );
        fixture.outputWrapper = fixture.vault.createWrapper(
            address(fixture.outputUnderlying), "Encrypted USDT", "eUSDT", ""
        );
        controller.setConfidentialVault(address(fixture.vault));
        fixture.executor = new AlphaEngineV4SwapExecutor(
            IPoolManager(address(fixture.poolManager)), owner, address(fixture.vault)
        );
        if (configureExecutor) {
            controller.setSwapExecutor(address(fixture.executor));
        }
        vm.stopPrank();

        fixture.inputUnderlying.mint(address(this), inputLiquidityAmount);
        fixture.outputUnderlying.mint(address(this), outputLiquidityAmount);
        fixture.inputUnderlying.approve(address(fixture.liquidityRouter), type(uint256).max);
        fixture.outputUnderlying.approve(address(fixture.liquidityRouter), type(uint256).max);

        Currency inputCurrency = Currency.wrap(address(fixture.inputUnderlying));
        Currency outputCurrency = Currency.wrap(address(fixture.outputUnderlying));
        if (address(fixture.inputUnderlying) < address(fixture.outputUnderlying)) {
            fixture.poolKey = PoolKey({
                currency0: inputCurrency,
                currency1: outputCurrency,
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            fixture.zeroForOne = true;
        } else {
            fixture.poolKey = PoolKey({
                currency0: outputCurrency,
                currency1: inputCurrency,
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            fixture.zeroForOne = false;
        }

        fixture.poolManager.initialize(fixture.poolKey, SQRT_PRICE_1_1);
        fixture.liquidityRouter.modifyLiquidity(
            fixture.poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e12,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _defaultExecutionData(PoolKey memory poolKey, bool zeroForOne)
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(
            AlphaEngineV4SwapExecutor.ExactInputParams({
                key: poolKey,
                zeroForOne: zeroForOne,
                sqrtPriceLimitX96: 0,
                hookData: ""
            })
        );
    }

    function _publishSwapDecryptResult(bytes32 unshieldRequestHandle, uint64 decryptedInputAmount)
        private
    {
        taskManager.publishDecryptResult(uint256(unshieldRequestHandle), decryptedInputAmount, "");
    }

    function _executeSwapIntentWithDefaultRoute(
        address caller,
        SwapExecutionFixture memory fixture,
        bytes32 intentId,
        address outputWrapper,
        uint64 decryptedInputAmount,
        uint64 minOutputAmount
    ) private returns (uint256 outputUnderlyingAmount, bytes32 shieldedOutputHandle) {
        vm.prank(caller);
        return controller.executeSwapIntent(
            intentId,
            outputWrapper,
            decryptedInputAmount,
            minOutputAmount,
            "",
            _defaultExecutionData(fixture.poolKey, fixture.zeroForOne)
        );
    }

    function _refundSwapIntent(bytes32 intentId, uint64 decryptedInputAmount)
        private
        returns (bytes32 refundedShieldedHandle)
    {
        return controller.refundSwapIntent(intentId, decryptedInputAmount, "");
    }

    function _assertSwapExecutionLog(
        Vm.Log[] memory logs,
        bytes32 expectedIntentId,
        address expectedOperator,
        address expectedOutputWrapper,
        bytes32 expectedRouteKey,
        uint64 expectedDecryptedInputAmount,
        uint256 expectedOutputUnderlyingAmount,
        bytes32 expectedShieldedOutputHandle
    ) private pure {
        bool found;
        bytes32 topic =
            keccak256("SwapIntentExecuted(bytes32,address,address,bytes32,uint64,uint256,bytes32)");

        for (uint256 index = 0; index < logs.length; ++index) {
            Vm.Log memory logEntry = logs[index];
            if (logEntry.topics.length == 4 && logEntry.topics[0] == topic) {
                found = true;
                assertEq(logEntry.topics[1], expectedIntentId);
                assertEq(address(uint160(uint256(logEntry.topics[2]))), expectedOperator);
                assertEq(address(uint160(uint256(logEntry.topics[3]))), expectedOutputWrapper);

                (
                    bytes32 routeKey,
                    uint64 decryptedInputAmount,
                    uint256 outputUnderlyingAmount,
                    bytes32 shieldedOutputHandle
                ) = abi.decode(logEntry.data, (bytes32, uint64, uint256, bytes32));
                assertEq(routeKey, expectedRouteKey);
                assertEq(decryptedInputAmount, expectedDecryptedInputAmount);
                assertEq(outputUnderlyingAmount, expectedOutputUnderlyingAmount);
                assertEq(shieldedOutputHandle, expectedShieldedOutputHandle);
                break;
            }
        }

        assertTrue(found, "SwapIntentExecuted log not found");
    }

    function _assertSwapRefundLog(
        Vm.Log[] memory logs,
        bytes32 expectedIntentId,
        address expectedActor,
        address expectedInputWrapper,
        uint64 expectedDecryptedInputAmount,
        bytes32 expectedRefundedShieldedHandle
    ) private pure {
        bool found;
        bytes32 topic = keccak256("SwapIntentRefunded(bytes32,address,address,uint64,bytes32)");

        for (uint256 index = 0; index < logs.length; ++index) {
            Vm.Log memory logEntry = logs[index];
            if (logEntry.topics.length == 4 && logEntry.topics[0] == topic) {
                found = true;
                assertEq(logEntry.topics[1], expectedIntentId);
                assertEq(address(uint160(uint256(logEntry.topics[2]))), expectedActor);
                assertEq(address(uint160(uint256(logEntry.topics[3]))), expectedInputWrapper);

                (uint64 decryptedInputAmount, bytes32 refundedShieldedHandle) =
                    abi.decode(logEntry.data, (uint64, bytes32));
                assertEq(decryptedInputAmount, expectedDecryptedInputAmount);
                assertEq(refundedShieldedHandle, expectedRefundedShieldedHandle);
                break;
            }
        }

        assertTrue(found, "SwapIntentRefunded log not found");
    }

    function _deployControllerVault() private returns (AlphaEngineConfidentialVault vault) {
        vault = _deployVault(address(controller));
    }

    function _deployVault(address vaultIntentController)
        private
        returns (AlphaEngineConfidentialVault vault)
    {
        AlphaEngineConfidentialVault vaultImplementation = new AlphaEngineConfidentialVault();
        TransparentUpgradeableProxy vaultProxy = new TransparentUpgradeableProxy(
            address(vaultImplementation),
            owner,
            abi.encodeCall(AlphaEngineConfidentialVault.initialize, (owner, vaultIntentController))
        );
        vault = AlphaEngineConfidentialVault(address(vaultProxy));
    }
}
