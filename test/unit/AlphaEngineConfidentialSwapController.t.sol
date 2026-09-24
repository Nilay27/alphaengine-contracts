// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Vm} from "forge-std/Vm.sol";
import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {
    AlphaEngineConfidentialAssetGateway
} from "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {
    AlphaEngineConfidentialAssetRegistry
} from "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {
    IAlphaEngineConfidentialSwapController
} from "src/interfaces/IAlphaEngineConfidentialSwapController.sol";
import {
    IAlphaEngineConfidentialSwapEscrow
} from "src/interfaces/IAlphaEngineConfidentialSwapEscrow.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";
import {AlphaEngineStrategyHashLib} from "src/libraries/AlphaEngineStrategyHashLib.sol";
import {
    AlphaEngineConfidentialSwapController
} from "src/swap/AlphaEngineConfidentialSwapController.sol";
import {AlphaEngineConfidentialSwapEscrow} from "src/swap/AlphaEngineConfidentialSwapEscrow.sol";
import {MockBoundSwapExecutor} from "test/mocks/MockBoundSwapExecutor.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AlphaEngineConfidentialSwapControllerTest is MockCoFheTest {
    bytes32 private constant ROUTE_KEY = keccak256("USDC_TO_USDT_EXACT_INPUT");
    bytes32 private constant MINIMUM_OUTPUT_SALT = keccak256("test-random-salt");

    address private admin = makeAddr("swap-admin");
    address private pauser = makeAddr("swap-pauser");
    address private operator = makeAddr("swap-operator");
    address private outsider = makeAddr("swap-outsider");
    address private trader = makeAddr("swap-trader");
    address private proxyAdminOwner = makeAddr("swap-proxy-admin");

    AlphaEngineConfidentialAssetRegistry private registry;
    AlphaEngineConfidentialAssetGateway private gateway;
    AlphaEngineConfidentialSwapController private implementation;
    AlphaEngineConfidentialSwapController private controller;
    AlphaEngineConfidentialSwapEscrow private escrow;
    MockBoundSwapExecutor private executor;
    MockERC20 private inputUnderlying;
    MockERC20 private outputUnderlying;
    address private inputWrapper;
    address private outputWrapper;

    function setUp() public {
        _installMockTaskManager();

        registry = new AlphaEngineConfidentialAssetRegistry(admin);
        gateway = new AlphaEngineConfidentialAssetGateway(registry);
        inputUnderlying = new MockERC20("USD Coin", "USDC", 6);
        outputUnderlying = new MockERC20("Tether", "USDT", 6);
        vm.startPrank(admin);
        inputWrapper =
            registry.createWrapper(address(inputUnderlying), "Encrypted USDC", "eUSDC", "");
        outputWrapper =
            registry.createWrapper(address(outputUnderlying), "Encrypted USDT", "eUSDT", "");
        vm.stopPrank();

        implementation = new AlphaEngineConfidentialSwapController();
        TransparentUpgradeableProxy controllerProxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapController.initialize,
                (AlphaEngineConfidentialSwapController.InitializationParams({
                        initialDefaultAdmin: admin,
                        initialPauser: pauser,
                        initialSwapOperator: operator
                    }))
            )
        );
        controller = AlphaEngineConfidentialSwapController(address(controllerProxy));

        escrow = _deployEscrow();
        executor = new MockBoundSwapExecutor(address(escrow));
        vm.prank(admin);
        controller.setSwapConfiguration(address(escrow), address(executor));
        vm.prank(admin);
        escrow.unpause();
        vm.prank(admin);
        controller.unpause();

        _shieldInput(trader, 1000e6);
    }

    function test_initializeDisablesImplementationAndSetsSeparatedRolesPaused() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            AlphaEngineConfidentialSwapController.InitializationParams({
                initialDefaultAdmin: admin, initialPauser: pauser, initialSwapOperator: operator
            })
        );

        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(controller.hasRole(controller.PAUSER_ROLE(), pauser));
        assertTrue(controller.hasRole(controller.SWAP_OPERATOR_ROLE(), operator));
        assertFalse(controller.paused());
        assertEq(controller.swapEscrow(), address(escrow));
        assertEq(controller.swapExecutor(), address(executor));
    }

    function test_initializeRejectsEveryZeroRoleAddress() public {
        _expectInitializationFailure(address(0), pauser, operator, "DEFAULT_ADMIN");
        _expectInitializationFailure(admin, address(0), operator, "PAUSER");
        _expectInitializationFailure(admin, pauser, address(0), "SWAP_OPERATOR");
    }

    function test_configurationIsAtomicValidatedAndRequiredBeforeUnpause() public {
        AlphaEngineConfidentialSwapController unconfigured = _deployController();
        vm.prank(admin);
        vm.expectRevert(AlphaEngineConfidentialSwapController.SwapConfigurationIncomplete.selector);
        unconfigured.unpause();

        vm.prank(pauser);
        controller.pause();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.SwapConfigurationUnchanged.selector,
                address(escrow),
                address(executor)
            )
        );
        controller.setSwapConfiguration(address(escrow), address(executor));

        MockBoundSwapExecutor wrongCallerExecutor = new MockBoundSwapExecutor(outsider);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.ExecutorCallerMismatch.selector,
                address(wrongCallerExecutor),
                address(escrow),
                outsider
            )
        );
        controller.setSwapConfiguration(address(escrow), address(wrongCallerExecutor));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.InvalidSwapEscrow.selector, outsider
            )
        );
        controller.setSwapConfiguration(outsider, address(executor));

        AlphaEngineConfidentialSwapEscrow nextEscrow = _deployEscrow();
        MockBoundSwapExecutor nextExecutor = new MockBoundSwapExecutor(address(nextEscrow));
        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(controller));
        emit AlphaEngineConfidentialSwapController.SwapConfigurationUpdated(
            address(escrow), address(nextEscrow), address(executor), address(nextExecutor)
        );
        controller.setSwapConfiguration(address(nextEscrow), address(nextExecutor));
        assertEq(controller.swapEscrow(), address(nextEscrow));
        assertEq(controller.swapExecutor(), address(nextExecutor));
    }

    function test_submitPinsEveryExecutionAndCustodyFieldWithEventGetterParity() public {
        uint64 inputAmount = 100e6;
        uint256 outputAmount = 97e6;
        bytes memory executionData = abi.encode(outputAmount);
        bytes32 intentId = controller.computeSwapIntentId(trader, 0);
        bytes32 minimumCommitment =
            controller.computeMinimumOutputCommitment(intentId, outputAmount, MINIMUM_OUTPUT_SALT);
        uint40 deadline = uint40(block.timestamp + 1 hours);

        vm.recordLogs();
        bytes32 actualIntentId = _submit(
            trader, inputAmount, deadline, executionData, outputAmount, MINIMUM_OUTPUT_SALT
        );
        assertEq(actualIntentId, intentId);

        IAlphaEngineConfidentialSwapController.SwapIntentRecord memory record =
            controller.getSwapIntent(intentId);
        IAlphaEngineConfidentialSwapEscrow.SwapIntentLock memory intentLock =
            escrow.getSwapIntentLock(intentId);
        assertEq(record.trader, trader);
        assertEq(record.escrow, address(escrow));
        assertEq(record.executor, address(executor));
        assertEq(record.inputWrapper, inputWrapper);
        assertEq(record.outputWrapper, outputWrapper);
        assertEq(record.routeKey, ROUTE_KEY);
        assertEq(record.executionDataHash, keccak256(executionData));
        assertEq(record.minimumOutputCommitment, minimumCommitment);
        assertEq(record.lockedAmountHandle, euint64.unwrap(intentLock.lockedAmount));
        assertEq(record.unshieldRequestHandle, euint64.unwrap(intentLock.unshieldRequestHandle));
        assertEq(record.deadline, deadline);
        assertEq(record.traderNonce, 0);
        assertEq(
            uint8(record.status),
            uint8(IAlphaEngineConfidentialSwapController.SwapIntentStatus.Active)
        );
        assertEq(controller.traderNonces(trader), 1);
        assertTrue(controller.existsSwapIntent(intentId));
        assertTrue(taskManager.isAllowed(uint256(record.lockedAmountHandle), address(escrow)));

        AlphaEngineStrategyHashLib.SwapPayloadV1 memory payload =
            AlphaEngineStrategyHashLib.SwapPayloadV1({
                chainId: block.chainid,
                controller: address(controller),
                intentId: intentId,
                trader: trader,
                traderNonce: 0,
                escrow: address(escrow),
                executor: address(executor),
                inputWrapper: inputWrapper,
                outputWrapper: outputWrapper,
                routeKey: ROUTE_KEY,
                executionDataHash: keccak256(executionData),
                minimumOutputCommitment: minimumCommitment,
                deadline: deadline,
                lockedAmountHandle: record.lockedAmountHandle,
                unshieldRequestHandle: record.unshieldRequestHandle
            });
        assertEq(record.payloadHash, AlphaEngineStrategyHashLib.hashSwapPayload(payload));

        _assertSubmissionEvents(vm.getRecordedLogs(), record);
    }

    function test_submitRejectsInvalidFieldsAndDoesNotAdvanceNonce() public {
        bytes memory executionData = abi.encode(uint256(90e6));
        uint40 deadline = uint40(block.timestamp + 1 hours);
        IAlphaEngineConfidentialSwapController.SwapIntentSubmission memory submission =
            _submission(trader, 100e6, deadline, executionData, 90e6, MINIMUM_OUTPUT_SALT);

        submission.inputWrapper = address(0);
        _expectSubmitError(
            submission, AlphaEngineConfidentialSwapController.ZeroInputWrapper.selector
        );
        submission = _submission(trader, 100e6, deadline, executionData, 90e6, MINIMUM_OUTPUT_SALT);
        submission.outputWrapper = address(0);
        _expectSubmitError(
            submission, AlphaEngineConfidentialSwapController.ZeroOutputWrapper.selector
        );
        submission = _submission(trader, 100e6, deadline, executionData, 90e6, MINIMUM_OUTPUT_SALT);
        submission.routeKey = bytes32(0);
        _expectSubmitError(submission, AlphaEngineConfidentialSwapController.ZeroRouteKey.selector);
        submission = _submission(trader, 100e6, deadline, executionData, 90e6, MINIMUM_OUTPUT_SALT);
        submission.executionDataHash = bytes32(0);
        _expectSubmitError(
            submission, AlphaEngineConfidentialSwapController.ZeroExecutionDataHash.selector
        );
        submission = _submission(trader, 100e6, deadline, executionData, 90e6, MINIMUM_OUTPUT_SALT);
        submission.minimumOutputCommitment = bytes32(0);
        _expectSubmitError(
            submission, AlphaEngineConfidentialSwapController.ZeroMinimumOutputCommitment.selector
        );

        assertEq(controller.traderNonces(trader), 0);
        assertEq(escrow.liveSwapLockCount(), 0);
    }

    function test_submitRejectsUnknownWrappersDeadlineAndPausedState() public {
        bytes memory executionData = abi.encode(uint256(90e6));
        uint40 deadline = uint40(block.timestamp + 1 hours);
        IAlphaEngineConfidentialSwapController.SwapIntentSubmission memory submission =
            _submission(trader, 100e6, deadline, executionData, 90e6, MINIMUM_OUTPUT_SALT);
        submission.outputWrapper = outsider;

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.WrapperNotRegistered.selector, outsider
            )
        );
        controller.submitSwapIntent(submission);

        submission = _submission(
            trader, 100e6, uint40(block.timestamp), executionData, 90e6, MINIMUM_OUTPUT_SALT
        );
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.DeadlineNotInFuture.selector,
                uint40(block.timestamp),
                block.timestamp
            )
        );
        controller.submitSwapIntent(submission);

        vm.prank(pauser);
        controller.pause();
        submission = _submission(trader, 100e6, deadline, executionData, 90e6, MINIMUM_OUTPUT_SALT);
        vm.prank(trader);
        vm.expectRevert();
        controller.submitSwapIntent(submission);
    }

    function test_executeRevealsExactCommitmentsAndSettlesOnlyOnce() public {
        uint64 inputAmount = 100e6;
        uint256 outputAmount = 97e6;
        bytes memory executionData = abi.encode(outputAmount);
        bytes32 intentId = _submit(
            trader,
            inputAmount,
            uint40(block.timestamp + 1 hours),
            executionData,
            outputAmount,
            MINIMUM_OUTPUT_SALT
        );
        _publishInput(intentId, inputAmount);

        vm.recordLogs();
        vm.prank(operator);
        (uint256 actualOutput, bytes32 outputHandle) = controller.executeSwapIntent(
            intentId, inputAmount, outputAmount, MINIMUM_OUTPUT_SALT, "", executionData
        );

        _assertExecutionEvent(
            vm.getRecordedLogs(), intentId, inputAmount, actualOutput, outputHandle
        );

        assertEq(actualOutput, outputAmount);
        assertEq(mockStorage(uint256(outputHandle)), outputAmount);
        assertEq(
            uint8(controller.getSwapIntent(intentId).status),
            uint8(IAlphaEngineConfidentialSwapController.SwapIntentStatus.Executed)
        );
        assertEq(
            uint8(escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Consumed)
        );
        assertEq(escrow.liveSwapLockCount(), 0);
        assertEq(inputUnderlying.balanceOf(address(escrow)), 0);
        assertEq(outputUnderlying.balanceOf(address(escrow)), 0);
        assertEq(inputUnderlying.balanceOf(address(executor)), 0);
        assertEq(outputUnderlying.balanceOf(address(executor)), 0);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.InvalidSwapIntentStatus.selector,
                intentId,
                IAlphaEngineConfidentialSwapController.SwapIntentStatus.Executed
            )
        );
        controller.executeSwapIntent(
            intentId, inputAmount, outputAmount, MINIMUM_OUTPUT_SALT, "", executionData
        );
    }

    function test_executeRejectsEveryUncommittedSubstitutionAndRollsBack() public {
        uint64 inputAmount = 100e6;
        uint256 outputAmount = 97e6;
        bytes memory executionData = abi.encode(outputAmount);
        bytes32 intentId = _submit(
            trader,
            inputAmount,
            uint40(block.timestamp + 1 hours),
            executionData,
            outputAmount,
            MINIMUM_OUTPUT_SALT
        );
        _publishInput(intentId, inputAmount);

        bytes memory substitutedExecutionData = abi.encode(outputAmount + 1);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.ExecutionDataHashMismatch.selector,
                keccak256(substitutedExecutionData),
                keccak256(executionData)
            )
        );
        controller.executeSwapIntent(
            intentId, inputAmount, outputAmount, MINIMUM_OUTPUT_SALT, "", substitutedExecutionData
        );

        bytes32 expectedMinimumCommitment =
            controller.getSwapIntent(intentId).minimumOutputCommitment;
        bytes32 wrongOutputCommitment = AlphaEngineExecutionHashLib.hashSwapMinimumOutput(
            intentId, outputAmount + 1, MINIMUM_OUTPUT_SALT
        );
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.MinimumOutputCommitmentMismatch.selector,
                wrongOutputCommitment,
                expectedMinimumCommitment
            )
        );
        controller.executeSwapIntent(
            intentId, inputAmount, outputAmount + 1, MINIMUM_OUTPUT_SALT, "", executionData
        );

        bytes32 wrongSalt = bytes32(uint256(1));
        bytes32 wrongSaltCommitment =
            AlphaEngineExecutionHashLib.hashSwapMinimumOutput(intentId, outputAmount, wrongSalt);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.MinimumOutputCommitmentMismatch.selector,
                wrongSaltCommitment,
                expectedMinimumCommitment
            )
        );
        controller.executeSwapIntent(
            intentId, inputAmount, outputAmount, wrongSalt, "", executionData
        );

        vm.prank(operator);
        vm.expectRevert(AlphaEngineConfidentialSwapController.ZeroMinimumOutputSalt.selector);
        controller.executeSwapIntent(
            intentId, inputAmount, outputAmount, bytes32(0), "", executionData
        );

        assertEq(
            uint8(controller.getSwapIntent(intentId).status),
            uint8(IAlphaEngineConfidentialSwapController.SwapIntentStatus.Active)
        );
        assertEq(
            uint8(escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested)
        );
        assertEq(escrow.liveSwapLockCount(), 1);
    }

    function test_executeRejectsUnauthorizedZeroAndExpiredInput() public {
        uint64 inputAmount = 100e6;
        uint256 outputAmount = 97e6;
        bytes memory executionData = abi.encode(outputAmount);
        uint40 deadline = uint40(block.timestamp + 1 hours);
        bytes32 intentId = _submit(
            trader, inputAmount, deadline, executionData, outputAmount, MINIMUM_OUTPUT_SALT
        );
        _publishInput(intentId, inputAmount);

        vm.prank(outsider);
        vm.expectRevert();
        controller.executeSwapIntent(
            intentId, inputAmount, outputAmount, MINIMUM_OUTPUT_SALT, "", executionData
        );

        vm.prank(operator);
        vm.expectRevert(AlphaEngineConfidentialSwapController.ZeroDecryptedInputAmount.selector);
        controller.executeSwapIntent(
            intentId, 0, outputAmount, MINIMUM_OUTPUT_SALT, "", executionData
        );

        vm.warp(deadline);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.SwapIntentExpired.selector,
                intentId,
                deadline,
                block.timestamp
            )
        );
        controller.executeSwapIntent(
            intentId, inputAmount, outputAmount, MINIMUM_OUTPUT_SALT, "", executionData
        );
    }

    function test_failedExecutorRollsBackControllerAndEscrowConsumption() public {
        uint64 inputAmount = 100e6;
        uint256 actualOutput = 90e6;
        uint256 minimumOutput = 95e6;
        bytes memory executionData = abi.encode(actualOutput);
        bytes32 intentId = _submit(
            trader,
            inputAmount,
            uint40(block.timestamp + 1 hours),
            executionData,
            minimumOutput,
            MINIMUM_OUTPUT_SALT
        );
        _publishInput(intentId, inputAmount);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockBoundSwapExecutor.OutputAmountBelowMinimum.selector, minimumOutput, actualOutput
            )
        );
        controller.executeSwapIntent(
            intentId, inputAmount, minimumOutput, MINIMUM_OUTPUT_SALT, "", executionData
        );

        assertEq(
            uint8(controller.getSwapIntent(intentId).status),
            uint8(IAlphaEngineConfidentialSwapController.SwapIntentStatus.Active)
        );
        assertEq(
            uint8(escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested)
        );
        assertEq(escrow.liveSwapLockCount(), 1);
        assertEq(inputUnderlying.balanceOf(address(escrow)), 0);
    }

    function test_refundIsPermissionlessAfterExpiryWithExactEventParity() public {
        uint64 inputAmount = 100e6;
        bytes memory executionData = abi.encode(uint256(97e6));
        uint40 deadline = uint40(block.timestamp + 1 hours);
        bytes32 intentId =
            _submit(trader, inputAmount, deadline, executionData, 97e6, MINIMUM_OUTPUT_SALT);
        _publishInput(intentId, inputAmount);

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.SwapIntentRefundUnavailable.selector,
                intentId,
                deadline,
                block.timestamp
            )
        );
        controller.refundSwapIntent(intentId, inputAmount, "");

        vm.warp(deadline);
        vm.recordLogs();
        vm.prank(outsider);
        bytes32 refundHandle = controller.refundSwapIntent(intentId, inputAmount, "");
        _assertRefundEvent(vm.getRecordedLogs(), intentId, inputAmount, refundHandle);
        assertEq(mockStorage(uint256(refundHandle)), inputAmount);
        assertEq(
            uint8(controller.getSwapIntent(intentId).status),
            uint8(IAlphaEngineConfidentialSwapController.SwapIntentStatus.Refunded)
        );
        assertEq(
            uint8(escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Refunded)
        );
        assertEq(escrow.liveSwapLockCount(), 0);
    }

    function test_refundIsPermissionlessBeforeExpiryWhenRecordedEscrowIsPaused() public {
        uint64 inputAmount = 100e6;
        bytes memory executionData = abi.encode(uint256(97e6));
        bytes32 intentId = _submit(
            trader,
            inputAmount,
            uint40(block.timestamp + 1 hours),
            executionData,
            97e6,
            MINIMUM_OUTPUT_SALT
        );
        _publishInput(intentId, inputAmount);

        vm.prank(pauser);
        escrow.pause();
        vm.prank(outsider);
        bytes32 refundHandle = controller.refundSwapIntent(intentId, inputAmount, "");

        assertEq(mockStorage(uint256(refundHandle)), inputAmount);
        assertEq(
            uint8(controller.getSwapIntent(intentId).status),
            uint8(IAlphaEngineConfidentialSwapController.SwapIntentStatus.Refunded)
        );
        assertEq(escrow.liveSwapLockCount(), 0);
    }

    function test_unknownSwapIntentGetterIsTypedAndExistsIsFalse() public {
        bytes32 unknownIntentId = keccak256("unknown-swap-intent");
        assertFalse(controller.existsSwapIntent(unknownIntentId));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.SwapIntentNotFound.selector, unknownIntentId
            )
        );
        controller.getSwapIntent(unknownIntentId);
    }

    function test_refundTerminatesInitializedEncryptedZeroLockWhilePaused() public {
        bytes memory executionData = abi.encode(uint256(1));
        bytes32 intentId = _submit(
            trader, 2000e6, uint40(block.timestamp + 1 hours), executionData, 1, MINIMUM_OUTPUT_SALT
        );
        IAlphaEngineConfidentialSwapController.SwapIntentRecord memory record =
            controller.getSwapIntent(intentId);
        assertEq(mockStorage(uint256(record.lockedAmountHandle)), 0);
        _publishInput(intentId, 0);

        vm.prank(pauser);
        controller.pause();
        vm.prank(outsider);
        bytes32 refundHandle = controller.refundSwapIntent(intentId, 0, "");
        assertEq(refundHandle, bytes32(0));
        assertEq(
            uint8(controller.getSwapIntent(intentId).status),
            uint8(IAlphaEngineConfidentialSwapController.SwapIntentStatus.Refunded)
        );
        assertEq(escrow.liveSwapLockCount(), 0);
    }

    function testFuzz_nonceAndIntentIdAdvanceExactlyOnceOnSuccessfulSubmission(
        uint64 firstAmount,
        uint64 secondAmount
    ) public {
        firstAmount = uint64(bound(firstAmount, 1, 400e6));
        secondAmount = uint64(bound(secondAmount, 1, 400e6));
        bytes memory executionData = abi.encode(uint256(1));

        bytes32 expectedFirst = controller.computeSwapIntentId(trader, 0);
        bytes32 first = _submit(
            trader,
            firstAmount,
            uint40(block.timestamp + 1 hours),
            executionData,
            1,
            MINIMUM_OUTPUT_SALT
        );
        bytes32 expectedSecond = controller.computeSwapIntentId(trader, 1);
        bytes32 second = _submit(
            trader,
            secondAmount,
            uint40(block.timestamp + 1 hours),
            executionData,
            1,
            bytes32(uint256(MINIMUM_OUTPUT_SALT) + 1)
        );

        assertEq(first, expectedFirst);
        assertEq(second, expectedSecond);
        assertNotEq(first, second);
        assertEq(controller.traderNonces(trader), 2);
    }

    function _submit(
        address submitter,
        uint64 inputAmount,
        uint40 deadline,
        bytes memory executionData,
        uint256 minimumOutput,
        bytes32 salt
    ) private returns (bytes32 intentId) {
        IAlphaEngineConfidentialSwapController.SwapIntentSubmission memory submission =
            _submission(submitter, inputAmount, deadline, executionData, minimumOutput, salt);
        vm.prank(submitter);
        return controller.submitSwapIntent(submission);
    }

    function _submission(
        address submitter,
        uint64 inputAmount,
        uint40 deadline,
        bytes memory executionData,
        uint256 minimumOutput,
        bytes32 salt
    )
        private
        returns (IAlphaEngineConfidentialSwapController.SwapIntentSubmission memory submission)
    {
        uint64 nonce = controller.traderNonces(submitter);
        bytes32 intentId = controller.computeSwapIntentId(submitter, nonce);
        submission = IAlphaEngineConfidentialSwapController.SwapIntentSubmission({
            inputWrapper: inputWrapper,
            outputWrapper: outputWrapper,
            routeKey: ROUTE_KEY,
            executionDataHash: keccak256(executionData),
            minimumOutputCommitment: AlphaEngineExecutionHashLib.hashSwapMinimumOutput(
                    intentId, minimumOutput, salt
                ),
            encryptedInputAmount: createExternalEuint64(inputAmount, submitter),
            inputProof: "",
            deadline: deadline
        });
        submission.inputProof = _inputProof(address(controller), submission.encryptedInputAmount);
    }

    function _expectSubmitError(
        IAlphaEngineConfidentialSwapController.SwapIntentSubmission memory submission,
        bytes4 selector
    ) private {
        vm.prank(trader);
        vm.expectRevert(selector);
        controller.submitSwapIntent(submission);
    }

    function _publishInput(bytes32 intentId, uint64 decryptedInputAmount) private {
        bytes32 requestHandle = controller.getSwapIntent(intentId).unshieldRequestHandle;
        taskManager.publishDecryptResult(uint256(requestHandle), decryptedInputAmount, "");
    }

    function _shieldInput(address account, uint256 amount) private {
        inputUnderlying.mint(account, amount);
        vm.startPrank(account);
        inputUnderlying.approve(address(gateway), amount);
        gateway.depositAndShield(address(inputUnderlying), amount, account);
        AlphaEngineFHERC20ERC20Wrapper(inputWrapper)
            .setOperator(address(escrow), uint48(block.timestamp + 30 days));
        vm.stopPrank();
    }

    function _deployController() private returns (AlphaEngineConfidentialSwapController deployed) {
        AlphaEngineConfidentialSwapController fresh = new AlphaEngineConfidentialSwapController();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(fresh),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapController.initialize,
                (AlphaEngineConfidentialSwapController.InitializationParams({
                        initialDefaultAdmin: admin,
                        initialPauser: pauser,
                        initialSwapOperator: operator
                    }))
            )
        );
        return AlphaEngineConfidentialSwapController(address(proxy));
    }

    function _deployEscrow() private returns (AlphaEngineConfidentialSwapEscrow deployed) {
        AlphaEngineConfidentialSwapEscrow fresh = new AlphaEngineConfidentialSwapEscrow();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(fresh),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapEscrow.initialize,
                (admin, pauser, address(controller), address(registry))
            )
        );
        return AlphaEngineConfidentialSwapEscrow(address(proxy));
    }

    function _expectInitializationFailure(
        address initialDefaultAdmin,
        address initialPauser,
        address initialOperator,
        bytes32 field
    ) private {
        AlphaEngineConfidentialSwapController fresh = new AlphaEngineConfidentialSwapController();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.ZeroInitializationAddress.selector, field
            )
        );
        new TransparentUpgradeableProxy(
            address(fresh),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapController.initialize,
                (AlphaEngineConfidentialSwapController.InitializationParams({
                        initialDefaultAdmin: initialDefaultAdmin,
                        initialPauser: initialPauser,
                        initialSwapOperator: initialOperator
                    }))
            )
        );
    }

    function _assertSubmissionEvents(
        Vm.Log[] memory logs,
        IAlphaEngineConfidentialSwapController.SwapIntentRecord memory record
    ) private view {
        bytes32
            submissionTopic =
            keccak256(
                "ConfidentialSwapSubmitted(bytes32,address,address,address,address,address,bytes32,bytes32,bytes32,uint40,bytes32,uint64)"
            );
        bytes32 commitmentTopic =
            keccak256("ConfidentialSwapExecutionCommitted(bytes32,bytes32,bytes32)");
        bool foundSubmission;
        bool foundCommitment;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(controller)) continue;
            if (logs[i].topics[0] == submissionTopic) {
                foundSubmission = true;
                assertEq(logs[i].topics[1], controller.computeSwapIntentId(trader, 0));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), trader);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), inputWrapper);
                (
                    address emittedOutputWrapper,
                    address emittedEscrow,
                    address emittedExecutor,
                    bytes32 emittedRouteKey,
                    bytes32 emittedLockedAmountHandle,
                    bytes32 emittedUnshieldRequestHandle,
                    uint40 emittedDeadline,
                    bytes32 emittedPayloadHash,
                    uint64 emittedTraderNonce
                ) = abi.decode(
                    logs[i].data,
                    (address, address, address, bytes32, bytes32, bytes32, uint40, bytes32, uint64)
                );
                assertEq(emittedOutputWrapper, record.outputWrapper);
                assertEq(emittedEscrow, record.escrow);
                assertEq(emittedExecutor, record.executor);
                assertEq(emittedRouteKey, record.routeKey);
                assertEq(emittedLockedAmountHandle, record.lockedAmountHandle);
                assertEq(emittedUnshieldRequestHandle, record.unshieldRequestHandle);
                assertEq(emittedDeadline, record.deadline);
                assertEq(emittedPayloadHash, record.payloadHash);
                assertEq(emittedTraderNonce, record.traderNonce);
            }
            if (logs[i].topics[0] == commitmentTopic) {
                foundCommitment = true;
                assertEq(logs[i].topics[2], record.executionDataHash);
                assertEq(logs[i].topics[3], record.minimumOutputCommitment);
            }
        }
        assertTrue(foundSubmission);
        assertTrue(foundCommitment);
    }

    function _assertExecutionEvent(
        Vm.Log[] memory logs,
        bytes32 intentId,
        uint64 inputAmount,
        uint256 outputAmount,
        bytes32 outputHandle
    ) private view {
        bytes32 eventTopic = keccak256(
            "ConfidentialSwapExecuted(bytes32,address,address,address,uint64,uint256,bytes32)"
        );
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(controller) || logs[i].topics[0] != eventTopic) {
                continue;
            }
            assertEq(logs[i].topics[1], intentId);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), trader);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), operator);
            (
                address emittedWrapper,
                uint64 emittedInput,
                uint256 emittedOutput,
                bytes32 emittedHandle
            ) = abi.decode(logs[i].data, (address, uint64, uint256, bytes32));
            assertEq(emittedWrapper, outputWrapper);
            assertEq(emittedInput, inputAmount);
            assertEq(emittedOutput, outputAmount);
            assertEq(emittedHandle, outputHandle);
            return;
        }
        assertTrue(false, "missing ConfidentialSwapExecuted event");
    }

    function _assertRefundEvent(
        Vm.Log[] memory logs,
        bytes32 intentId,
        uint64 inputAmount,
        bytes32 refundHandle
    ) private view {
        bytes32 eventTopic = keccak256(
            "ConfidentialSwapRefunded(bytes32,address,address,address,uint64,bytes32)"
        );
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(controller) || logs[i].topics[0] != eventTopic) {
                continue;
            }
            assertEq(logs[i].topics[1], intentId);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), trader);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), outsider);
            (address emittedWrapper, uint64 emittedInput, bytes32 emittedHandle) =
                abi.decode(logs[i].data, (address, uint64, bytes32));
            assertEq(emittedWrapper, inputWrapper);
            assertEq(emittedInput, inputAmount);
            assertEq(emittedHandle, refundHandle);
            return;
        }
        assertTrue(false, "missing ConfidentialSwapRefunded event");
    }
}
