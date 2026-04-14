// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FHE, InEuint64, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC7984} from "fhenix-confidential-contracts/interfaces/IERC7984.sol";
import {IFHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockMintingSwapExecutor} from "test/mocks/MockMintingSwapExecutor.sol";

contract VaultInvariantHandler is MockCoFheTest {
    error UnexpectedLockSender(address caller, address expectedAccount);

    struct LockSnapshot {
        address account;
        address wrapper;
        bytes32 lockedAmountHandle;
        bytes32 unshieldRequestHandle;
        uint256 lockedValue;
        AlphaEngineConfidentialVault.SwapIntentLockStatus expectedStatus;
        address outputWrapper;
        bytes32 outputShieldedHandle;
        uint256 outputUnderlyingAmount;
        uint256 outputConfidentialUnits;
        uint256 failedDustSettleAttempts;
    }

    struct ClaimSnapshot {
        address account;
        bytes32 requestId;
        uint64 amount;
        bool vaultClaim;
        bool claimed;
    }

    AlphaEngineConfidentialVault public immutable VAULT;
    MockERC20 public immutable INPUT_UNDERLYING;
    MockERC20 public immutable OUTPUT_UNDERLYING;
    address public immutable INPUT_WRAPPER;
    address public immutable OUTPUT_WRAPPER;
    address public immutable USER_A;
    address public immutable USER_B;
    uint256 public immutable INPUT_RATE;
    uint256 public immutable OUTPUT_RATE;
    MockMintingSwapExecutor public immutable EXECUTOR;

    mapping(address account => uint256 units) public inputDepositedUnitsByAccount;
    mapping(address account => uint256 units) public pendingInputUnshieldUnitsByAccount;
    mapping(address account => uint256 units) public claimedInputUnitsByAccount;
    mapping(address account => uint256 units) public outputCreditedUnitsByAccount;
    uint256 public totalPendingInputUnshieldUnits;

    mapping(bytes32 intentId => bool known) public knownLock;
    mapping(bytes32 intentId => LockSnapshot snapshot) private _lockSnapshots;
    mapping(bytes32 requestId => ClaimSnapshot snapshot) private _claimSnapshots;
    bytes32[] private _lockIds;
    bytes32[] private _claimIds;
    uint256 private _nextIntentId;

    constructor(
        AlphaEngineConfidentialVault vault_,
        MockERC20 inputUnderlying_,
        address inputWrapper_,
        MockERC20 outputUnderlying_,
        address outputWrapper_,
        address userA_,
        address userB_
    ) {
        _bindMockTaskManager();
        VAULT = vault_;
        INPUT_UNDERLYING = inputUnderlying_;
        OUTPUT_UNDERLYING = outputUnderlying_;
        INPUT_WRAPPER = inputWrapper_;
        OUTPUT_WRAPPER = outputWrapper_;
        USER_A = userA_;
        USER_B = userB_;
        INPUT_RATE = IFHERC20ERC20Wrapper(inputWrapper_).rate();
        OUTPUT_RATE = IFHERC20ERC20Wrapper(outputWrapper_).rate();
        EXECUTOR = new MockMintingSwapExecutor();
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

    function requestUnshieldAsA(uint64 rawAmount) external {
        _requestUnshield(USER_A, rawAmount);
    }

    function requestUnshieldAsB(uint64 rawAmount) external {
        _requestUnshield(USER_B, rawAmount);
    }

    function claimUnshield(uint8 rawIndex) external {
        (bytes32 requestId, bool found) = _selectPendingUserClaim(rawIndex);
        if (!found) {
            return;
        }

        ClaimSnapshot storage claimEntry = _claimSnapshots[requestId];
        taskManager.publishDecryptResult(uint256(requestId), claimEntry.amount, "");

        uint256 accountBalanceBefore = INPUT_UNDERLYING.balanceOf(claimEntry.account);
        try VAULT.claimUnshielded(INPUT_WRAPPER, requestId, claimEntry.amount, "") {
            claimEntry.claimed = true;
            totalPendingInputUnshieldUnits -= claimEntry.amount;
            pendingInputUnshieldUnitsByAccount[claimEntry.account] -= claimEntry.amount;
            claimedInputUnitsByAccount[claimEntry.account] += claimEntry.amount;
            assertEq(
                INPUT_UNDERLYING.balanceOf(claimEntry.account) - accountBalanceBefore,
                uint256(claimEntry.amount) * INPUT_RATE
            );
        } catch {}
    }

    function settleLock(uint8 rawIndex) external {
        (bytes32 intentId, bool found) = _selectSettleableLock(rawIndex);
        if (!found) {
            return;
        }

        LockSnapshot storage lockEntry = _lockSnapshots[intentId];
        ClaimSnapshot storage claimEntry = _claimSnapshots[lockEntry.unshieldRequestHandle];
        taskManager.publishDecryptResult(
            uint256(lockEntry.unshieldRequestHandle), claimEntry.amount, ""
        );

        uint256 outputUnderlyingAmount = uint256(claimEntry.amount) * OUTPUT_RATE;
        try VAULT.settleSwapIntent(
            intentId,
            address(EXECUTOR),
            OUTPUT_WRAPPER,
            claimEntry.amount,
            outputUnderlyingAmount,
            "",
            abi.encode(outputUnderlyingAmount)
        ) returns (uint256 returnedOutputUnderlyingAmount, bytes32 shieldedOutputHandle) {
            assertEq(returnedOutputUnderlyingAmount, outputUnderlyingAmount);
            assertTrue(shieldedOutputHandle != bytes32(0));

            lockEntry.expectedStatus = AlphaEngineConfidentialVault.SwapIntentLockStatus.Consumed;
            lockEntry.outputWrapper = OUTPUT_WRAPPER;
            lockEntry.outputShieldedHandle = shieldedOutputHandle;
            lockEntry.outputUnderlyingAmount = returnedOutputUnderlyingAmount;
            lockEntry.outputConfidentialUnits = returnedOutputUnderlyingAmount / OUTPUT_RATE;

            claimEntry.claimed = true;
            totalPendingInputUnshieldUnits -= claimEntry.amount;
            pendingInputUnshieldUnitsByAccount[claimEntry.account] -= claimEntry.amount;
            outputCreditedUnitsByAccount[claimEntry.account] += lockEntry.outputConfidentialUnits;

            assertEq(
                lockEntry.outputUnderlyingAmount, lockEntry.outputConfidentialUnits * OUTPUT_RATE
            );
            assertEq(_evalue(euint64.wrap(shieldedOutputHandle)), lockEntry.outputConfidentialUnits);
            assertEq(INPUT_UNDERLYING.balanceOf(address(VAULT)), 0);
            assertEq(OUTPUT_UNDERLYING.balanceOf(address(VAULT)), 0);
            assertEq(INPUT_UNDERLYING.balanceOf(address(EXECUTOR)), 0);
            assertEq(OUTPUT_UNDERLYING.balanceOf(address(EXECUTOR)), 0);
        } catch {}
    }

    function attemptDustSettle(uint8 rawIndex) external {
        (bytes32 intentId, bool found) = _selectSettleableLock(rawIndex);
        if (!found) {
            return;
        }

        LockSnapshot storage lockEntry = _lockSnapshots[intentId];
        ClaimSnapshot storage claimEntry = _claimSnapshots[lockEntry.unshieldRequestHandle];
        taskManager.publishDecryptResult(
            uint256(lockEntry.unshieldRequestHandle), claimEntry.amount, ""
        );

        uint256 dustOutputAmount = uint256(claimEntry.amount) * OUTPUT_RATE - 1;
        AlphaEngineConfidentialVault.SwapIntentLock memory lockBefore =
            VAULT.getSwapIntentLock(intentId);
        uint256 outputSupplyBefore = _confidentialTotalSupply(OUTPUT_WRAPPER);
        uint256 userOutputBalanceBefore = _confidentialBalance(OUTPUT_WRAPPER, lockEntry.account);
        uint256 inputVaultBalanceBefore = INPUT_UNDERLYING.balanceOf(address(VAULT));
        uint256 outputVaultBalanceBefore = OUTPUT_UNDERLYING.balanceOf(address(VAULT));
        uint256 inputExecutorBalanceBefore = INPUT_UNDERLYING.balanceOf(address(EXECUTOR));
        uint256 outputExecutorBalanceBefore = OUTPUT_UNDERLYING.balanceOf(address(EXECUTOR));

        try VAULT.settleSwapIntent(
            intentId,
            address(EXECUTOR),
            OUTPUT_WRAPPER,
            claimEntry.amount,
            dustOutputAmount,
            "",
            abi.encode(dustOutputAmount)
        ) {
            fail();
        } catch {
            lockEntry.failedDustSettleAttempts += 1;

            AlphaEngineConfidentialVault.SwapIntentLock memory lockAfter =
                VAULT.getSwapIntentLock(intentId);
            assertEq(uint8(lockAfter.status), uint8(lockBefore.status));
            assertEq(
                euint64.unwrap(lockAfter.lockedAmount), euint64.unwrap(lockBefore.lockedAmount)
            );
            assertEq(
                euint64.unwrap(lockAfter.unshieldRequestHandle),
                euint64.unwrap(lockBefore.unshieldRequestHandle)
            );
            assertFalse(_claimSnapshots[lockEntry.unshieldRequestHandle].claimed);
            assertEq(lockEntry.outputShieldedHandle, bytes32(0));
            assertEq(lockEntry.outputUnderlyingAmount, 0);
            assertEq(lockEntry.outputConfidentialUnits, 0);
            assertEq(_confidentialTotalSupply(OUTPUT_WRAPPER), outputSupplyBefore);
            assertEq(
                _confidentialBalance(OUTPUT_WRAPPER, lockEntry.account), userOutputBalanceBefore
            );
            assertEq(INPUT_UNDERLYING.balanceOf(address(VAULT)), inputVaultBalanceBefore);
            assertEq(OUTPUT_UNDERLYING.balanceOf(address(VAULT)), outputVaultBalanceBefore);
            assertEq(INPUT_UNDERLYING.balanceOf(address(EXECUTOR)), inputExecutorBalanceBefore);
            assertEq(OUTPUT_UNDERLYING.balanceOf(address(EXECUTOR)), outputExecutorBalanceBefore);
        }
    }

    function lockWithInputForInvariant(bytes32 intentId, address account, InEuint64 calldata input)
        external
        returns (euint64 lockedAmount)
    {
        if (msg.sender != account) {
            revert UnexpectedLockSender(msg.sender, account);
        }

        euint64 requestedAmount = FHE.asEuint64(input);
        FHE.allow(requestedAmount, address(VAULT));

        lockedAmount = VAULT.lockForSwapIntent(intentId, account, INPUT_WRAPPER, requestedAmount);
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

    function claimIdsLength() external view returns (uint256) {
        return _claimIds.length;
    }

    function claimIdAt(uint256 index) external view returns (bytes32) {
        return _claimIds[index];
    }

    function claimSnapshot(bytes32 requestId) external view returns (ClaimSnapshot memory) {
        return _claimSnapshots[requestId];
    }

    function _deposit(address account, uint96 rawAmount) private {
        uint256 availableUnderlying = INPUT_UNDERLYING.balanceOf(account);
        if (availableUnderlying < INPUT_RATE) {
            return;
        }

        uint256 maxAmount = _min(availableUnderlying, 1_000_000 * INPUT_RATE);
        uint256 units = bound(uint256(rawAmount), 1, maxAmount / INPUT_RATE);
        uint256 amount = units * INPUT_RATE;

        vm.prank(account);
        try VAULT.depositAndShield(address(INPUT_UNDERLYING), amount, account) returns (
            address returnedWrapper, euint64 shieldedAmount
        ) {
            assertEq(returnedWrapper, INPUT_WRAPPER);
            uint256 shieldedUnits = _evalue(shieldedAmount);
            assertEq(shieldedUnits, units);
            inputDepositedUnitsByAccount[account] += shieldedUnits;
        } catch {}
    }

    function _lock(address account, uint64 rawAmount) private {
        uint256 availableBalance = _confidentialBalance(INPUT_WRAPPER, account);
        if (availableBalance == 0) {
            return;
        }

        uint256 amount = bound(uint256(rawAmount), 1, _min(availableBalance, 1000));
        InEuint64 memory input = createInEuint64(uint64(amount), account);

        bytes32 intentId =
            keccak256(abi.encode("alphaengine.vault.invariant.lock", _nextIntentId, account));
        _nextIntentId += 1;

        vm.prank(account);
        try this.lockWithInputForInvariant(intentId, account, input) returns (euint64 lockedAmount)
        {
            bytes32 lockedAmountHandle = euint64.unwrap(lockedAmount);
            uint256 lockedValue = _evalue(lockedAmount);
            assertEq(lockedValue, amount);
            assertFalse(knownLock[intentId], "duplicate vault lock");

            AlphaEngineConfidentialVault.SwapIntentLock memory intentLock =
                VAULT.getSwapIntentLock(intentId);

            knownLock[intentId] = true;
            _lockIds.push(intentId);
            _lockSnapshots[intentId] = LockSnapshot({
                account: account,
                wrapper: INPUT_WRAPPER,
                lockedAmountHandle: lockedAmountHandle,
                unshieldRequestHandle: euint64.unwrap(intentLock.unshieldRequestHandle),
                lockedValue: lockedValue,
                expectedStatus: AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested,
                outputWrapper: address(0),
                outputShieldedHandle: bytes32(0),
                outputUnderlyingAmount: 0,
                outputConfidentialUnits: 0,
                failedDustSettleAttempts: 0
            });
            _claimIds.push(_lockSnapshots[intentId].unshieldRequestHandle);
            _claimSnapshots[_lockSnapshots[intentId].unshieldRequestHandle] = ClaimSnapshot({
                account: account,
                requestId: _lockSnapshots[intentId].unshieldRequestHandle,
                amount: uint64(lockedValue),
                vaultClaim: true,
                claimed: false
            });
            pendingInputUnshieldUnitsByAccount[account] += lockedValue;
            totalPendingInputUnshieldUnits += lockedValue;
        } catch {}
    }

    function _requestUnshield(address account, uint64 rawAmount) private {
        uint256 availableBalance = _confidentialBalance(INPUT_WRAPPER, account);
        if (availableBalance == 0) {
            return;
        }

        uint256 amount = bound(uint256(rawAmount), 1, _min(availableBalance, 1000));

        vm.prank(account);
        try VAULT.requestUnshield(INPUT_WRAPPER, account, uint64(amount)) returns (
            euint64 unshieldHandle
        ) {
            bytes32 requestId = euint64.unwrap(unshieldHandle);
            assertEq(_evalue(unshieldHandle), amount);

            _claimIds.push(requestId);
            _claimSnapshots[requestId] = ClaimSnapshot({
                account: account,
                requestId: requestId,
                amount: uint64(amount),
                vaultClaim: false,
                claimed: false
            });
            pendingInputUnshieldUnitsByAccount[account] += amount;
            totalPendingInputUnshieldUnits += amount;
        } catch {}
    }

    function _selectPendingUserClaim(uint8 rawIndex)
        private
        view
        returns (bytes32 requestId, bool found)
    {
        uint256 length = _claimIds.length;
        if (length == 0) {
            return (bytes32(0), false);
        }

        uint256 startIndex = bound(uint256(rawIndex), 0, length - 1);
        for (uint256 offset = 0; offset < length; ++offset) {
            bytes32 candidate = _claimIds[(startIndex + offset) % length];
            ClaimSnapshot storage claimEntry = _claimSnapshots[candidate];
            if (!claimEntry.claimed && !claimEntry.vaultClaim) {
                return (candidate, true);
            }
        }

        return (bytes32(0), false);
    }

    function _selectSettleableLock(uint8 rawIndex)
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
            LockSnapshot storage lockEntry = _lockSnapshots[candidate];
            if (
                lockEntry.expectedStatus
                    == AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested
                    && !_claimSnapshots[lockEntry.unshieldRequestHandle].claimed
            ) {
                return (candidate, true);
            }
        }

        return (bytes32(0), false);
    }

    function _confidentialBalance(address wrapper, address account)
        private
        view
        returns (uint256)
    {
        return _evalue(IERC7984(wrapper).confidentialBalanceOf(account));
    }

    function _confidentialTotalSupply(address wrapper) private view returns (uint256) {
        return _evalue(IERC7984(wrapper).confidentialTotalSupply());
    }

    function _evalue(euint64 encryptedValue) private view returns (uint256) {
        bytes32 handle = euint64.unwrap(encryptedValue);
        if (handle == bytes32(0)) {
            return 0;
        }

        return mockStorage(uint256(handle));
    }

    function _min(uint256 lhs, uint256 rhs) private pure returns (uint256) {
        return lhs < rhs ? lhs : rhs;
    }
}
