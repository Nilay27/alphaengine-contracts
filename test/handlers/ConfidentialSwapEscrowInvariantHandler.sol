// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    ERC20ConfidentialLib
} from "fhenix-confidential-contracts/ERC20Confidential/ERC20ConfidentialLib.sol";

import {FHE, externalEuint64, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC7984} from "fhenix-confidential-contracts/interfaces/IERC7984.sol";
import {
    IFHERC20ERC20Wrapper
} from "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {
    AlphaEngineConfidentialAssetGateway
} from "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {AlphaEngineConfidentialSwapEscrow} from "src/swap/AlphaEngineConfidentialSwapEscrow.sol";
import {
    IAlphaEngineEncryptedUnshieldFHERC20Wrapper
} from "src/interfaces/IAlphaEngineEncryptedUnshieldFHERC20Wrapper.sol";
import {
    IAlphaEngineConfidentialSwapEscrow
} from "src/interfaces/IAlphaEngineConfidentialSwapEscrow.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockMintingSwapExecutor} from "test/mocks/MockMintingSwapExecutor.sol";

contract ConfidentialSwapEscrowInvariantHandler is MockCoFheTest {
    struct LockSnapshot {
        address account;
        bytes32 lockedAmountHandle;
        bytes32 unshieldRequestHandle;
        bytes32 unshieldClaimId;
        uint64 inputAmount;
        uint64 outputUnits;
        bool preclaimed;
        IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus expectedStatus;
        uint256 failedSettlementAttempts;
    }

    error EscrowAlreadyBound();
    error UnexpectedLockSender(address caller, address expectedAccount);

    AlphaEngineConfidentialAssetGateway public immutable GATEWAY;
    MockERC20 public immutable INPUT_UNDERLYING;
    MockERC20 public immutable OUTPUT_UNDERLYING;
    address public immutable INPUT_WRAPPER;
    address public immutable OUTPUT_WRAPPER;
    address public immutable USER_A;
    address public immutable USER_B;
    MockMintingSwapExecutor public immutable EXECUTOR;

    AlphaEngineConfidentialSwapEscrow public escrow;

    mapping(address account => uint256 units) public depositedUnitsByAccount;
    mapping(address account => uint256 units) public pendingUnitsByAccount;
    mapping(address account => uint256 units) public consumedInputUnitsByAccount;
    mapping(address account => uint256 units) public settledOutputUnitsByAccount;
    uint256 public totalUnclaimedPendingUnits;
    uint256 public totalPreclaimedUnderlying;

    uint256 public successfulDeposits;
    uint256 public successfulLocks;
    uint256 public successfulZeroLocks;
    uint256 public successfulPreclaims;
    uint256 public successfulSettlements;
    uint256 public successfulRefunds;
    uint256 public expectedSettlementReverts;

    mapping(bytes32 intentId => bool known) public knownLock;
    mapping(bytes32 intentId => LockSnapshot snapshot) private _lockSnapshots;
    bytes32[] private _lockIds;
    uint256 private _nextIntentId;

    constructor(
        AlphaEngineConfidentialAssetGateway gateway,
        MockERC20 inputUnderlying,
        address inputWrapper,
        MockERC20 outputUnderlying,
        address outputWrapper,
        address userA,
        address userB
    ) {
        _bindMockTaskManager();
        GATEWAY = gateway;
        INPUT_UNDERLYING = inputUnderlying;
        INPUT_WRAPPER = inputWrapper;
        OUTPUT_UNDERLYING = outputUnderlying;
        OUTPUT_WRAPPER = outputWrapper;
        USER_A = userA;
        USER_B = userB;
        EXECUTOR = new MockMintingSwapExecutor();
    }

    function bindEscrow(AlphaEngineConfidentialSwapEscrow escrow_) external {
        if (address(escrow) != address(0)) {
            revert EscrowAlreadyBound();
        }
        escrow = escrow_;
    }

    function depositAsA(uint96 rawAmount) external {
        _deposit(USER_A, rawAmount);
    }

    function depositAsB(uint96 rawAmount) external {
        _deposit(USER_B, rawAmount);
    }

    function lockAsA(uint64 rawAmount) external {
        _lock(USER_A, rawAmount);
    }

    function lockAsB(uint64 rawAmount) external {
        _lock(USER_B, rawAmount);
    }

    function overdrawLockAsA() external {
        _overdrawLock(USER_A);
    }

    function overdrawLockAsB() external {
        _overdrawLock(USER_B);
    }

    function settleLock(uint8 rawIndex) external {
        (bytes32 intentId, bool found) = _selectActiveLock(rawIndex, true, false);
        if (!found) {
            return;
        }

        LockSnapshot storage snapshot = _lockSnapshots[intentId];
        taskManager.publishDecryptResult(
            uint256(snapshot.unshieldRequestHandle), snapshot.inputAmount, ""
        );
        uint256 outputUnderlyingAmount = _quotedOutputUnderlying(snapshot.inputAmount);
        // The handler caps input units at 1e12, so the 3:2 quote is below uint64 max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 outputUnits =
            uint64(outputUnderlyingAmount / IFHERC20ERC20Wrapper(OUTPUT_WRAPPER).rate());

        (uint256 outputAmount, bytes32 shieldedOutputHandle) = escrow.settleSwapIntent(
            intentId,
            address(EXECUTOR),
            OUTPUT_WRAPPER,
            snapshot.inputAmount,
            outputUnderlyingAmount,
            "",
            abi.encode(outputUnderlyingAmount)
        );
        assertEq(outputAmount, outputUnderlyingAmount);
        assertEq(_evalue(euint64.wrap(shieldedOutputHandle)), outputUnits);

        _accountForClaimedInput(snapshot);
        snapshot.outputUnits = outputUnits;
        snapshot.expectedStatus = IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Consumed;
        pendingUnitsByAccount[snapshot.account] -= snapshot.inputAmount;
        consumedInputUnitsByAccount[snapshot.account] += snapshot.inputAmount;
        settledOutputUnitsByAccount[snapshot.account] += outputUnits;
        successfulSettlements += 1;
    }

    function refundLock(uint8 rawIndex) external {
        (bytes32 intentId, bool found) = _selectActiveLock(rawIndex, false, false);
        if (!found) {
            return;
        }

        LockSnapshot storage snapshot = _lockSnapshots[intentId];
        taskManager.publishDecryptResult(
            uint256(snapshot.unshieldRequestHandle), snapshot.inputAmount, ""
        );

        bytes32 refundedShieldedHandle = escrow.refundSwapIntent(intentId, snapshot.inputAmount, "");
        if (snapshot.inputAmount == 0) {
            assertEq(refundedShieldedHandle, bytes32(0));
        } else {
            assertEq(_evalue(euint64.wrap(refundedShieldedHandle)), snapshot.inputAmount);
        }

        _accountForClaimedInput(snapshot);
        snapshot.expectedStatus = IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Refunded;
        pendingUnitsByAccount[snapshot.account] -= snapshot.inputAmount;
        successfulRefunds += 1;
    }

    function preclaimLock(uint8 rawIndex) external {
        (bytes32 intentId, bool found) = _selectActiveLock(rawIndex, false, true);
        if (!found) {
            return;
        }

        LockSnapshot storage snapshot = _lockSnapshots[intentId];
        taskManager.publishDecryptResult(
            uint256(snapshot.unshieldRequestHandle), snapshot.inputAmount, ""
        );
        uint256 balanceBefore = INPUT_UNDERLYING.balanceOf(address(escrow));
        IFHERC20ERC20Wrapper(INPUT_WRAPPER)
            .claimUnshielded(snapshot.unshieldClaimId, snapshot.inputAmount, "");
        uint256 claimedUnderlying =
            uint256(snapshot.inputAmount) * IFHERC20ERC20Wrapper(INPUT_WRAPPER).rate();

        assertEq(INPUT_UNDERLYING.balanceOf(address(escrow)), balanceBefore + claimedUnderlying);
        snapshot.preclaimed = true;
        totalUnclaimedPendingUnits -= snapshot.inputAmount;
        totalPreclaimedUnderlying += claimedUnderlying;
        successfulPreclaims += 1;
    }

    function attemptUnderMinimumSettlement(uint8 rawIndex) external {
        (bytes32 intentId, bool found) = _selectActiveLock(rawIndex, true, false);
        if (!found) {
            return;
        }

        LockSnapshot storage snapshot = _lockSnapshots[intentId];
        taskManager.publishDecryptResult(
            uint256(snapshot.unshieldRequestHandle), snapshot.inputAmount, ""
        );

        IAlphaEngineConfidentialSwapEscrow.SwapIntentLock memory lockBefore =
            escrow.getSwapIntentLock(intentId);
        ERC20ConfidentialLib.Claim memory claimBefore = IAlphaEngineEncryptedUnshieldFHERC20Wrapper(
                INPUT_WRAPPER
            ).getClaim(snapshot.unshieldClaimId);
        uint256 liveCountBefore = escrow.liveSwapLockCount();
        uint256 escrowInputBefore = INPUT_UNDERLYING.balanceOf(address(escrow));
        uint256 executorInputBefore = INPUT_UNDERLYING.balanceOf(address(EXECUTOR));
        uint256 outputBalanceBefore = _confidentialBalance(OUTPUT_WRAPPER, snapshot.account);
        uint256 outputUnderlyingAmount = _quotedOutputUnderlying(snapshot.inputAmount);

        try escrow.settleSwapIntent(
            intentId,
            address(EXECUTOR),
            OUTPUT_WRAPPER,
            snapshot.inputAmount,
            outputUnderlyingAmount + 1,
            "",
            abi.encode(outputUnderlyingAmount)
        ) {
            fail();
        } catch (bytes memory reason) {
            assertGe(reason.length, 4);
            // The length check above proves the revert data contains a complete selector.
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(bytes4(reason), MockMintingSwapExecutor.OutputAmountBelowMinimum.selector);
            snapshot.failedSettlementAttempts += 1;
            expectedSettlementReverts += 1;
            assertEq(
                uint8(escrow.getSwapIntentLock(intentId).status),
                uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested)
            );
            assertEq(escrow.liveSwapLockCount(), liveCountBefore);
            assertEq(
                euint64.unwrap(escrow.getSwapIntentLock(intentId).lockedAmount),
                euint64.unwrap(lockBefore.lockedAmount)
            );
            assertEq(INPUT_UNDERLYING.balanceOf(address(escrow)), escrowInputBefore);
            assertEq(INPUT_UNDERLYING.balanceOf(address(EXECUTOR)), executorInputBefore);
            assertEq(_confidentialBalance(OUTPUT_WRAPPER, snapshot.account), outputBalanceBefore);
            ERC20ConfidentialLib.Claim memory claimAfter = IAlphaEngineEncryptedUnshieldFHERC20Wrapper(
                    INPUT_WRAPPER
                ).getClaim(snapshot.unshieldClaimId);
            assertEq(claimAfter.claimed, claimBefore.claimed);
        }
    }

    function lockWithInputForInvariant(
        bytes32 intentId,
        address account,
        externalEuint64 encryptedInput,
        bytes calldata inputProof
    ) external returns (euint64 lockedAmount) {
        if (msg.sender != account) {
            revert UnexpectedLockSender(msg.sender, account);
        }

        euint64 requestedAmount = FHE.asEuint64(encryptedInput, inputProof);
        FHE.allow(requestedAmount, address(escrow));
        return escrow.lockForSwapIntent(intentId, account, INPUT_WRAPPER, requestedAmount);
    }

    function lockIdsLength() external view returns (uint256) {
        return _lockIds.length;
    }

    function lockIdAt(uint256 index) external view returns (bytes32) {
        return _lockIds[index];
    }

    function lockSnapshot(bytes32 intentId) external view returns (LockSnapshot memory) {
        return _lockSnapshots[intentId];
    }

    function _deposit(address account, uint96 rawAmount) private {
        uint256 availableUnderlying = INPUT_UNDERLYING.balanceOf(account);
        if (availableUnderlying == 0) {
            return;
        }

        uint256 amount = bound(uint256(rawAmount), 1, _min(availableUnderlying, 1_000_000e6));
        vm.prank(account);
        (address returnedWrapper, euint64 shieldedAmount) =
            GATEWAY.depositAndShield(address(INPUT_UNDERLYING), amount, account);
        assertEq(returnedWrapper, INPUT_WRAPPER);
        assertEq(_evalue(shieldedAmount), amount);
        depositedUnitsByAccount[account] += amount;
        successfulDeposits += 1;
    }

    function _lock(address account, uint64 rawAmount) private {
        uint256 availableBalance = _confidentialBalance(INPUT_WRAPPER, account);
        if (availableBalance == 0) {
            return;
        }

        uint64 amount = uint64(bound(uint256(rawAmount), 1, _min(availableBalance, 1_000_000e6)));
        externalEuint64 encryptedInput = createExternalEuint64(amount, account);
        bytes32 intentId =
            keccak256(abi.encode("alphaengine.stage7.invariant.lock", _nextIntentId, account));
        _nextIntentId += 1;

        vm.prank(account);
        euint64 lockedAmount = this.lockWithInputForInvariant(
            intentId, account, encryptedInput, _inputProof(address(this), encryptedInput)
        );
        assertEq(_evalue(lockedAmount), amount);
        _recordLock(intentId, account, lockedAmount, amount);
        successfulLocks += 1;
    }

    function _overdrawLock(address account) private {
        uint256 availableBalance = _confidentialBalance(INPUT_WRAPPER, account);
        if (availableBalance >= type(uint64).max) {
            return;
        }

        // The preceding guard proves availableBalance + 1 fits in uint64.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 requestedAmount = uint64(availableBalance + 1);
        externalEuint64 encryptedInput = createExternalEuint64(requestedAmount, account);
        bytes32 intentId =
            keccak256(abi.encode("alphaengine.stage7.invariant.overdraw", _nextIntentId, account));
        _nextIntentId += 1;

        vm.prank(account);
        euint64 lockedAmount = this.lockWithInputForInvariant(
            intentId, account, encryptedInput, _inputProof(address(this), encryptedInput)
        );
        assertEq(_evalue(lockedAmount), 0);
        _recordLock(intentId, account, lockedAmount, 0);
        successfulZeroLocks += 1;
    }

    function _recordLock(bytes32 intentId, address account, euint64 lockedAmount, uint64 amount)
        private
    {
        IAlphaEngineConfidentialSwapEscrow.SwapIntentLock memory intentLock =
            escrow.getSwapIntentLock(intentId);
        assertFalse(knownLock[intentId]);

        knownLock[intentId] = true;
        _lockIds.push(intentId);
        _lockSnapshots[intentId] = LockSnapshot({
            account: account,
            lockedAmountHandle: euint64.unwrap(lockedAmount),
            unshieldRequestHandle: euint64.unwrap(intentLock.unshieldRequestHandle),
            unshieldClaimId: intentLock.unshieldClaimId,
            inputAmount: amount,
            outputUnits: 0,
            preclaimed: false,
            expectedStatus: IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus
                .UnshieldRequested,
            failedSettlementAttempts: 0
        });
        pendingUnitsByAccount[account] += amount;
        totalUnclaimedPendingUnits += amount;
    }

    function _accountForClaimedInput(LockSnapshot storage snapshot) private {
        if (snapshot.preclaimed) {
            totalPreclaimedUnderlying -= uint256(snapshot.inputAmount)
            * IFHERC20ERC20Wrapper(INPUT_WRAPPER).rate();
        } else {
            totalUnclaimedPendingUnits -= snapshot.inputAmount;
        }
    }

    function _selectActiveLock(uint8 rawIndex, bool positiveOnly, bool unclaimedOnly)
        private
        view
        returns (bytes32 intentId, bool found)
    {
        uint256 length = _lockIds.length;
        if (length == 0) {
            return (bytes32(0), false);
        }

        uint256 startIndex = bound(uint256(rawIndex), 0, length - 1);
        for (uint256 offset = 0; offset < length; ++offset) {
            bytes32 candidate = _lockIds[(startIndex + offset) % length];
            if (
                _lockSnapshots[candidate].expectedStatus
                        == IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested
                    && (!positiveOnly || _lockSnapshots[candidate].inputAmount != 0)
                    && (!unclaimedOnly || !_lockSnapshots[candidate].preclaimed)
            ) {
                return (candidate, true);
            }
        }
        return (bytes32(0), false);
    }

    function _confidentialBalance(address wrapper, address account) private view returns (uint256) {
        return _evalue(IERC7984(wrapper).confidentialBalanceOf(account));
    }

    function _evalue(euint64 encryptedValue) private view returns (uint256) {
        bytes32 handle = euint64.unwrap(encryptedValue);
        return handle == bytes32(0) ? 0 : mockStorage(uint256(handle));
    }

    function _quotedOutputUnderlying(uint64 inputUnits) private view returns (uint256) {
        uint256 outputUnits = (uint256(inputUnits) * 3) / 2;
        return outputUnits * IFHERC20ERC20Wrapper(OUTPUT_WRAPPER).rate();
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }
}
