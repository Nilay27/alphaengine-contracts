// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    ERC20ConfidentialLib
} from "fhenix-confidential-contracts/ERC20Confidential/ERC20ConfidentialLib.sol";

import {
    FHE,
    externalEuint64,
    euint64,
    sharedEuint64
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
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
import {MockERC20, MockSelectiveFeeERC20} from "test/mocks/MockERC20.sol";
import {FHERC20ZeroBalance} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20Errors.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {
    AlphaEngineConfidentialAssetRegistry
} from "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {MockMintingSwapExecutor} from "test/mocks/MockMintingSwapExecutor.sol";
import {AssetRegistryV2, AssetGatewayV2, AssetWrapperV2} from "test/mocks/MockAssetUpgrade.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

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
    uint256 public successfulAssetUpgrades;
    uint256 public governanceAttempts;
    uint256 public governanceProgress;
    uint256 public pausedRefunds;
    uint256 public injectedExecutorFailures;
    uint256 public injectedShieldFailures;
    uint256 public terminalReplays;
    uint256 public rejectedUninitialized;
    mapping(address => bytes32) public ordinaryPending;
    mapping(address => uint64) public ordinaryAmounts;
    mapping(address => uint40) public ordinaryCooldowns;
    mapping(address => uint256) public ordinaryPaid;
    uint256 public ordinaryRequests;
    uint256 public ordinaryClaims;
    uint256 public ordinaryRejected;
    uint256 public ordinaryPolicyUpdates;
    uint256 public drainedLiveLocks;
    RegistryBoundEscrowProbe private immutable _replacementEscrow;
    FailingLifecycleExecutor private immutable _failingExecutor;
    AlphaEngineConfidentialAssetRegistry private immutable _alternateRegistry;
    address[4] private _assetImplementations;

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
        _failingExecutor = new FailingLifecycleExecutor();
        _replacementEscrow = new RegistryBoundEscrowProbe(gateway.assetRegistry());
        _alternateRegistry = _deployAssetRegistry(address(this));
        _assetImplementations = [
            address(new AssetRegistryV2()),
            address(new AssetGatewayV2()),
            address(new AssetWrapperV2()),
            address(new AssetWrapperV2())
        ];
    }

    function upgradeAsset(uint8 seed) external {
        address[4] memory proxies =
            [GATEWAY.assetRegistry(), address(GATEWAY), INPUT_WRAPPER, OUTPUT_WRAPPER];
        uint256 i = seed % 4;
        ProxyAdmin proxyAdmin = ProxyAdmin(
            address(
                uint160(
                    uint256(
                        vm.load(
                            proxies[i],
                            0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
                        )
                    )
                )
            )
        );
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(proxies[i]), _assetImplementations[i], ""
        );
        successfulAssetUpgrades += 1;
    }

    // SW-02: dependency-uninitialized differs from an initialized encrypted zero.
    function rejectUninitializedLock(uint256 seed) external {
        address empty = address(uint160(0xF0000 + seed % 100));
        vm.prank(empty);
        AlphaEngineFHERC20ERC20Wrapper(INPUT_WRAPPER).setOperator(address(escrow), type(uint48).max);
        externalEuint64 amount = createExternalEuint64(1, empty);
        bytes32 id = keccak256(abi.encode("uninitialized", seed, _nextIntentId));
        uint256 liveBefore = escrow.liveSwapLockCount();
        vm.prank(empty);
        vm.expectRevert(abi.encodeWithSelector(FHERC20ZeroBalance.selector, empty));
        this.lockWithInputForInvariant(id, empty, amount, _inputProof(address(this), amount));
        assertEq(escrow.liveSwapLockCount(), liveBefore);
        assertFalse(escrow.existsSwapIntentLock(id));
        rejectedUninitialized += 1;
    }

    // SW-07/AS-11: all three governance pointers reject live locks; after the
    // final lock clears, changes and restoration succeed without altering history.
    function rotateAfterDrainOrReject(uint256 seed) external {
        escrow.pause();
        uint256 live = escrow.liveSwapLockCount();
        address admin = escrow.defaultAdmin();
        AlphaEngineConfidentialAssetRegistry registry =
            AlphaEngineConfidentialAssetRegistry(GATEWAY.assetRegistry());
        address registryOwner = registry.owner();
        if (live != 0) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineConfidentialSwapEscrow.ActiveSwapLocksPresent.selector, live
                )
            );
            vm.prank(admin);
            escrow.setSwapController(address(_failingExecutor));
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineConfidentialSwapEscrow.ActiveSwapLocksPresent.selector, live
                )
            );
            vm.prank(admin);
            escrow.setAssetRegistry(address(_alternateRegistry));
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineConfidentialAssetRegistry.ActiveSwapLocksPresent.selector, live
                )
            );
            vm.prank(registryOwner);
            registry.setTrustedSwapEscrow(address(_replacementEscrow));
        } else {
            vm.prank(admin);
            escrow.setSwapController(address(_failingExecutor));
            vm.prank(admin);
            escrow.setSwapController(address(this));
            vm.prank(admin);
            escrow.setAssetRegistry(address(_alternateRegistry));
            vm.prank(admin);
            escrow.setAssetRegistry(address(registry));
            vm.prank(registryOwner);
            registry.setTrustedSwapEscrow(address(_replacementEscrow));
            vm.prank(registryOwner);
            registry.setTrustedSwapEscrow(address(escrow));
            governanceProgress += 1;
        }
        vm.prank(admin);
        escrow.unpause();
        governanceAttempts += 1;
        seed;
    }

    // SW-06: a preclaimed lock still refunds while new risk-taking is paused.
    function pauseAndRefund(uint8 rawIndex) external {
        (bytes32 id, bool found) = _selectActiveLock(rawIndex, false, false);
        if (!found) return;
        escrow.pause();
        LockSnapshot storage snapshot = _lockSnapshots[id];
        if (snapshot.inputAmount != 0) {
            _expectAtomicFailure(
                id,
                abi.encodeCall(
                    escrow.settleSwapIntent,
                    (
                        id,
                        address(EXECUTOR),
                        OUTPUT_WRAPPER,
                        snapshot.inputAmount,
                        uint256(1),
                        "",
                        abi.encode(uint256(1))
                    )
                ),
                PausableUpgradeable.EnforcedPause.selector
            );
        }
        this.refundLock(rawIndex);
        vm.prank(escrow.defaultAdmin());
        escrow.unpause();
        pausedRefunds += 1;
    }

    // SW-11: failure after claim/transfer cannot consume the lock or an approval.
    function failExecutorThenRetry(uint8 rawIndex) external {
        (bytes32 id, bool found) = _selectActiveLock(rawIndex, true, false);
        if (!found) return;
        LockSnapshot storage snapshot = _lockSnapshots[id];
        taskManager.publishDecryptResult(
            uint256(snapshot.unshieldRequestHandle), snapshot.inputAmount, ""
        );
        _expectAtomicFailure(
            id,
            abi.encodeCall(
                escrow.settleSwapIntent,
                (
                    id,
                    address(_failingExecutor),
                    OUTPUT_WRAPPER,
                    snapshot.inputAmount,
                    uint256(1),
                    "",
                    ""
                )
            ),
            FailingLifecycleExecutor.ForcedExecutorFailure.selector
        );
        injectedExecutorFailures += 1;
    }

    function failOutputShieldThenRetry(uint8 rawIndex) external {
        (bytes32 id, bool found) = _selectActiveLock(rawIndex, true, false);
        if (!found) return;
        LockSnapshot storage snapshot = _lockSnapshots[id];
        uint256 output = _quotedOutputUnderlying(snapshot.inputAmount);
        if (output <= 1) return; // A fee of one unit requires a larger transfer.
        taskManager.publishDecryptResult(
            uint256(snapshot.unshieldRequestHandle), snapshot.inputAmount, ""
        );
        MockSelectiveFeeERC20(address(OUTPUT_UNDERLYING))
            .setFeeRoute(address(escrow), OUTPUT_WRAPPER);
        _expectAtomicFailure(
            id,
            abi.encodeCall(
                escrow.settleSwapIntent,
                (
                    id,
                    address(EXECUTOR),
                    OUTPUT_WRAPPER,
                    snapshot.inputAmount,
                    uint256(1),
                    "",
                    abi.encode(output)
                )
            ),
            AlphaEngineConfidentialSwapEscrow.UnexpectedUnderlyingBalance.selector
        );
        MockSelectiveFeeERC20(address(OUTPUT_UNDERLYING)).setFeeRoute(address(0), address(0));
        injectedShieldFailures += 1;
    }

    // SW-12: terminal consumption/refund cannot revive another pending record.
    function rejectTerminalOperations(uint8 rawIndex) external {
        if (_lockIds.length == 0) return;
        bytes32 id = _lockIds[rawIndex % _lockIds.length];
        LockSnapshot storage snapshot = _lockSnapshots[id];
        if (
            snapshot.expectedStatus
                == IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested
        ) return;
        _expectAtomicFailure(
            id,
            abi.encodeCall(escrow.refundSwapIntent, (id, snapshot.inputAmount, "")),
            AlphaEngineConfidentialSwapEscrow.SwapIntentLockNotActive.selector
        );
        if (snapshot.inputAmount != 0) {
            _expectAtomicFailure(
                id,
                abi.encodeCall(
                    escrow.settleSwapIntent,
                    (
                        id,
                        address(EXECUTOR),
                        OUTPUT_WRAPPER,
                        snapshot.inputAmount,
                        uint256(1),
                        "",
                        abi.encode(uint256(1))
                    )
                ),
                AlphaEngineConfidentialSwapEscrow.SwapIntentLockNotActive.selector
            );
        }
        terminalReplays += 1;
    }

    // SW-18: verify actual role ACLs, not only that a mocked operation succeeds.
    function assertAssetPermissions() public view {
        address[2] memory users = [USER_A, USER_B];
        for (uint256 u; u < 2; ++u) {
            AlphaEngineFHERC20ERC20Wrapper wrapper = AlphaEngineFHERC20ERC20Wrapper(INPUT_WRAPPER);
            assertEq(wrapper.pendingUnshieldClaimId(users[u]), ordinaryPending[users[u]]);
            assertEq(wrapper.unshieldCooldownUntil(users[u]), ordinaryCooldowns[users[u]]);
            if (ordinaryPending[users[u]] != bytes32(0)) {
                ERC20ConfidentialLib.Claim memory claim =
                    wrapper.getClaim(ordinaryPending[users[u]]);
                assertEq(claim.to, users[u]);
                assertFalse(claim.claimed);
                assertEq(mockStorage(uint256(claim.ctHash)), ordinaryAmounts[users[u]]);
            }
        }
        address[2] memory wrappers = [INPUT_WRAPPER, OUTPUT_WRAPPER];
        for (uint256 w; w < 2; ++w) {
            for (uint256 u; u < 2; ++u) {
                bytes32 handle =
                    euint64.unwrap(IERC7984(wrappers[w]).confidentialBalanceOf(users[u]));
                if (handle == bytes32(0)) continue; // Uninitialized output holders have no ACL.
                assertTrue(taskManager.isAllowed(uint256(handle), wrappers[w]));
                assertTrue(taskManager.isAllowed(uint256(handle), users[u]));
            }
        }
        for (uint256 i; i < _lockIds.length; ++i) {
            LockSnapshot storage snapshot = _lockSnapshots[_lockIds[i]];
            assertTrue(taskManager.isAllowed(uint256(snapshot.lockedAmountHandle), address(escrow)));
            assertTrue(taskManager.isPubliclyAllowed(uint256(snapshot.unshieldRequestHandle)));
        }
    }

    function _expectAtomicFailure(bytes32 id, bytes memory data, bytes4 selector) private {
        bytes32 beforeState = _coupledState(id);
        (bool success, bytes memory result) = address(escrow).call(data);
        assertFalse(success);
        assertGe(result.length, 4);
        assertEq(bytes4(result), selector);
        assertEq(_coupledState(id), beforeState);
    }

    function _coupledState(bytes32 id) private view returns (bytes32) {
        LockSnapshot storage snapshot = _lockSnapshots[id];
        return keccak256(
            abi.encode(
                escrow.getSwapIntentLock(id),
                escrow.liveSwapLockCount(),
                IAlphaEngineEncryptedUnshieldFHERC20Wrapper(INPUT_WRAPPER)
                    .getClaim(snapshot.unshieldClaimId),
                INPUT_UNDERLYING.balanceOf(address(escrow)),
                INPUT_UNDERLYING.balanceOf(address(EXECUTOR)),
                OUTPUT_UNDERLYING.balanceOf(address(escrow)),
                OUTPUT_UNDERLYING.balanceOf(OUTPUT_WRAPPER),
                OUTPUT_UNDERLYING.allowance(address(escrow), OUTPUT_WRAPPER),
                IERC7984(INPUT_WRAPPER).confidentialTotalSupply(),
                IERC7984(OUTPUT_WRAPPER).confidentialTotalSupply(),
                IERC7984(INPUT_WRAPPER).confidentialBalanceOf(snapshot.account),
                IERC7984(OUTPUT_WRAPPER).confidentialBalanceOf(snapshot.account)
            )
        );
    }

    // AS-09/11 and XS-04: ordinary requests and swap locks share balances but
    // retain separate claim gates and admission budgets on the very same wrapper.
    function ordinaryRequest(uint8 seed, uint64 requested) external {
        address user = seed % 2 == 0 ? USER_A : USER_B;
        AlphaEngineFHERC20ERC20Wrapper wrapper = AlphaEngineFHERC20ERC20Wrapper(INPUT_WRAPPER);
        AlphaEngineConfidentialAssetRegistry registry =
            AlphaEngineConfidentialAssetRegistry(GATEWAY.assetRegistry());
        uint256 available = uint256(registry.availableUnshieldTokens())
            + (block.timestamp - registry.unshieldTokensUpdatedAt())
            * registry.unshieldRequestsPerSecond();
        bytes memory expected;
        if (ordinaryPending[user] != bytes32(0)) {
            expected = abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.PendingUnshieldClaim.selector,
                user,
                ordinaryPending[user]
            );
        } else if (block.timestamp < ordinaryCooldowns[user]) {
            expected = abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.UnshieldCooldownActive.selector,
                user,
                ordinaryCooldowns[user]
            );
        } else if (available == 0) {
            expected = abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.UnshieldRateLimitExceeded.selector,
                block.timestamp + 1
            );
        }
        uint256 balance = _confidentialBalance(INPUT_WRAPPER, user);
        vm.startPrank(user);
        euint64 encrypted = FHE.asEuint64(requested);
        sharedEuint64 shared = FHE.shareEuint64(encrypted, INPUT_WRAPPER);
        if (expected.length != 0) {
            vm.expectRevert(expected);
            wrapper.unshield(user, user, shared);
            vm.stopPrank();
            assertEq(_confidentialBalance(INPUT_WRAPPER, user), balance);
            ordinaryRejected += 1;
            return;
        }
        wrapper.unshield(user, user, shared);
        vm.stopPrank();
        uint64 actual = requested >= registry.minimumUnshieldAmount(INPUT_WRAPPER)
            && requested <= balance
            ? requested
            : 0;
        bytes32 id = wrapper.pendingUnshieldClaimId(user);
        assertNotEq(id, bytes32(0));
        ordinaryPending[user] = id;
        ordinaryAmounts[user] = actual;
        pendingUnitsByAccount[user] += actual;
        totalUnclaimedPendingUnits += actual;
        ordinaryRequests += 1;
    }

    function ordinaryClaim(uint8 seed) external {
        address user = seed % 2 == 0 ? USER_A : USER_B;
        bytes32 id = ordinaryPending[user];
        if (id == bytes32(0)) return;
        AlphaEngineFHERC20ERC20Wrapper wrapper = AlphaEngineFHERC20ERC20Wrapper(INPUT_WRAPPER);
        uint64 amount = ordinaryAmounts[user];
        taskManager.publishDecryptResult(uint256(wrapper.getClaim(id).ctHash), amount, "");
        uint256 beforeBalance = INPUT_UNDERLYING.balanceOf(user);
        wrapper.claimUnshielded(id, amount, "");
        assertEq(INPUT_UNDERLYING.balanceOf(user) - beforeBalance, uint256(amount) * wrapper.rate());
        pendingUnitsByAccount[user] -= amount;
        totalUnclaimedPendingUnits -= amount;
        consumedInputUnitsByAccount[user] += amount;
        ordinaryPaid[user] += amount;
        if (amount == 0) ordinaryCooldowns[user] = uint40(block.timestamp + 5 minutes);
        delete ordinaryPending[user];
        delete ordinaryAmounts[user];
        ordinaryClaims += 1;
    }

    function configureOrdinaryAndSwapMinimum(uint64 rawMinimum) external {
        AlphaEngineConfidentialAssetRegistry registry =
            AlphaEngineConfidentialAssetRegistry(GATEWAY.assetRegistry());
        uint64 minimum = uint64(bound(rawMinimum, 1, 2000));
        vm.prank(registry.owner());
        registry.setWrapperMinimums(INPUT_WRAPPER, minimum, minimum);
        ordinaryPolicyUpdates += 1;
    }

    // SW-07: actively clear every admitted live lock, then prove governance
    // makes progress after the last one, including with ordinary claims pending.
    function drainAndRotate(uint256 seed) external {
        uint256 beforeCount = escrow.liveSwapLockCount();
        for (uint256 i; i < beforeCount; ++i) {
            this.refundLock(0);
        }
        assertEq(escrow.liveSwapLockCount(), 0);
        drainedLiveLocks += beforeCount;
        this.rotateAfterDrainOrReject(seed);
    }

    function advanceTime(uint16 elapsed) external {
        vm.warp(block.timestamp + elapsed);
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
            )
            .getClaim(snapshot.unshieldClaimId);
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
                )
                .getClaim(snapshot.unshieldClaimId);
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

        AlphaEngineConfidentialAssetRegistry registry =
            AlphaEngineConfidentialAssetRegistry(GATEWAY.assetRegistry());
        bytes32 admissionBefore = keccak256(
            abi.encode(registry.availableUnshieldTokens(), registry.unshieldTokensUpdatedAt())
        );
        vm.prank(account);
        euint64 lockedAmount = this.lockWithInputForInvariant(
            intentId, account, encryptedInput, _inputProof(address(this), encryptedInput)
        );
        assertEq(
            keccak256(
                abi.encode(registry.availableUnshieldTokens(), registry.unshieldTokensUpdatedAt())
            ),
            admissionBefore
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

        AlphaEngineConfidentialAssetRegistry registry =
            AlphaEngineConfidentialAssetRegistry(GATEWAY.assetRegistry());
        bytes32 admissionBefore = keccak256(
            abi.encode(registry.availableUnshieldTokens(), registry.unshieldTokensUpdatedAt())
        );
        vm.prank(account);
        euint64 lockedAmount = this.lockWithInputForInvariant(
            intentId, account, encryptedInput, _inputProof(address(this), encryptedInput)
        );
        assertEq(
            keccak256(
                abi.encode(registry.availableUnshieldTokens(), registry.unshieldTokensUpdatedAt())
            ),
            admissionBefore
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

/// @dev Test-only failure injection after escrow has transferred claimed input.
contract FailingLifecycleExecutor {
    error ForcedExecutorFailure();

    function executeExactInput(address, address, uint256, uint256, address, bytes calldata)
        external
        pure
        returns (uint256)
    {
        revert ForcedExecutorFailure();
    }
}

contract RegistryBoundEscrowProbe {
    address public immutable assetRegistry;
    uint256 public constant liveSwapLockCount = 0;

    constructor(address registry) {
        assetRegistry = registry;
    }
}
