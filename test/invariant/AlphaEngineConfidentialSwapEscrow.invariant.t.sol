// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC7984} from "fhenix-confidential-contracts/interfaces/IERC7984.sol";
import {IFHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {FHERC20WrapperClaimHelper} from
    "fhenix-confidential-contracts/FHERC20/utils/FHERC20WrapperClaimHelper.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineConfidentialAssetRegistry} from
    "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {AlphaEngineConfidentialAssetGateway} from
    "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {IAlphaEngineConfidentialSwapEscrow} from
    "src/interfaces/IAlphaEngineConfidentialSwapEscrow.sol";
import {AlphaEngineConfidentialSwapEscrow} from "src/swap/AlphaEngineConfidentialSwapEscrow.sol";
import {ConfidentialSwapEscrowInvariantHandler} from
    "test/handlers/ConfidentialSwapEscrowInvariantHandler.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AlphaEngineConfidentialSwapEscrowInvariantTest is MockCoFheTest {
    uint256 private constant USER_STARTING_UNDERLYING = 1_000_000_000e6;

    AlphaEngineConfidentialAssetRegistry private registry;
    AlphaEngineConfidentialAssetGateway private gateway;
    AlphaEngineConfidentialSwapEscrow private escrow;
    MockERC20 private inputUnderlying;
    MockERC20 private outputUnderlying;
    address private inputWrapper;
    address private outputWrapper;
    ConfidentialSwapEscrowInvariantHandler private handler;

    address private admin = makeAddr("stage7-invariant-admin");
    address private pauser = makeAddr("stage7-invariant-pauser");
    address private proxyAdminOwner = makeAddr("stage7-invariant-proxy-admin");
    address private userA = makeAddr("stage7-invariant-user-a");
    address private userB = makeAddr("stage7-invariant-user-b");

    function setUp() public {
        _installMockTaskManager();
        registry = new AlphaEngineConfidentialAssetRegistry(admin);
        gateway = new AlphaEngineConfidentialAssetGateway(registry);
        inputUnderlying = new MockERC20("Invariant USDC", "iUSDC", 6);
        outputUnderlying = new MockERC20("Invariant USDT", "iUSDT", 6);

        vm.startPrank(admin);
        inputWrapper =
            registry.createWrapper(address(inputUnderlying), "Encrypted iUSDC", "eiUSDC", "");
        outputWrapper =
            registry.createWrapper(address(outputUnderlying), "Encrypted iUSDT", "eiUSDT", "");
        vm.stopPrank();

        handler = new ConfidentialSwapEscrowInvariantHandler(
            gateway, inputUnderlying, inputWrapper, outputUnderlying, outputWrapper, userA, userB
        );

        AlphaEngineConfidentialSwapEscrow implementation = new AlphaEngineConfidentialSwapEscrow();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapEscrow.initialize,
                (admin, pauser, address(handler), address(registry))
            )
        );
        escrow = AlphaEngineConfidentialSwapEscrow(address(proxy));
        handler.bindEscrow(escrow);

        vm.prank(admin);
        escrow.unpause();

        _fundAndAuthorize(userA);
        _fundAndAuthorize(userB);

        handler.depositAsA(200e6);
        handler.lockAsA(40e6);
        handler.preclaimLock(0);
        handler.settleLock(0);
        handler.depositAsB(200e6);
        handler.lockAsB(50e6);
        handler.refundLock(1);
        handler.overdrawLockAsA();
        handler.refundLock(2);
        handler.lockAsA(30e6);
        handler.attemptUnderMinimumSettlement(3);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = ConfidentialSwapEscrowInvariantHandler.depositAsA.selector;
        selectors[1] = ConfidentialSwapEscrowInvariantHandler.depositAsB.selector;
        selectors[2] = ConfidentialSwapEscrowInvariantHandler.lockAsA.selector;
        selectors[3] = ConfidentialSwapEscrowInvariantHandler.lockAsB.selector;
        selectors[4] = ConfidentialSwapEscrowInvariantHandler.overdrawLockAsA.selector;
        selectors[5] = ConfidentialSwapEscrowInvariantHandler.overdrawLockAsB.selector;
        selectors[6] = ConfidentialSwapEscrowInvariantHandler.preclaimLock.selector;
        selectors[7] = ConfidentialSwapEscrowInvariantHandler.settleLock.selector;
        selectors[8] = ConfidentialSwapEscrowInvariantHandler.refundLock.selector;
        selectors[9] = ConfidentialSwapEscrowInvariantHandler.attemptUnderMinimumSettlement.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_registryAndEscrowConfigurationRemainStable() public view {
        assertEq(registry.wrapperForUnderlying(address(inputUnderlying)), inputWrapper);
        assertEq(registry.wrapperForUnderlying(address(outputUnderlying)), outputWrapper);
        assertEq(registry.underlyingForWrapper(inputWrapper), address(inputUnderlying));
        assertEq(registry.underlyingForWrapper(outputWrapper), address(outputUnderlying));
        assertEq(escrow.assetRegistry(), address(registry));
        assertEq(escrow.swapController(), address(handler));
        assertEq(gateway.assetRegistry(), address(registry));
    }

    function invariant_liveCountAndLockRecordsMatchTrackedLifecycle() public view {
        uint256 expectedLiveCount;
        uint256 length = handler.lockIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.lockIdAt(index);
            ConfidentialSwapEscrowInvariantHandler.LockSnapshot memory snapshot =
                handler.lockSnapshot(intentId);
            IAlphaEngineConfidentialSwapEscrow.SwapIntentLock memory intentLock =
                escrow.getSwapIntentLock(intentId);

            assertTrue(handler.knownLock(intentId));
            assertEq(intentLock.account, snapshot.account);
            assertEq(intentLock.wrapper, inputWrapper);
            assertEq(euint64.unwrap(intentLock.lockedAmount), snapshot.lockedAmountHandle);
            assertEq(
                euint64.unwrap(intentLock.unshieldRequestHandle), snapshot.unshieldRequestHandle
            );
            assertEq(_evalue(intentLock.lockedAmount), snapshot.inputAmount);
            assertEq(uint8(intentLock.status), uint8(snapshot.expectedStatus));

            if (
                snapshot.expectedStatus
                    == IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested
            ) {
                expectedLiveCount += 1;
                assertEq(_evalue(intentLock.unshieldRequestHandle), snapshot.inputAmount);
            }
        }
        assertEq(escrow.liveSwapLockCount(), expectedLiveCount);
    }

    function invariant_gatewayEscrowAndExecutorRetainNoUnderlying() public view {
        assertEq(inputUnderlying.balanceOf(address(gateway)), 0);
        assertEq(outputUnderlying.balanceOf(address(gateway)), 0);
        assertEq(inputUnderlying.balanceOf(address(escrow)), handler.totalPreclaimedUnderlying());
        assertEq(outputUnderlying.balanceOf(address(escrow)), 0);
        assertEq(inputUnderlying.balanceOf(address(handler.EXECUTOR())), 0);
        assertEq(outputUnderlying.balanceOf(address(handler.EXECUTOR())), 0);
        assertEq(inputUnderlying.allowance(address(gateway), inputWrapper), 0);
        assertEq(outputUnderlying.allowance(address(escrow), outputWrapper), 0);
    }

    function invariant_userConfidentialBalancesAndPendingClaimsAreConserved() public view {
        _assertUserConservation(userA);
        _assertUserConservation(userB);
    }

    function invariant_wrapperReservesMatchSupplyAndPendingClaims() public view {
        uint256 inputRate = IFHERC20ERC20Wrapper(inputWrapper).rate();
        uint256 outputRate = IFHERC20ERC20Wrapper(outputWrapper).rate();

        assertEq(
            inputUnderlying.balanceOf(inputWrapper) / inputRate,
            _confidentialTotalSupply(inputWrapper) + handler.totalUnclaimedPendingUnits()
        );
        assertEq(
            outputUnderlying.balanceOf(outputWrapper) / outputRate,
            _confidentialTotalSupply(outputWrapper)
        );
    }

    function invariant_confidentialSupplyMatchesTrackedHolders() public view {
        assertEq(
            _confidentialTotalSupply(inputWrapper),
            _confidentialBalance(inputWrapper, userA) + _confidentialBalance(inputWrapper, userB)
        );
        assertEq(
            _confidentialTotalSupply(outputWrapper),
            _confidentialBalance(outputWrapper, userA) + _confidentialBalance(outputWrapper, userB)
        );
        assertEq(
            _confidentialBalance(outputWrapper, userA), handler.settledOutputUnitsByAccount(userA)
        );
        assertEq(
            _confidentialBalance(outputWrapper, userB), handler.settledOutputUnitsByAccount(userB)
        );
    }

    function invariant_terminalLocksHaveClaimedInputsAndFailedSettlesRemainLive() public view {
        uint256 length = handler.lockIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.lockIdAt(index);
            ConfidentialSwapEscrowInvariantHandler.LockSnapshot memory snapshot =
                handler.lockSnapshot(intentId);
            FHERC20WrapperClaimHelper.Claim memory claim = AlphaEngineFHERC20ERC20Wrapper(
                inputWrapper
            ).getClaim(snapshot.unshieldRequestHandle);

            if (
                snapshot.expectedStatus
                    == IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Consumed
                    || snapshot.expectedStatus
                        == IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Refunded
            ) {
                assertTrue(claim.claimed);
            } else {
                assertEq(claim.claimed, snapshot.preclaimed);
            }

            if (snapshot.failedSettlementAttempts != 0) {
                assertTrue(
                    snapshot.expectedStatus
                        != IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Unset
                );
            }
        }
    }

    function _assertUserConservation(address account) private view {
        assertEq(
            _confidentialBalance(inputWrapper, account) + handler.pendingUnitsByAccount(account)
                + handler.consumedInputUnitsByAccount(account),
            handler.depositedUnitsByAccount(account)
        );
        assertEq(
            _confidentialBalance(outputWrapper, account),
            handler.settledOutputUnitsByAccount(account)
        );
    }

    function invariant_meaningfulActionsAreExercised() public view {
        assertGt(handler.successfulDeposits(), 0);
        assertGt(handler.successfulLocks(), 0);
        assertGt(handler.successfulZeroLocks(), 0);
        assertGt(handler.successfulPreclaims(), 0);
        assertGt(handler.successfulSettlements(), 0);
        assertGt(handler.successfulRefunds(), 0);
        assertGt(handler.expectedSettlementReverts(), 0);
    }

    function _fundAndAuthorize(address account) private {
        inputUnderlying.mint(account, USER_STARTING_UNDERLYING);
        vm.startPrank(account);
        inputUnderlying.approve(address(gateway), type(uint256).max);
        AlphaEngineFHERC20ERC20Wrapper(inputWrapper).setOperator(address(escrow), type(uint48).max);
        vm.stopPrank();
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
        return handle == bytes32(0) ? 0 : mockStorage(uint256(handle));
    }
}
