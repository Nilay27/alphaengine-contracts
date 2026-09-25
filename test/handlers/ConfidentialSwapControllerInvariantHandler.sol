// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IAlphaEngineConfidentialSwapController
} from "src/interfaces/IAlphaEngineConfidentialSwapController.sol";
import {
    IAlphaEngineConfidentialSwapEscrow
} from "src/interfaces/IAlphaEngineConfidentialSwapEscrow.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";
import {
    AlphaEngineConfidentialSwapController
} from "src/swap/AlphaEngineConfidentialSwapController.sol";
import {AlphaEngineConfidentialSwapEscrow} from "src/swap/AlphaEngineConfidentialSwapEscrow.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";

import {FHE} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {
    IAlphaEngineConfidentialAssetRegistry
} from "src/interfaces/IAlphaEngineConfidentialAssetRegistry.sol";

contract ConfidentialSwapControllerInvariantHandler is MockCoFheTest {
    bytes32 internal constant ROUTE_KEY = keccak256("INVARIANT_EXACT_INPUT");

    struct IntentSnapshot {
        bytes32 intentId;
        address trader;
        uint64 inputAmount;
        uint256 outputAmount;
        bytes32 salt;
        bytes executionData;
        uint40 deadline;
        uint64 traderNonce;
        bytes32 payloadHash;
        bytes32 lockedAmountHandle;
        bytes32 unshieldRequestHandle;
        IAlphaEngineConfidentialSwapController.SwapIntentStatus expectedStatus;
    }

    error ExpectedFailureDidNotOccur(bytes4 expectedSelector);
    error UnexpectedFailureSelector(bytes4 expectedSelector, bytes4 actualSelector);
    error CoupledStateChanged(bytes32 intentId);

    AlphaEngineConfidentialSwapController public immutable CONTROLLER;
    AlphaEngineConfidentialSwapEscrow public immutable ESCROW;
    address public immutable INPUT_WRAPPER;
    address public immutable OUTPUT_WRAPPER;
    address public immutable OPERATOR;
    address public immutable TRADER_A;
    address public immutable TRADER_B;

    IntentSnapshot[] private _snapshots;
    mapping(address trader => uint64 count) public successfulSubmissions;
    uint256 public successfulExecutions;
    uint256 public successfulRefunds;
    uint256 public rejectedExecutionDataMutations;
    uint256 public rejectedMinimumOutputMutations;
    uint256 public rejectedReplays;
    uint256 public rejectedCooldowns;
    mapping(address => uint40) public expectedCooldownUntil;

    constructor(
        AlphaEngineConfidentialSwapController controller,
        AlphaEngineConfidentialSwapEscrow escrow,
        address inputWrapper,
        address outputWrapper,
        address operator,
        address traderA,
        address traderB
    ) {
        CONTROLLER = controller;
        ESCROW = escrow;
        INPUT_WRAPPER = inputWrapper;
        OUTPUT_WRAPPER = outputWrapper;
        OPERATOR = operator;
        TRADER_A = traderA;
        TRADER_B = traderB;
        _bindMockTaskManager();
    }

    function submitAsA(uint64 rawInput, uint256 rawOutput, bytes32 rawSalt) external {
        _submit(TRADER_A, rawInput, rawOutput, rawSalt);
    }

    function submitAsB(uint64 rawInput, uint256 rawOutput, bytes32 rawSalt) external {
        _submit(TRADER_B, rawInput, rawOutput, rawSalt);
    }

    function executeActive(uint256 seed) external {
        (bool found, uint256 index) = _findActive(seed, true, true);
        if (!found) return;

        IntentSnapshot storage snapshot = _snapshots[index];
        _publish(snapshot);
        vm.prank(OPERATOR);
        CONTROLLER.executeSwapIntent(
            snapshot.intentId,
            snapshot.inputAmount,
            snapshot.outputAmount,
            snapshot.salt,
            "",
            snapshot.executionData
        );
        snapshot.expectedStatus = IAlphaEngineConfidentialSwapController.SwapIntentStatus.Executed;
        successfulExecutions += 1;
    }

    function refundExpiredActive(uint256 seed) external {
        (bool found, uint256 index) = _findActive(seed, false, false);
        if (!found) return;

        IntentSnapshot storage snapshot = _snapshots[index];
        if (block.timestamp < snapshot.deadline) vm.warp(snapshot.deadline);
        _publish(snapshot);
        CONTROLLER.refundSwapIntent(snapshot.intentId, snapshot.inputAmount, "");
        snapshot.expectedStatus = IAlphaEngineConfidentialSwapController.SwapIntentStatus.Refunded;
        successfulRefunds += 1;
        if (snapshot.inputAmount == 0) {
            expectedCooldownUntil[snapshot.trader] = uint40(block.timestamp + 5 minutes);
        }
    }

    function rejectExecutionDataMutation(uint256 seed) external {
        (bool found, uint256 index) = _findActive(seed, true, true);
        if (!found) return;

        IntentSnapshot storage snapshot = _snapshots[index];
        bytes memory mutatedData = abi.encode(snapshot.outputAmount + 1);
        _publish(snapshot);
        _expectFailureAndUnchanged(
            snapshot,
            abi.encodeCall(
                CONTROLLER.executeSwapIntent,
                (
                    snapshot.intentId,
                    snapshot.inputAmount,
                    snapshot.outputAmount,
                    snapshot.salt,
                    "",
                    mutatedData
                )
            ),
            AlphaEngineConfidentialSwapController.ExecutionDataHashMismatch.selector,
            true
        );
        rejectedExecutionDataMutations += 1;
    }

    function rejectMinimumOutputMutation(uint256 seed) external {
        (bool found, uint256 index) = _findActive(seed, true, true);
        if (!found) return;

        IntentSnapshot storage snapshot = _snapshots[index];
        _publish(snapshot);
        _expectFailureAndUnchanged(
            snapshot,
            abi.encodeCall(
                CONTROLLER.executeSwapIntent,
                (
                    snapshot.intentId,
                    snapshot.inputAmount,
                    snapshot.outputAmount + 1,
                    snapshot.salt,
                    "",
                    snapshot.executionData
                )
            ),
            AlphaEngineConfidentialSwapController.MinimumOutputCommitmentMismatch.selector,
            true
        );
        rejectedMinimumOutputMutations += 1;
    }

    function rejectTerminalReplay(uint256 seed) external {
        (bool found, uint256 index) = _findTerminal(seed);
        if (!found) return;

        IntentSnapshot storage snapshot = _snapshots[index];
        _expectFailureAndUnchanged(
            snapshot,
            abi.encodeCall(
                CONTROLLER.executeSwapIntent,
                (
                    snapshot.intentId,
                    snapshot.inputAmount,
                    snapshot.outputAmount,
                    snapshot.salt,
                    "",
                    snapshot.executionData
                )
            ),
            AlphaEngineConfidentialSwapController.InvalidSwapIntentStatus.selector,
            true
        );
        rejectedReplays += 1;
    }

    function snapshotCount() external view returns (uint256) {
        return _snapshots.length;
    }

    function snapshotAt(uint256 index) external view returns (IntentSnapshot memory) {
        return _snapshots[index];
    }

    function _submit(address trader, uint64 rawInput, uint256 rawOutput, bytes32 rawSalt) private {
        if (CONTROLLER.activeSwapIntentOf(trader) != bytes32(0)) return;
        uint64 inputAmount = rawInput;
        uint256 outputAmount = bound(rawOutput, 1, 150e6);
        bytes32 salt = rawSalt == bytes32(0) ? bytes32(uint256(1)) : rawSalt;
        bytes memory executionData = abi.encode(outputAmount);
        uint64 traderNonce = CONTROLLER.traderNonces(trader);
        bytes32 intentId = CONTROLLER.computeSwapIntentId(trader, traderNonce);
        uint40 deadline = uint40(block.timestamp + 1 days);

        IAlphaEngineConfidentialSwapController.SwapIntentSubmission memory submission =
            IAlphaEngineConfidentialSwapController.SwapIntentSubmission({
                inputWrapper: INPUT_WRAPPER,
                outputWrapper: OUTPUT_WRAPPER,
                routeKey: ROUTE_KEY,
                executionDataHash: keccak256(executionData),
                minimumOutputCommitment: AlphaEngineExecutionHashLib.hashSwapMinimumOutput(
                        intentId, outputAmount, salt
                    ),
                encryptedInputAmount: createExternalEuint64(inputAmount, trader),
                inputProof: "",
                deadline: deadline
            });
        submission.inputProof = _inputProof(address(CONTROLLER), submission.encryptedInputAmount);

        if (block.timestamp < expectedCooldownUntil[trader]) {
            uint256 count = CONTROLLER.submittedSwapIntentCount();
            vm.prank(trader);
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineConfidentialSwapController.SwapCooldownActive.selector,
                    trader,
                    expectedCooldownUntil[trader]
                )
            );
            CONTROLLER.submitSwapIntent(submission);
            assertEq(CONTROLLER.submittedSwapIntentCount(), count);
            assertEq(CONTROLLER.traderNonces(trader), traderNonce);
            rejectedCooldowns += 1;
            return;
        }
        uint256 balance = mockStorage(
            uint256(
                FHE.unwrap(
                    AlphaEngineFHERC20ERC20Wrapper(INPUT_WRAPPER).confidentialBalanceOf(trader)
                )
            )
        );
        uint64 minimum = IAlphaEngineConfidentialAssetRegistry(ESCROW.assetRegistry())
            .minimumSwapInput(INPUT_WRAPPER);
        uint64 expectedAmount = inputAmount >= minimum && inputAmount <= balance ? inputAmount : 0;
        vm.prank(trader);
        bytes32 actualIntentId = CONTROLLER.submitSwapIntent(submission);
        assertEq(actualIntentId, intentId);
        IAlphaEngineConfidentialSwapController.SwapIntentRecord memory record =
            CONTROLLER.getSwapIntent(intentId);
        assertEq(mockStorage(uint256(record.lockedAmountHandle)), expectedAmount);
        assertEq(
            mockStorage(
                uint256(
                    FHE.unwrap(
                        AlphaEngineFHERC20ERC20Wrapper(INPUT_WRAPPER).confidentialBalanceOf(trader)
                    )
                )
            ),
            balance - expectedAmount
        );
        _snapshots.push(
            IntentSnapshot({
                intentId: intentId,
                trader: trader,
                inputAmount: uint64(mockStorage(uint256(record.lockedAmountHandle))),
                outputAmount: outputAmount,
                salt: salt,
                executionData: executionData,
                deadline: deadline,
                traderNonce: traderNonce,
                payloadHash: record.payloadHash,
                lockedAmountHandle: record.lockedAmountHandle,
                unshieldRequestHandle: record.unshieldRequestHandle,
                expectedStatus: IAlphaEngineConfidentialSwapController.SwapIntentStatus.Active
            })
        );
        successfulSubmissions[trader] += 1;
    }

    function _findActive(uint256 seed, bool requirePositive, bool requireUnexpired)
        private
        view
        returns (bool found, uint256 index)
    {
        uint256 count = _snapshots.length;
        if (count == 0) return (false, 0);
        uint256 start = seed % count;
        for (uint256 offset; offset < count; ++offset) {
            index = (start + offset) % count;
            IntentSnapshot storage snapshot = _snapshots[index];
            if (
                snapshot.expectedStatus
                        == IAlphaEngineConfidentialSwapController.SwapIntentStatus.Active
                    && (!requirePositive || snapshot.inputAmount != 0)
                    && (!requireUnexpired || snapshot.deadline > block.timestamp)
            ) return (true, index);
        }
        return (false, 0);
    }

    function _findTerminal(uint256 seed) private view returns (bool found, uint256 index) {
        uint256 count = _snapshots.length;
        if (count == 0) return (false, 0);
        uint256 start = seed % count;
        for (uint256 offset; offset < count; ++offset) {
            index = (start + offset) % count;
            if (
                _snapshots[index].expectedStatus
                    != IAlphaEngineConfidentialSwapController.SwapIntentStatus.Active
            ) return (true, index);
        }
        return (false, 0);
    }

    function _publish(IntentSnapshot storage snapshot) private {
        taskManager.publishDecryptResult(
            uint256(snapshot.unshieldRequestHandle), snapshot.inputAmount, ""
        );
    }

    function _expectFailureAndUnchanged(
        IntentSnapshot storage snapshot,
        bytes memory callData,
        bytes4 expectedSelector,
        bool asOperator
    ) private {
        IAlphaEngineConfidentialSwapController.SwapIntentStatus
            controllerStatusBefore = CONTROLLER.getSwapIntent(snapshot.intentId).status;
        IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus escrowStatusBefore =
        ESCROW.getSwapIntentLock(snapshot.intentId).status;
        uint256 liveCountBefore = ESCROW.liveSwapLockCount();

        if (asOperator) vm.prank(OPERATOR);
        (bool success, bytes memory revertData) = address(CONTROLLER).call(callData);
        if (success) revert ExpectedFailureDidNotOccur(expectedSelector);
        bytes4 actualSelector = _selector(revertData);
        if (actualSelector != expectedSelector) {
            revert UnexpectedFailureSelector(expectedSelector, actualSelector);
        }

        if (
            CONTROLLER.getSwapIntent(snapshot.intentId).status != controllerStatusBefore
                || ESCROW.getSwapIntentLock(snapshot.intentId).status != escrowStatusBefore
                || ESCROW.liveSwapLockCount() != liveCountBefore
        ) revert CoupledStateChanged(snapshot.intentId);
    }

    function _selector(bytes memory revertData) private pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
    }
}
