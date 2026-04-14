// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC7984} from "fhenix-confidential-contracts/interfaces/IERC7984.sol";
import {IFHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {VaultInvariantHandler} from "test/handlers/VaultInvariantHandler.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AlphaEngineConfidentialVaultInvariantTest is MockCoFheTest {
    uint256 private constant USER_STARTING_INPUT_UNDERLYING = 1_000_000_000e6;

    AlphaEngineConfidentialVault internal vault;
    MockERC20 internal inputUnderlying;
    MockERC20 internal outputUnderlying;
    address internal inputWrapper;
    address internal outputWrapper;
    VaultInvariantHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");

    function setUp() public {
        _installMockTaskManager();

        inputUnderlying = new MockERC20("Invariant USDC", "iUSDC", 6);
        outputUnderlying = new MockERC20("Invariant WETH", "iWETH", 18);
        vault = _deployVault(owner);

        vm.startPrank(owner);
        inputWrapper =
            vault.createWrapper(address(inputUnderlying), "Encrypted Invariant USDC", "eiUSDC", "");
        outputWrapper =
            vault.createWrapper(address(outputUnderlying), "Encrypted Invariant WETH", "eiWETH", "");
        vm.stopPrank();

        handler = new VaultInvariantHandler(
            vault, inputUnderlying, inputWrapper, outputUnderlying, outputWrapper, userA, userB
        );

        vm.prank(owner);
        vault.setIntentController(address(handler));

        _fundAndAuthorize(userA);
        _fundAndAuthorize(userB);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = VaultInvariantHandler.depositAsA.selector;
        selectors[1] = VaultInvariantHandler.depositAsB.selector;
        selectors[2] = VaultInvariantHandler.lockAsA.selector;
        selectors[3] = VaultInvariantHandler.lockAsB.selector;
        selectors[4] = VaultInvariantHandler.requestUnshieldAsA.selector;
        selectors[5] = VaultInvariantHandler.requestUnshieldAsB.selector;
        selectors[6] = VaultInvariantHandler.claimUnshield.selector;
        selectors[7] = VaultInvariantHandler.settleLock.selector;
        selectors[8] = VaultInvariantHandler.attemptDustSettle.selector;
        selectors[9] = VaultInvariantHandler.refundLock.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_wrapperRegistryRemainsStable() public view {
        _assertWrapperStable(inputUnderlying, inputWrapper);
        _assertWrapperStable(outputUnderlying, outputWrapper);
    }

    function invariant_lockLifecycleAndFieldsRemainConsistent() public view {
        uint256 liveLockCount;
        uint256 length = handler.lockIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.lockIdAt(index);
            VaultInvariantHandler.LockSnapshot memory snapshot = handler.lockSnapshot(intentId);
            AlphaEngineConfidentialVault.SwapIntentLock memory intentLock =
                vault.getSwapIntentLock(intentId);

            assertTrue(handler.knownLock(intentId));
            assertEq(intentLock.account, snapshot.account);
            assertEq(intentLock.wrapper, snapshot.wrapper);
            assertEq(euint64.unwrap(intentLock.lockedAmount), snapshot.lockedAmountHandle);
            assertEq(_evalue(intentLock.lockedAmount), snapshot.lockedValue);
            assertEq(uint8(intentLock.status), uint8(snapshot.expectedStatus));
            assertEq(
                euint64.unwrap(intentLock.unshieldRequestHandle), snapshot.unshieldRequestHandle
            );
            assertTrue(intentLock.account == userA || intentLock.account == userB);
            assertEq(intentLock.wrapper, inputWrapper);

            if (
                snapshot.expectedStatus
                    == AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested
            ) {
                liveLockCount += 1;
                assertTrue(snapshot.unshieldRequestHandle != bytes32(0));
                assertEq(_evalue(intentLock.unshieldRequestHandle), snapshot.lockedValue);
                assertEq(snapshot.outputWrapper, address(0));
                assertEq(snapshot.outputShieldedHandle, bytes32(0));
                assertEq(snapshot.outputUnderlyingAmount, 0);
                assertEq(snapshot.outputConfidentialUnits, 0);
            }

            if (
                snapshot.expectedStatus
                    == AlphaEngineConfidentialVault.SwapIntentLockStatus.Consumed
            ) {
                assertEq(snapshot.outputWrapper, outputWrapper);
                assertTrue(snapshot.outputShieldedHandle != bytes32(0));
                assertTrue(snapshot.outputUnderlyingAmount > 0);
                assertTrue(snapshot.outputConfidentialUnits > 0);
            }

            if (
                snapshot.expectedStatus
                    == AlphaEngineConfidentialVault.SwapIntentLockStatus.Refunded
            ) {
                assertEq(snapshot.outputWrapper, inputWrapper);
                assertTrue(snapshot.outputShieldedHandle != bytes32(0));
                assertEq(
                    snapshot.outputUnderlyingAmount,
                    snapshot.outputConfidentialUnits * IFHERC20ERC20Wrapper(inputWrapper).rate()
                );
                assertEq(snapshot.outputConfidentialUnits, snapshot.lockedValue);
            }
        }

        assertEq(vault.liveSwapLockCount(), liveLockCount);
    }

    function invariant_vaultAndExecutorDoNotRetainUnderlying() public view {
        assertEq(inputUnderlying.balanceOf(address(vault)), 0);
        assertEq(outputUnderlying.balanceOf(address(vault)), 0);
        assertEq(inputUnderlying.balanceOf(address(handler.EXECUTOR())), 0);
        assertEq(outputUnderlying.balanceOf(address(handler.EXECUTOR())), 0);
    }

    function invariant_userConfidentialBalancesRemainConservedAcrossWrappers() public view {
        _assertUserConservation(userA);
        _assertUserConservation(userB);
    }

    function invariant_confidentialSupplyMatchesTrackedBalances() public view {
        assertEq(
            _confidentialTotalSupply(inputWrapper),
            _confidentialBalance(inputWrapper, userA) + _confidentialBalance(inputWrapper, userB)
                + _confidentialBalance(inputWrapper, address(vault))
        );
        assertEq(
            _confidentialTotalSupply(outputWrapper),
            _confidentialBalance(outputWrapper, userA) + _confidentialBalance(outputWrapper, userB)
                + _confidentialBalance(outputWrapper, address(vault))
        );
    }

    function invariant_eachWrapperReserveMatchesSupplyPlusPendingUnshield() public view {
        uint256 inputRate = IFHERC20ERC20Wrapper(inputWrapper).rate();
        uint256 outputRate = IFHERC20ERC20Wrapper(outputWrapper).rate();

        assertEq(
            inputUnderlying.balanceOf(inputWrapper) / inputRate,
            _confidentialTotalSupply(inputWrapper) + handler.totalPendingInputUnshieldUnits()
        );
        assertEq(
            outputUnderlying.balanceOf(outputWrapper) / outputRate,
            _confidentialTotalSupply(outputWrapper)
        );
    }

    function invariant_claimSnapshotsRemainConsistent() public view {
        uint256 length = handler.claimIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 requestId = handler.claimIdAt(index);
            VaultInvariantHandler.ClaimSnapshot memory snapshot = handler.claimSnapshot(requestId);

            assertEq(snapshot.requestId, requestId);
            assertTrue(snapshot.account == userA || snapshot.account == userB);
            assertTrue(snapshot.amount > 0);
        }
    }

    function invariant_consumedLocksHaveClaimedInputsAndExactOutputs() public view {
        uint256 length = handler.lockIdsLength();
        uint256 outputRate = IFHERC20ERC20Wrapper(outputWrapper).rate();

        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.lockIdAt(index);
            VaultInvariantHandler.LockSnapshot memory snapshot = handler.lockSnapshot(intentId);
            if (
                snapshot.expectedStatus
                    == AlphaEngineConfidentialVault.SwapIntentLockStatus.Consumed
            ) {
                VaultInvariantHandler.ClaimSnapshot memory claimSnapshot =
                    handler.claimSnapshot(snapshot.unshieldRequestHandle);
                assertTrue(claimSnapshot.claimed);
                assertEq(snapshot.outputWrapper, outputWrapper);
                assertEq(
                    snapshot.outputUnderlyingAmount, snapshot.outputConfidentialUnits * outputRate
                );
                assertEq(
                    mockStorage(uint256(snapshot.outputShieldedHandle)),
                    snapshot.outputConfidentialUnits
                );
            }
            if (
                snapshot.expectedStatus
                    == AlphaEngineConfidentialVault.SwapIntentLockStatus.Refunded
            ) {
                VaultInvariantHandler.ClaimSnapshot memory claimSnapshot =
                    handler.claimSnapshot(snapshot.unshieldRequestHandle);
                assertTrue(claimSnapshot.claimed);
                assertEq(snapshot.outputWrapper, inputWrapper);
                assertEq(
                    snapshot.outputUnderlyingAmount,
                    snapshot.outputConfidentialUnits * IFHERC20ERC20Wrapper(inputWrapper).rate()
                );
                assertEq(
                    mockStorage(uint256(snapshot.outputShieldedHandle)),
                    snapshot.outputConfidentialUnits
                );
            }
        }
    }

    function invariant_outputConfidentialBalancesMatchTrackedSettlementCredits() public view {
        assertEq(
            _confidentialBalance(outputWrapper, userA), handler.outputCreditedUnitsByAccount(userA)
        );
        assertEq(
            _confidentialBalance(outputWrapper, userB), handler.outputCreditedUnitsByAccount(userB)
        );
    }

    function invariant_failedDustSettlesNeverPartiallyConsumePendingLocks() public view {
        uint256 length = handler.lockIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.lockIdAt(index);
            VaultInvariantHandler.LockSnapshot memory snapshot = handler.lockSnapshot(intentId);
            if (
                snapshot.failedDustSettleAttempts > 0
                    && snapshot.expectedStatus
                        == AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested
            ) {
                VaultInvariantHandler.ClaimSnapshot memory claimSnapshot =
                    handler.claimSnapshot(snapshot.unshieldRequestHandle);
                assertFalse(claimSnapshot.claimed);
                assertEq(snapshot.outputShieldedHandle, bytes32(0));
                assertEq(snapshot.outputUnderlyingAmount, 0);
                assertEq(snapshot.outputConfidentialUnits, 0);
            }
        }
    }

    function invariant_vaultIntentControllerRemainsHandler() public view {
        assertEq(vault.intentController(), address(handler));
        assertEq(vault.owner(), owner);
    }

    function _assertUserConservation(address account) private view {
        assertEq(
            _confidentialBalance(inputWrapper, account)
                + _confidentialBalance(outputWrapper, account)
                + handler.pendingInputUnshieldUnitsByAccount(account)
                + handler.claimedInputUnitsByAccount(account),
            handler.inputDepositedUnitsByAccount(account)
        );
    }

    function _assertWrapperStable(MockERC20 underlyingToken, address wrapperAddress) private view {
        assertEq(vault.wrapperForUnderlying(address(underlyingToken)), wrapperAddress);
        assertEq(vault.underlyingForWrapper(wrapperAddress), address(underlyingToken));
        assertEq(IFHERC20ERC20Wrapper(wrapperAddress).underlying(), address(underlyingToken));
        assertTrue(wrapperAddress != address(0));
        assertTrue(address(underlyingToken) != address(0));
        assertTrue(IFHERC20ERC20Wrapper(wrapperAddress).rate() > 0);
    }

    function _fundAndAuthorize(address account) private {
        inputUnderlying.mint(account, USER_STARTING_INPUT_UNDERLYING);

        vm.startPrank(account);
        inputUnderlying.approve(address(vault), type(uint256).max);
        AlphaEngineFHERC20ERC20Wrapper(inputWrapper).setOperator(address(vault), type(uint48).max);
        vm.stopPrank();
    }

    function _confidentialBalance(address wrapperAddress, address account)
        private
        view
        returns (uint256)
    {
        return _evalue(IERC7984(wrapperAddress).confidentialBalanceOf(account));
    }

    function _confidentialTotalSupply(address wrapperAddress) private view returns (uint256) {
        return _evalue(IERC7984(wrapperAddress).confidentialTotalSupply());
    }

    function _evalue(euint64 encryptedValue) private view returns (uint256) {
        bytes32 handle = euint64.unwrap(encryptedValue);
        if (handle == bytes32(0)) {
            return 0;
        }

        return mockStorage(uint256(handle));
    }

    function _deployVault(address vaultIntentController)
        private
        returns (AlphaEngineConfidentialVault deployedVault)
    {
        AlphaEngineConfidentialVault vaultImplementation = new AlphaEngineConfidentialVault();
        TransparentUpgradeableProxy vaultProxy = new TransparentUpgradeableProxy(
            address(vaultImplementation),
            owner,
            abi.encodeCall(AlphaEngineConfidentialVault.initialize, (owner, vaultIntentController))
        );
        deployedVault = AlphaEngineConfidentialVault(address(vaultProxy));
    }
}
