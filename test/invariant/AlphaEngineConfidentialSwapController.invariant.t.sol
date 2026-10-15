// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
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
import {AlphaEngineStrategyHashLib} from "src/libraries/AlphaEngineStrategyHashLib.sol";
import {
    AlphaEngineConfidentialSwapController
} from "src/swap/AlphaEngineConfidentialSwapController.sol";
import {AlphaEngineConfidentialSwapEscrow} from "src/swap/AlphaEngineConfidentialSwapEscrow.sol";
import {
    ConfidentialSwapControllerInvariantHandler
} from "test/handlers/ConfidentialSwapControllerInvariantHandler.sol";
import {MockBoundSwapExecutor} from "test/mocks/MockBoundSwapExecutor.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AlphaEngineConfidentialSwapControllerInvariantTest is StdInvariant, MockCoFheTest {
    address private admin = makeAddr("controller-invariant-admin");
    address private pauser = makeAddr("controller-invariant-pauser");
    address private operator = makeAddr("controller-invariant-operator");
    address private traderA = makeAddr("controller-invariant-trader-a");
    address private traderB = makeAddr("controller-invariant-trader-b");
    address private proxyAdminOwner = makeAddr("controller-invariant-proxy-admin");

    AlphaEngineConfidentialSwapController private controller;
    AlphaEngineConfidentialSwapEscrow private escrow;
    AlphaEngineConfidentialAssetRegistry private registry;
    AlphaEngineConfidentialAssetGateway private gateway;
    MockBoundSwapExecutor private executor;
    MockERC20 private inputUnderlying;
    MockERC20 private outputUnderlying;
    address private inputWrapper;
    address private outputWrapper;
    ConfidentialSwapControllerInvariantHandler private handler;

    function setUp() public {
        _installMockTaskManager();
        registry = _deployAssetRegistry(admin);
        gateway = _deployAssetGateway(registry);
        inputUnderlying = new MockERC20("Invariant Input", "IIN", 6);
        outputUnderlying = new MockERC20("Invariant Output", "IOUT", 6);
        vm.startPrank(admin);
        inputWrapper = registry.createWrapper(
            address(inputUnderlying), "Encrypted Invariant Input", "eIIN", ""
        );
        outputWrapper = registry.createWrapper(
            address(outputUnderlying), "Encrypted Invariant Output", "eIOUT", ""
        );
        registry.setWrapperMinimums(inputWrapper, 1000, 1000);
        registry.setWrapperMinimums(outputWrapper, 1, 1000);
        vm.stopPrank();

        controller = _deployController();
        escrow = _deployEscrow();
        executor = new MockBoundSwapExecutor(address(escrow));
        vm.prank(admin);
        controller.setSwapConfiguration(address(escrow), address(executor));
        vm.prank(admin);
        registry.setTrustedSwapEscrow(address(escrow));
        vm.prank(admin);
        escrow.unpause();
        vm.prank(admin);
        controller.unpause();

        _shield(traderA, 2000e6);
        _shield(traderB, 2000e6);

        handler = new ConfidentialSwapControllerInvariantHandler(
            controller,
            escrow,
            inputWrapper,
            outputWrapper,
            operator,
            traderA,
            traderB,
            admin,
            pauser
        );

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.submitAsA.selector;
        selectors[1] = handler.submitAsB.selector;
        selectors[2] = handler.executeActive.selector;
        selectors[3] = handler.refundExpiredActive.selector;
        selectors[4] = handler.rejectExecutionDataMutation.selector;
        selectors[5] = handler.rejectMinimumOutputMutation.selector;
        selectors[6] = handler.rejectTerminalReplay.selector;
        selectors[7] = handler.rotateFutureExecutor.selector;
        selectors[8] = handler.pausedPreclaimRefund.selector;
        selectors[9] = handler.configureLimits.selector;
        selectors[10] = handler.advanceTime.selector;
        selectors[11] = handler.rejectSaltMutation.selector;
        selectors[12] = handler.rejectTerminalRefundReplay.selector;
        selectors[13] = handler.rejectIncorrectRefundResult.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        // Seed every important transition so campaign success cannot be vacuous.
        handler.submitAsA(25e6, 40e6, bytes32(uint256(1)));
        handler.rejectExecutionDataMutation(0);
        handler.rejectMinimumOutputMutation(0);
        handler.executeActive(0);
        handler.rejectTerminalReplay(0);
        handler.submitAsB(30e6, 45e6, bytes32(uint256(2)));
        handler.refundExpiredActive(0);
        handler.submitAsA(999, 1, bytes32(uint256(3)));
        handler.refundExpiredActive(0);
        handler.submitAsA(1000, 1, bytes32(uint256(4)));
        handler.advanceTime(300);
        handler.submitAsA(1000, 1, bytes32(uint256(5)));
        handler.rotateFutureExecutor(0);
        handler.rejectSaltMutation(0);
        handler.rejectIncorrectRefundResult(0);
        handler.pausedPreclaimRefund(0);
        handler.rejectTerminalRefundReplay(0);
        handler.configureLimits(120, 1, 1);
        handler.submitAsA(1000, 1, bytes32(uint256(6)));
        handler.submitAsB(1000, 1, bytes32(uint256(7)));
    }

    function invariant_nonceEqualsSuccessfulSubmissionsPerTrader() public view {
        assertEq(controller.swapCooldownUntil(traderA), handler.expectedCooldownUntil(traderA));
        assertEq(controller.swapCooldownUntil(traderB), handler.expectedCooldownUntil(traderB));
        assertGt(handler.rejectedCooldowns(), 0);
        assertEq(controller.traderNonces(traderA), handler.successfulSubmissions(traderA));
        assertEq(controller.traderNonces(traderB), handler.successfulSubmissions(traderB));
    }

    function invariant_recordsRetainBoundPayloadAndIdentity() public view {
        uint256 count = handler.snapshotCount();
        for (uint256 i; i < count; ++i) {
            ConfidentialSwapControllerInvariantHandler.IntentSnapshot memory snapshot =
                handler.snapshotAt(i);
            IAlphaEngineConfidentialSwapController.SwapIntentRecord memory record =
                controller.getSwapIntent(snapshot.intentId);
            assertEq(record.trader, snapshot.trader);
            assertEq(record.escrow, address(escrow));
            assertEq(record.executor, snapshot.executor);
            assertEq(record.inputWrapper, inputWrapper);
            assertEq(record.outputWrapper, outputWrapper);
            assertEq(record.traderNonce, snapshot.traderNonce);
            assertEq(record.lockedAmountHandle, snapshot.lockedAmountHandle);
            assertEq(record.unshieldRequestHandle, snapshot.unshieldRequestHandle);
            assertEq(record.payloadHash, snapshot.payloadHash);
            assertEq(
                record.payloadHash,
                AlphaEngineStrategyHashLib.hashSwapPayload(
                    AlphaEngineStrategyHashLib.SwapPayloadV1({
                        chainId: block.chainid,
                        controller: address(controller),
                        intentId: snapshot.intentId,
                        trader: snapshot.trader,
                        traderNonce: snapshot.traderNonce,
                        escrow: address(escrow),
                        executor: snapshot.executor,
                        inputWrapper: inputWrapper,
                        outputWrapper: outputWrapper,
                        routeKey: record.routeKey,
                        executionDataHash: record.executionDataHash,
                        minimumOutputCommitment: record.minimumOutputCommitment,
                        deadline: record.deadline,
                        lockedAmountHandle: record.lockedAmountHandle,
                        unshieldRequestHandle: record.unshieldRequestHandle
                    })
                )
            );
        }
    }

    function invariant_controllerAndEscrowLifecycleRemainInParity() public view {
        uint256 count = handler.snapshotCount();
        uint256 expectedLiveLocks;
        for (uint256 i; i < count; ++i) {
            ConfidentialSwapControllerInvariantHandler.IntentSnapshot memory snapshot =
                handler.snapshotAt(i);
            IAlphaEngineConfidentialSwapController.SwapIntentStatus controllerStatus =
            controller.getSwapIntent(snapshot.intentId).status;
            IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus escrowStatus =
            escrow.getSwapIntentLock(snapshot.intentId).status;
            assertEq(uint8(controllerStatus), uint8(snapshot.expectedStatus));
            if (controllerStatus == IAlphaEngineConfidentialSwapController.SwapIntentStatus.Active)
            {
                expectedLiveLocks += 1;
                assertEq(controller.activeSwapIntentOf(snapshot.trader), snapshot.intentId);
                assertEq(
                    uint8(escrowStatus),
                    uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested)
                );
            } else if (
                controllerStatus == IAlphaEngineConfidentialSwapController.SwapIntentStatus.Executed
            ) {
                assertNotEq(controller.activeSwapIntentOf(snapshot.trader), snapshot.intentId);
                assertEq(
                    uint8(escrowStatus),
                    uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Consumed)
                );
            } else {
                assertNotEq(controller.activeSwapIntentOf(snapshot.trader), snapshot.intentId);
                assertEq(
                    uint8(escrowStatus),
                    uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Refunded)
                );
            }
        }
        assertEq(escrow.liveSwapLockCount(), expectedLiveLocks);
        assertLe(expectedLiveLocks, 2);
        assertEq(
            controller.submittedSwapIntentCount(),
            uint256(handler.successfulSubmissions(traderA)) + handler.successfulSubmissions(traderB)
        );
    }

    function invariant_controllerNeverHoldsTokens() public view {
        assertEq(inputUnderlying.balanceOf(address(controller)), 0);
        assertEq(outputUnderlying.balanceOf(address(controller)), 0);
        assertEq(inputUnderlying.balanceOf(address(executor)), 0);
        assertEq(outputUnderlying.balanceOf(address(executor)), 0);
    }

    function invariant_meaningfulTransitionsAndAdversarialChecksAreReached() public view {
        assertGt(handler.successfulSubmissions(traderA), 0);
        assertGt(handler.successfulSubmissions(traderB), 0);
        assertGt(handler.successfulExecutions(), 0);
        assertGt(handler.successfulRefunds(), 0);
        assertGt(handler.rejectedExecutionDataMutations(), 0);
        assertGt(handler.rejectedMinimumOutputMutations(), 0);
        assertGt(handler.rejectedReplays(), 0);
        assertGt(handler.configurationRotations(), 0);
        assertGt(handler.pauseRefunds(), 0);
        assertGt(handler.rateChanges(), 0);
        assertGt(handler.rejectedAdmissions(), 0);
        assertGt(handler.rejectedRefundReplays(), 0);
        assertGt(handler.rejectedRefundProofs(), 0);
        assertEq(controller.availableSwapTokens(), handler.modelTokens());
        assertEq(controller.swapTokensUpdatedAt(), handler.modelTokensAt());
    }

    function _shield(address account, uint256 amount) private {
        inputUnderlying.mint(account, amount);
        vm.startPrank(account);
        inputUnderlying.approve(address(gateway), amount);
        gateway.depositAndShield(address(inputUnderlying), amount, account);
        AlphaEngineFHERC20ERC20Wrapper(inputWrapper).setOperator(address(escrow), type(uint48).max);
        vm.stopPrank();
    }

    function _deployController() private returns (AlphaEngineConfidentialSwapController deployed) {
        AlphaEngineConfidentialSwapController implementation =
            new AlphaEngineConfidentialSwapController();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
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
        return AlphaEngineConfidentialSwapController(address(proxy));
    }

    function _deployEscrow() private returns (AlphaEngineConfidentialSwapEscrow deployed) {
        AlphaEngineConfidentialSwapEscrow implementation = new AlphaEngineConfidentialSwapEscrow();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapEscrow.initialize,
                (admin, pauser, address(controller), address(registry))
            )
        );
        return AlphaEngineConfidentialSwapEscrow(address(proxy));
    }
}
