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

import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {MockCoFheTaskManager} from "test/mocks/MockCoFheTaskManager.sol";
import {MockBoundSwapExecutor} from "test/mocks/MockBoundSwapExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IFHERC20ERC20Wrapper
} from "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";

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
        address executor;
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

    address public immutable ORIGINAL_EXECUTOR;
    address public immutable ADMIN;
    address public immutable PAUSER;
    MockBoundSwapExecutor public immutable ALTERNATE_EXECUTOR;
    uint16 public modelRate = 2;
    uint16 public modelBurst = 24;
    uint16 public modelLimit = 120;
    uint16 public modelTokens = 24;
    uint40 public modelTokensAt;
    uint40[] private _submissionTimes;
    uint256 public configurationRotations;
    uint256 public pauseRefunds;
    uint256 public rateChanges;
    uint256 public rejectedAdmissions;
    uint256 public rejectedRefundReplays;
    uint256 public preclaims;
    uint256 public rejectedRefundProofs;
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
        address traderB,
        address admin,
        address pauser
    ) {
        CONTROLLER = controller;
        ESCROW = escrow;
        INPUT_WRAPPER = inputWrapper;
        OUTPUT_WRAPPER = outputWrapper;
        OPERATOR = operator;
        TRADER_A = traderA;
        TRADER_B = traderB;
        ORIGINAL_EXECUTOR = controller.swapExecutor();
        ADMIN = admin;
        PAUSER = pauser;
        modelTokensAt = uint40(block.timestamp);
        ALTERNATE_EXECUTOR = new MockBoundSwapExecutor(address(escrow));
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

    // SW-05/10: future dependency changes cannot replace pinned executor/payload of old records.
    function rotateFutureExecutor(uint256 seed) external {
        vm.prank(PAUSER);
        CONTROLLER.pause();
        address replacement = CONTROLLER.swapExecutor() == address(ALTERNATE_EXECUTOR)
            ? ORIGINAL_EXECUTOR
            : address(ALTERNATE_EXECUTOR);
        vm.prank(ADMIN);
        CONTROLLER.setSwapConfiguration(address(ESCROW), replacement);
        vm.prank(ADMIN);
        CONTROLLER.unpause();
        configurationRotations += 1;
        seed; // Sequence entropy is supplied by calls before/after this transition.
    }

    // SW-06/08: preclaim ordering and all pause domains retain the original recipient.
    function pausedPreclaimRefund(uint256 seed) external {
        (bool found, uint256 index) = _findActive(seed, false, false);
        if (!found) return;
        IntentSnapshot storage snapshot = _snapshots[index];
        _publish(snapshot);
        if (seed % 2 == 0) {
            bytes32 claimId = ESCROW.getSwapIntentLock(snapshot.intentId).unshieldClaimId;
            IFHERC20ERC20Wrapper(INPUT_WRAPPER).claimUnshielded(claimId, snapshot.inputAmount, "");
            preclaims += 1;
        }
        bool pauseController = seed % 3 != 1;
        bool pauseEscrow = seed % 3 != 0;
        if (pauseController) {
            vm.prank(PAUSER);
            CONTROLLER.pause();
        }
        if (pauseEscrow) {
            vm.prank(PAUSER);
            ESCROW.pause();
        }
        if (pauseController) {
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
                PausableUpgradeable.EnforcedPause.selector,
                true
            );
        }
        address thirdParty = address(0xFEED);
        vm.prank(thirdParty);
        CONTROLLER.refundSwapIntent(snapshot.intentId, snapshot.inputAmount, "");
        snapshot.expectedStatus = IAlphaEngineConfidentialSwapController.SwapIntentStatus.Refunded;
        if (snapshot.inputAmount == 0) {
            expectedCooldownUntil[snapshot.trader] = uint40(block.timestamp + 5 minutes);
        }
        assertEq(CONTROLLER.swapCooldownUntil(thirdParty), 0);
        if (pauseEscrow) {
            vm.prank(ADMIN);
            ESCROW.unpause();
        }
        if (pauseController) {
            vm.prank(ADMIN);
            CONTROLLER.unpause();
        }
        successfulRefunds += 1;
        pauseRefunds += 1;
    }

    // SW-09: governance deliberately resets the burst; the rolling minute history remains.
    function configureLimits(uint16 rawMinute, uint16 rawRate, uint16 rawBurst) external {
        modelLimit = uint16(bound(rawMinute, 1, 512));
        modelRate = uint16(bound(rawRate, 1, 16));
        modelBurst = uint16(bound(rawBurst, modelRate, 128));
        vm.prank(PAUSER);
        CONTROLLER.pause();
        vm.prank(ADMIN);
        CONTROLLER.setSwapRateLimits(modelLimit, modelRate, modelBurst);
        modelTokens = modelBurst;
        modelTokensAt = uint40(block.timestamp);
        vm.prank(ADMIN);
        CONTROLLER.unpause();
        rateChanges += 1;
    }

    function advanceTime(uint16 elapsed) external {
        vm.warp(block.timestamp + elapsed);
    }

    // SW-10: mutate the salt independently of the output; original record stays usable.
    // SW-08: a false zero/nonzero refund result cannot start someone else's
    // cooldown or mutate the live claim, even when early refunds are enabled.
    function rejectIncorrectRefundResult(uint256 seed) external {
        (bool found, uint256 index) = _findActive(seed, false, false);
        if (!found) return;
        IntentSnapshot storage snapshot = _snapshots[index];
        _publish(snapshot);
        uint64 wrong = snapshot.inputAmount == type(uint64).max
            ? snapshot.inputAmount - 1
            : snapshot.inputAmount + 1;
        vm.prank(PAUSER);
        CONTROLLER.pause();
        uint40 cooldown = CONTROLLER.swapCooldownUntil(snapshot.trader);
        _expectFailureAndUnchanged(
            snapshot,
            abi.encodeCall(CONTROLLER.refundSwapIntent, (snapshot.intentId, wrong, "")),
            MockCoFheTaskManager.InvalidDecryptResult.selector,
            false
        );
        assertEq(CONTROLLER.swapCooldownUntil(snapshot.trader), cooldown);
        vm.prank(ADMIN);
        CONTROLLER.unpause();
        rejectedRefundProofs += 1;
    }

    function rejectSaltMutation(uint256 seed) external {
        (bool found, uint256 index) = _findActive(seed, true, true);
        if (!found) return;
        IntentSnapshot storage snapshot = _snapshots[index];
        bytes32 mutated = bytes32(uint256(snapshot.salt) ^ 1);
        if (mutated == bytes32(0)) mutated = bytes32(uint256(2));
        _expectFailureAndUnchanged(
            snapshot,
            abi.encodeCall(
                CONTROLLER.executeSwapIntent,
                (
                    snapshot.intentId,
                    snapshot.inputAmount,
                    snapshot.outputAmount,
                    mutated,
                    "",
                    snapshot.executionData
                )
            ),
            AlphaEngineConfidentialSwapController.MinimumOutputCommitmentMismatch.selector,
            true
        );
        rejectedMinimumOutputMutations += 1;
    }

    // SW-12: refund replay must not clear a later active slot for the same wallet.
    function rejectTerminalRefundReplay(uint256 seed) external {
        (bool found, uint256 index) = _findTerminal(seed);
        if (!found) return;
        IntentSnapshot storage snapshot = _snapshots[index];
        _expectFailureAndUnchanged(
            snapshot,
            abi.encodeCall(
                CONTROLLER.refundSwapIntent, (snapshot.intentId, snapshot.inputAmount, "")
            ),
            AlphaEngineConfidentialSwapController.InvalidSwapIntentStatus.selector,
            false
        );
        rejectedRefundReplays += 1;
    }

    function _rejectAdmission(
        IAlphaEngineConfidentialSwapController.SwapIntentSubmission memory submission,
        address trader,
        uint64 nonce
    ) private returns (bool) {
        bytes memory expected;
        uint256 count = _submissionTimes.length;
        if (count >= modelLimit) {
            uint256 next = uint256(_submissionTimes[count - modelLimit]) + 60;
            if (block.timestamp < next) {
                expected = abi.encodeWithSelector(
                    AlphaEngineConfidentialSwapController.SwapIntentRateLimitExceeded.selector, next
                );
            }
        }
        uint256 credit = uint256(modelTokens) + (block.timestamp - modelTokensAt) * modelRate;
        if (expected.length == 0 && credit == 0) {
            expected = abi.encodeWithSelector(
                AlphaEngineConfidentialSwapController.SwapIntentBurstLimitExceeded.selector,
                block.timestamp + 1
            );
        }
        if (expected.length == 0) return false;
        uint256 countBefore = CONTROLLER.submittedSwapIntentCount();
        submission.inputProof = hex"ff"; // Admission failure must precede FHE proof processing.
        vm.expectRevert(expected);
        vm.prank(trader);
        CONTROLLER.submitSwapIntent(submission);
        assertEq(CONTROLLER.traderNonces(trader), nonce);
        assertEq(CONTROLLER.submittedSwapIntentCount(), countBefore);
        assertEq(CONTROLLER.availableSwapTokens(), modelTokens);
        assertEq(CONTROLLER.swapTokensUpdatedAt(), modelTokensAt);
        rejectedAdmissions += 1;
        return true;
    }

    function snapshotCount() external view returns (uint256) {
        return _snapshots.length;
    }

    function snapshotAt(uint256 index) external view returns (IntentSnapshot memory) {
        return _snapshots[index];
    }

    function _submit(address trader, uint64 rawInput, uint256 rawOutput, bytes32 rawSalt) private {
        if (CONTROLLER.activeSwapIntentOf(trader) != bytes32(0)) return;
        IntentSnapshot memory next;
        next.trader = trader;
        next.outputAmount = bound(rawOutput, 1, 150e6);
        next.salt = rawSalt == bytes32(0) ? bytes32(uint256(1)) : rawSalt;
        next.executionData = abi.encode(next.outputAmount);
        next.traderNonce = CONTROLLER.traderNonces(trader);
        next.intentId = CONTROLLER.computeSwapIntentId(trader, next.traderNonce);
        next.deadline = uint40(block.timestamp + 1 days);
        IAlphaEngineConfidentialSwapController.SwapIntentSubmission memory submission =
            _prepareSubmission(next, rawInput);
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
            assertEq(CONTROLLER.traderNonces(trader), next.traderNonce);
            rejectedCooldowns += 1;
            return;
        }
        if (_rejectAdmission(submission, trader, next.traderNonce)) return;
        uint256 balance = mockStorage(
            uint256(
                FHE.unwrap(
                    AlphaEngineFHERC20ERC20Wrapper(INPUT_WRAPPER).confidentialBalanceOf(trader)
                )
            )
        );
        uint64 minimum = IAlphaEngineConfidentialAssetRegistry(ESCROW.assetRegistry())
            .minimumSwapInput(INPUT_WRAPPER);
        uint64 expectedAmount = rawInput >= minimum && rawInput <= balance ? rawInput : 0;
        vm.prank(trader);
        assertEq(CONTROLLER.submitSwapIntent(submission), next.intentId);
        _recordSubmission(next, balance, expectedAmount);
    }

    function _prepareSubmission(IntentSnapshot memory next, uint64 amount)
        private
        returns (IAlphaEngineConfidentialSwapController.SwapIntentSubmission memory submission)
    {
        submission = IAlphaEngineConfidentialSwapController.SwapIntentSubmission({
            inputWrapper: INPUT_WRAPPER,
            outputWrapper: OUTPUT_WRAPPER,
            routeKey: ROUTE_KEY,
            executionDataHash: keccak256(next.executionData),
            minimumOutputCommitment: AlphaEngineExecutionHashLib.hashSwapMinimumOutput(
                    next.intentId, next.outputAmount, next.salt
                ),
            encryptedInputAmount: createExternalEuint64(amount, next.trader),
            inputProof: "",
            deadline: next.deadline
        });
        submission.inputProof = _inputProof(address(CONTROLLER), submission.encryptedInputAmount);
    }

    function _recordSubmission(IntentSnapshot memory next, uint256 balance, uint64 expectedAmount)
        private
    {
        IAlphaEngineConfidentialSwapController.SwapIntentRecord memory record =
            CONTROLLER.getSwapIntent(next.intentId);
        assertEq(mockStorage(uint256(record.lockedAmountHandle)), expectedAmount);
        assertEq(
            mockStorage(
                uint256(
                    FHE.unwrap(
                        AlphaEngineFHERC20ERC20Wrapper(INPUT_WRAPPER)
                            .confidentialBalanceOf(next.trader)
                    )
                )
            ),
            balance - expectedAmount
        );
        next.executor = record.executor;
        next.inputAmount = expectedAmount;
        next.payloadHash = record.payloadHash;
        next.lockedAmountHandle = record.lockedAmountHandle;
        next.unshieldRequestHandle = record.unshieldRequestHandle;
        next.expectedStatus = IAlphaEngineConfidentialSwapController.SwapIntentStatus.Active;
        _snapshots.push(next);
        successfulSubmissions[next.trader] += 1;
        uint256 credit = uint256(modelTokens) + (block.timestamp - modelTokensAt) * modelRate;
        modelTokens = uint16((credit > modelBurst ? modelBurst : credit) - 1);
        modelTokensAt = uint40(block.timestamp);
        _submissionTimes.push(uint40(block.timestamp));
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
        bytes32 activeBefore = CONTROLLER.activeSwapIntentOf(snapshot.trader);
        uint64 nonceBefore = CONTROLLER.traderNonces(snapshot.trader);
        bytes32 recordBefore = keccak256(abi.encode(CONTROLLER.getSwapIntent(snapshot.intentId)));
        bytes32 lockBefore = keccak256(abi.encode(ESCROW.getSwapIntentLock(snapshot.intentId)));
        bytes32 claimId = ESCROW.getSwapIntentLock(snapshot.intentId).unshieldClaimId;
        bytes32 claimBefore =
            keccak256(abi.encode(AlphaEngineFHERC20ERC20Wrapper(INPUT_WRAPPER).getClaim(claimId)));
        address input = IFHERC20ERC20Wrapper(INPUT_WRAPPER).underlying();
        address output = IFHERC20ERC20Wrapper(OUTPUT_WRAPPER).underlying();
        bytes32 balancesBefore = keccak256(
            abi.encode(
                IERC20(input).balanceOf(address(ESCROW)),
                IERC20(output).balanceOf(address(ESCROW)),
                IERC20(input).balanceOf(snapshot.executor),
                IERC20(output).balanceOf(snapshot.executor),
                IERC20(output).balanceOf(snapshot.trader)
            )
        );

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
        assertEq(
            keccak256(abi.encode(AlphaEngineFHERC20ERC20Wrapper(INPUT_WRAPPER).getClaim(claimId))),
            claimBefore
        );
        assertEq(CONTROLLER.activeSwapIntentOf(snapshot.trader), activeBefore);
        assertEq(CONTROLLER.traderNonces(snapshot.trader), nonceBefore);
        assertEq(keccak256(abi.encode(CONTROLLER.getSwapIntent(snapshot.intentId))), recordBefore);
        assertEq(keccak256(abi.encode(ESCROW.getSwapIntentLock(snapshot.intentId))), lockBefore);
        assertEq(
            keccak256(
                abi.encode(
                    IERC20(input).balanceOf(address(ESCROW)),
                    IERC20(output).balanceOf(address(ESCROW)),
                    IERC20(input).balanceOf(snapshot.executor),
                    IERC20(output).balanceOf(snapshot.executor),
                    IERC20(output).balanceOf(snapshot.trader)
                )
            ),
            balancesBefore
        );
    }

    function _selector(bytes memory revertData) private pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
    }
}
