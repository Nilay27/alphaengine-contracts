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
        registry = new AlphaEngineConfidentialAssetRegistry(admin);
        gateway = new AlphaEngineConfidentialAssetGateway(registry);
        inputUnderlying = new MockERC20("Invariant Input", "IIN", 6);
        outputUnderlying = new MockERC20("Invariant Output", "IOUT", 6);
        vm.startPrank(admin);
        inputWrapper = registry.createWrapper(
            address(inputUnderlying), "Encrypted Invariant Input", "eIIN", ""
        );
        outputWrapper = registry.createWrapper(
            address(outputUnderlying), "Encrypted Invariant Output", "eIOUT", ""
        );
        vm.stopPrank();

        controller = _deployController();
        escrow = _deployEscrow();
        executor = new MockBoundSwapExecutor(address(escrow));
        vm.prank(admin);
        controller.setSwapConfiguration(address(escrow), address(executor));
        vm.prank(admin);
        escrow.unpause();
        vm.prank(admin);
        controller.unpause();

        _shield(traderA, 2000e6);
        _shield(traderB, 2000e6);

        handler = new ConfidentialSwapControllerInvariantHandler(
            controller, escrow, inputWrapper, outputWrapper, operator, traderA, traderB
        );

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.submitAsA.selector;
        selectors[1] = handler.submitAsB.selector;
        selectors[2] = handler.executeActive.selector;
        selectors[3] = handler.refundExpiredActive.selector;
        selectors[4] = handler.rejectExecutionDataMutation.selector;
        selectors[5] = handler.rejectMinimumOutputMutation.selector;
        selectors[6] = handler.rejectTerminalReplay.selector;
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
    }

    function invariant_nonceEqualsSuccessfulSubmissionsPerTrader() public view {
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
            assertEq(record.executor, address(executor));
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
                        executor: address(executor),
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
                assertEq(
                    uint8(escrowStatus),
                    uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested)
                );
            } else if (
                controllerStatus == IAlphaEngineConfidentialSwapController.SwapIntentStatus.Executed
            ) {
                assertEq(
                    uint8(escrowStatus),
                    uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Consumed)
                );
            } else {
                assertEq(
                    uint8(escrowStatus),
                    uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Refunded)
                );
            }
        }
        assertEq(escrow.liveSwapLockCount(), expectedLiveLocks);
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
