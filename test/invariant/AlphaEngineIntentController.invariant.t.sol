// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {IntentControllerInvariantHandler} from "test/handlers/IntentControllerInvariantHandler.sol";
import {AlphaEngineIntentControllerTestBase} from
    "test/mocks/AlphaEngineIntentControllerTestBase.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockSwapExecutor} from "test/mocks/MockSwapExecutor.sol";

contract AlphaEngineIntentControllerInvariantTest is AlphaEngineIntentControllerTestBase {
    uint256 private constant USER_STARTING_UNDERLYING = 1_000_000_000e6;

    IntentControllerInvariantHandler internal handler;
    AlphaEngineConfidentialVault internal vaultA;
    AlphaEngineConfidentialVault internal vaultB;
    MockERC20 internal underlyingA;
    MockERC20 internal underlyingB;
    address internal wrapperA;
    address internal wrapperB;
    MockSwapExecutor internal swapExecutor;

    function setUp() public override {
        super.setUp();

        (vaultA, underlyingA, wrapperA) = _prepareSwapVault("A");
        (vaultB, underlyingB, wrapperB) = _prepareSwapVault("B");

        vm.prank(owner);
        controller.setConfidentialVault(address(vaultA));
        swapExecutor = new MockSwapExecutor();
        vm.prank(owner);
        controller.setSwapExecutor(address(swapExecutor));

        handler = new IntentControllerInvariantHandler(
            controller,
            vaultA,
            wrapperA,
            vaultB,
            wrapperB,
            DEFAULT_MARKET_ID,
            DEFAULT_TIMEFRAME_KEY,
            DEFAULT_SWAP_ROUTE_KEY,
            owner,
            submitter,
            otherSubmitter,
            listenerOperator,
            updatedListenerOperator
        );

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = IntentControllerInvariantHandler.submitStrategyAsA.selector;
        selectors[1] = IntentControllerInvariantHandler.submitStrategyAsB.selector;
        selectors[2] = IntentControllerInvariantHandler.submitSwapAsA.selector;
        selectors[3] = IntentControllerInvariantHandler.submitSwapAsB.selector;
        selectors[4] = IntentControllerInvariantHandler.cancelStrategyAsOwner.selector;
        selectors[5] = IntentControllerInvariantHandler.cancelStrategyAsSubmitterA.selector;
        selectors[6] = IntentControllerInvariantHandler.cancelStrategyAsSubmitterB.selector;
        selectors[7] = IntentControllerInvariantHandler.rotateListenerToA.selector;
        selectors[8] = IntentControllerInvariantHandler.rotateListenerToB.selector;
        selectors[9] = IntentControllerInvariantHandler.rotateVaultToA.selector;
        selectors[10] = IntentControllerInvariantHandler.rotateVaultToB.selector;
        selectors[11] = IntentControllerInvariantHandler.executeSwapAsListenerA.selector;
        selectors[12] = IntentControllerInvariantHandler.executeSwapAsListenerB.selector;
        selectors[13] = IntentControllerInvariantHandler.refundExpiredSwap.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_strategyRecordsRemainConsistent() public view {
        uint256 length = handler.strategyIntentIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.strategyIntentIdAt(index);
            IntentControllerInvariantHandler.StrategySnapshot memory snapshot =
                handler.strategySnapshot(intentId);
            AlphaEngineIntentController.IntentRecord memory intentRecord =
                controller.getIntent(intentId);
            bytes32[] memory handles = controller.getIntentComponentHandles(intentId);

            assertEq(intentRecord.submitter, snapshot.submitter);
            assertEq(intentRecord.marketIdHandle, snapshot.marketIdHandle);
            assertEq(intentRecord.timeframeKey, snapshot.timeframeKey);
            assertEq(intentRecord.deadline, snapshot.deadline);
            assertEq(intentRecord.createdAt, snapshot.createdAt);
            assertEq(intentRecord.submitterNonce, snapshot.submitterNonce);
            assertEq(intentRecord.componentCount, snapshot.componentCount);
            assertEq(intentRecord.payloadHash, snapshot.payloadHash);
            assertEq(uint8(intentRecord.status), uint8(snapshot.expectedStatus));
            assertEq(handles.length, intentRecord.componentCount);
            assertEq(
                intentRecord.payloadHash,
                keccak256(
                    abi.encode(
                        intentRecord.marketIdHandle,
                        intentRecord.timeframeKey,
                        intentRecord.deadline,
                        handles
                    )
                )
            );
            assertTrue(intentRecord.submitter != address(0));
            assertTrue(intentRecord.marketIdHandle != bytes32(0));
            assertTrue(intentRecord.timeframeKey != bytes32(0));
            assertTrue(intentRecord.deadline > intentRecord.createdAt);
            assertTrue(intentRecord.componentCount >= 1);
            assertTrue(intentRecord.componentCount <= controller.MAX_COMPONENT_COUNT());
            assertTrue(
                taskManager.isAllowed(uint256(intentRecord.marketIdHandle), address(controller))
            );
            assertTrue(
                taskManager.isAllowed(
                    uint256(intentRecord.marketIdHandle), snapshot.listenerOperatorAtSubmit
                )
            );

            for (uint256 handleIndex = 0; handleIndex < handles.length; ++handleIndex) {
                assertEq(
                    handles[handleIndex], handler.strategyComponentHandleAt(intentId, handleIndex)
                );
                assertTrue(
                    taskManager.isAllowed(uint256(handles[handleIndex]), address(controller))
                );
                assertTrue(
                    taskManager.isAllowed(
                        uint256(handles[handleIndex]), snapshot.listenerOperatorAtSubmit
                    )
                );
                assertFalse(handler.knownSwapLockedHandle(handles[handleIndex]));
            }
        }
    }

    function invariant_swapRecordsAndVaultLocksRemainConsistent() public view {
        uint256 length = handler.swapIntentIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.swapIntentIdAt(index);
            IntentControllerInvariantHandler.SwapSnapshot memory swapSnapshot =
                handler.swapSnapshot(intentId);
            IntentControllerInvariantHandler.LockSnapshot memory lockSnapshot =
                handler.lockSnapshot(intentId);
            AlphaEngineIntentController.SwapIntentRecord memory swapRecord =
                controller.getSwapIntent(intentId);
            AlphaEngineConfidentialVault.SwapIntentLock memory intentLock =
            AlphaEngineConfidentialVault(swapRecord.confidentialVault).getSwapIntentLock(intentId);

            assertEq(swapRecord.submitter, swapSnapshot.submitter);
            assertEq(swapRecord.confidentialVault, swapSnapshot.confidentialVault);
            assertEq(swapRecord.inputWrapper, swapSnapshot.inputWrapper);
            assertEq(swapRecord.routeKey, swapSnapshot.routeKey);
            assertEq(swapRecord.lockedAmountHandle, swapSnapshot.lockedAmountHandle);
            assertEq(swapRecord.unshieldRequestHandle, swapSnapshot.unshieldRequestHandle);
            assertEq(swapRecord.deadline, swapSnapshot.deadline);
            assertEq(swapRecord.createdAt, swapSnapshot.createdAt);
            assertEq(swapRecord.submitterNonce, swapSnapshot.submitterNonce);
            assertEq(swapRecord.payloadHash, swapSnapshot.payloadHash);
            assertEq(uint8(swapRecord.status), uint8(swapSnapshot.expectedStatus));
            assertEq(
                swapRecord.payloadHash,
                keccak256(
                    abi.encode(
                        swapRecord.confidentialVault,
                        swapRecord.inputWrapper,
                        swapRecord.routeKey,
                        swapRecord.deadline,
                        swapRecord.lockedAmountHandle,
                        swapRecord.unshieldRequestHandle
                    )
                )
            );
            assertTrue(swapRecord.submitter != address(0));
            assertTrue(swapRecord.confidentialVault != address(0));
            assertTrue(swapRecord.inputWrapper != address(0));
            assertTrue(swapRecord.routeKey != bytes32(0));
            assertTrue(swapRecord.lockedAmountHandle != bytes32(0));
            assertTrue(swapRecord.unshieldRequestHandle != bytes32(0));
            assertTrue(swapRecord.deadline > swapRecord.createdAt);
            assertTrue(
                taskManager.isAllowed(
                    uint256(swapSnapshot.requestedInputHandle), address(controller)
                )
            );
            assertTrue(
                taskManager.isAllowed(
                    uint256(swapSnapshot.requestedInputHandle), swapRecord.confidentialVault
                )
            );

            assertEq(intentLock.account, lockSnapshot.account);
            assertEq(intentLock.wrapper, lockSnapshot.wrapper);
            assertEq(euint64.unwrap(intentLock.lockedAmount), lockSnapshot.lockedAmountHandle);
            assertEq(
                euint64.unwrap(intentLock.unshieldRequestHandle), lockSnapshot.unshieldRequestHandle
            );
            assertEq(uint8(intentLock.status), uint8(lockSnapshot.expectedStatus));
            assertEq(intentLock.account, swapRecord.submitter);
            assertEq(intentLock.wrapper, swapRecord.inputWrapper);
            assertEq(euint64.unwrap(intentLock.lockedAmount), swapRecord.lockedAmountHandle);
            assertEq(
                euint64.unwrap(intentLock.unshieldRequestHandle), swapRecord.unshieldRequestHandle
            );
            assertTrue(
                taskManager.isAllowed(
                    uint256(swapRecord.lockedAmountHandle), swapRecord.confidentialVault
                )
            );
            assertFalse(handler.knownStrategyHandle(swapRecord.lockedAmountHandle));
        }
    }

    function invariant_submitterNonceTracksAllIntentFamilies() public view {
        assertEq(
            controller.submitterNonces(submitter), handler.totalSubmissionsBySubmitter(submitter)
        );
        assertEq(
            controller.submitterNonces(otherSubmitter),
            handler.totalSubmissionsBySubmitter(otherSubmitter)
        );
    }

    function invariant_knownIntentIdsRemainUniqueAndFamilyScoped() public view {
        uint256 length = handler.allIntentIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.allIntentIdAt(index);
            assertTrue(handler.knownIntent(intentId));
            assertTrue(handler.knownStrategyIntent(intentId) != handler.knownSwapIntent(intentId));
        }
    }

    function invariant_listenerOperatorNeverZero() public view {
        assertTrue(controller.listenerOperator() != address(0));
    }

    function invariant_configuredVaultIsValidWhenSet() public view {
        address configuredVault = controller.confidentialVault();
        assertTrue(configuredVault == address(vaultA) || configuredVault == address(vaultB));
        assertEq(
            AlphaEngineConfidentialVault(configuredVault).intentController(), address(controller)
        );
    }

    function invariant_swapExecutorRemainsConfigured() public view {
        assertEq(controller.swapExecutor(), address(swapExecutor));
    }

    function _prepareSwapVault(string memory salt)
        private
        returns (AlphaEngineConfidentialVault vault, MockERC20 underlying, address wrapper)
    {
        underlying =
            new MockERC20(string.concat("Invariant USDC ", salt), string.concat("iUSDC", salt), 6);
        vault = _deployVault(address(controller));

        vm.startPrank(owner);
        wrapper = vault.createWrapper(
            address(underlying),
            string.concat("Encrypted USDC ", salt),
            string.concat("eiUSDC", salt),
            ""
        );
        vm.stopPrank();

        _depositAndAuthorize(vault, underlying, wrapper, submitter);
        _depositAndAuthorize(vault, underlying, wrapper, otherSubmitter);
    }

    function _depositAndAuthorize(
        AlphaEngineConfidentialVault vault,
        MockERC20 underlying,
        address wrapper,
        address account
    ) private {
        underlying.mint(account, USER_STARTING_UNDERLYING);

        vm.startPrank(account);
        underlying.approve(address(vault), USER_STARTING_UNDERLYING);
        vault.depositAndShield(address(underlying), USER_STARTING_UNDERLYING, account);
        AlphaEngineFHERC20ERC20Wrapper(wrapper).setOperator(address(vault), type(uint48).max);
        vm.stopPrank();
    }

    function _deployVault(address vaultIntentController)
        private
        returns (AlphaEngineConfidentialVault vault)
    {
        AlphaEngineConfidentialVault vaultImplementation = new AlphaEngineConfidentialVault();
        TransparentUpgradeableProxy vaultProxy = new TransparentUpgradeableProxy(
            address(vaultImplementation),
            owner,
            abi.encodeCall(AlphaEngineConfidentialVault.initialize, (owner, vaultIntentController))
        );
        vault = AlphaEngineConfidentialVault(address(vaultProxy));
    }
}
