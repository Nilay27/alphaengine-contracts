// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FHE, InEuint64, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC7984} from "fhenix-confidential-contracts/interfaces/IERC7984.sol";
import {IFHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockSwapExecutor} from "test/mocks/MockSwapExecutor.sol";

contract VaultInvariantHandler is MockCoFheTest {
    error UnexpectedLockSender(address caller, address expectedAccount);

    struct LockSnapshot {
        address account;
        address wrapper;
        bytes32 lockedAmountHandle;
        bytes32 unshieldRequestHandle;
        uint256 lockedValue;
        AlphaEngineConfidentialVault.SwapIntentLockStatus expectedStatus;
    }

    struct ClaimSnapshot {
        address account;
        bytes32 requestId;
        uint64 amount;
        bool vaultClaim;
        bool claimed;
    }

    AlphaEngineConfidentialVault public immutable VAULT;
    MockERC20 public immutable UNDERLYING;
    address public immutable WRAPPER;
    address public immutable OWNER;
    address public immutable USER_A;
    address public immutable USER_B;
    uint256 public immutable RATE;
    MockSwapExecutor public immutable EXECUTOR;

    mapping(address account => uint256 units) public shieldedDepositsByAccount;
    mapping(address account => uint256 units) public unshieldRequestedUnitsByAccount;
    uint256 public totalShieldedDeposits;
    uint256 public totalPendingUnshieldUnits;
    uint256 public vaultClaimedSwapUnshieldUnits;

    mapping(bytes32 intentId => bool known) public knownLock;
    mapping(bytes32 intentId => LockSnapshot snapshot) private _lockSnapshots;
    mapping(bytes32 requestId => ClaimSnapshot snapshot) private _claimSnapshots;
    bytes32[] private _lockIds;
    bytes32[] private _claimIds;
    uint256 private _nextIntentId;

    constructor(
        AlphaEngineConfidentialVault vault_,
        MockERC20 underlying_,
        address wrapper_,
        address owner_,
        address userA_,
        address userB_
    ) {
        _bindMockTaskManager();
        VAULT = vault_;
        UNDERLYING = underlying_;
        WRAPPER = wrapper_;
        OWNER = owner_;
        USER_A = userA_;
        USER_B = userB_;
        RATE = IFHERC20ERC20Wrapper(wrapper_).rate();
        EXECUTOR = new MockSwapExecutor();
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
        (bytes32 requestId, bool found) = _selectPendingClaim(rawIndex);
        if (!found) {
            return;
        }

        ClaimSnapshot storage snapshot = _claimSnapshots[requestId];
        taskManager.publishDecryptResult(uint256(requestId), snapshot.amount, "");

        try VAULT.claimUnshielded(WRAPPER, requestId, snapshot.amount, "") {
            snapshot.claimed = true;
            totalPendingUnshieldUnits -= snapshot.amount;
            if (snapshot.vaultClaim) {
                vaultClaimedSwapUnshieldUnits += snapshot.amount;
            }
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

        try VAULT.settleSwapIntent(
            intentId,
            address(EXECUTOR),
            WRAPPER,
            claimEntry.amount,
            claimEntry.amount * RATE,
            "",
            bytes("")
        ) returns (uint256 outputUnderlyingAmount, bytes32 shieldedOutputHandle) {
            assertEq(outputUnderlyingAmount, claimEntry.amount * RATE);
            assertTrue(shieldedOutputHandle != bytes32(0));
            lockEntry.expectedStatus = AlphaEngineConfidentialVault.SwapIntentLockStatus.Consumed;
            claimEntry.claimed = true;
            totalPendingUnshieldUnits -= claimEntry.amount;
            unshieldRequestedUnitsByAccount[claimEntry.account] -= claimEntry.amount;
        } catch {}
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

        lockedAmount = VAULT.lockForSwapIntent(intentId, account, WRAPPER, requestedAmount);
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
        uint256 availableUnderlying = UNDERLYING.balanceOf(account);
        if (availableUnderlying < RATE) {
            return;
        }

        uint256 maxAmount = _min(availableUnderlying, 1_000_000 * RATE);
        uint256 units = bound(uint256(rawAmount), 1, maxAmount / RATE);
        uint256 amount = units * RATE;

        vm.prank(account);
        try VAULT.depositAndShield(address(UNDERLYING), amount, account) returns (
            address returnedWrapper, euint64 shieldedAmount
        ) {
            assertEq(returnedWrapper, WRAPPER);
            uint256 shieldedUnits = _evalue(shieldedAmount);
            assertEq(shieldedUnits, units);
            shieldedDepositsByAccount[account] += shieldedUnits;
            totalShieldedDeposits += shieldedUnits;
        } catch {}
    }

    function _lock(address account, uint64 rawAmount) private {
        uint256 availableBalance = _confidentialBalance(account);
        if (availableBalance == 0) {
            return;
        }

        uint256 amount = bound(uint256(rawAmount), 1, _min(availableBalance, 1000));
        // forge-lint: disable-next-line(unsafe-typecast)
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

            knownLock[intentId] = true;
            _lockIds.push(intentId);
            _lockSnapshots[intentId] = LockSnapshot({
                account: account,
                wrapper: WRAPPER,
                lockedAmountHandle: lockedAmountHandle,
                unshieldRequestHandle: euint64.unwrap(
                    VAULT.getSwapIntentLock(intentId).unshieldRequestHandle
                ),
                lockedValue: lockedValue,
                expectedStatus: AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested
            });
            _claimIds.push(_lockSnapshots[intentId].unshieldRequestHandle);
            _claimSnapshots[_lockSnapshots[intentId].unshieldRequestHandle] = ClaimSnapshot({
                account: account,
                requestId: _lockSnapshots[intentId].unshieldRequestHandle,
                // forge-lint: disable-next-line(unsafe-typecast)
                amount: uint64(lockedValue),
                vaultClaim: true,
                claimed: false
            });
            unshieldRequestedUnitsByAccount[account] += lockedValue;
            totalPendingUnshieldUnits += lockedValue;
        } catch {}
    }

    function _requestUnshield(address account, uint64 rawAmount) private {
        uint256 availableBalance = _confidentialBalance(account);
        if (availableBalance == 0) {
            return;
        }

        uint256 amount = bound(uint256(rawAmount), 1, _min(availableBalance, 1000));

        vm.prank(account);
        // forge-lint: disable-next-line(unsafe-typecast)
        try VAULT.requestUnshield(WRAPPER, account, uint64(amount)) returns (euint64 unshieldHandle)
        {
            bytes32 requestId = euint64.unwrap(unshieldHandle);
            assertEq(_evalue(unshieldHandle), amount);

            _claimIds.push(requestId);
            _claimSnapshots[requestId] = ClaimSnapshot({
                account: account,
                requestId: requestId,
                // forge-lint: disable-next-line(unsafe-typecast)
                amount: uint64(amount),
                vaultClaim: false,
                claimed: false
            });
            unshieldRequestedUnitsByAccount[account] += amount;
            totalPendingUnshieldUnits += amount;
        } catch {}
    }

    function _selectPendingClaim(uint8 rawIndex)
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
            if (!_claimSnapshots[candidate].claimed) {
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
            LockSnapshot storage snapshot = _lockSnapshots[candidate];
            if (
                snapshot.expectedStatus
                    == AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested
                    && !_claimSnapshots[snapshot.unshieldRequestHandle].claimed
            ) {
                return (candidate, true);
            }
        }

        return (bytes32(0), false);
    }

    function _confidentialBalance(address account) private view returns (uint256) {
        return _evalue(IERC7984(WRAPPER).confidentialBalanceOf(account));
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
