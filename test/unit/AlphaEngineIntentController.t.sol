// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Vm} from "forge-std/Vm.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {InEuint64, InEuint128, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {FHERC20WrapperClaimHelper} from
    "fhenix-confidential-contracts/FHERC20/utils/FHERC20WrapperClaimHelper.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {AlphaEngineIntentControllerTestBase} from
    "test/mocks/AlphaEngineIntentControllerTestBase.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AlphaEngineIntentControllerUnitTest is AlphaEngineIntentControllerTestBase {
    struct SwapFixture {
        AlphaEngineConfidentialVault vault;
        MockERC20 underlying;
        address wrapper;
    }

    function test_constructorDisablesImplementationInitializer() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, listenerOperator);
    }

    function test_initializeSetsOwnerOperatorAndProxyAdmin() public view {
        assertEq(controller.owner(), owner);
        assertEq(controller.listenerOperator(), listenerOperator);
        assertTrue(_proxyAdmin() != address(0));
        assertEq(ProxyAdmin(_proxyAdmin()).owner(), owner);
    }

    function test_initializeRejectsZeroOwner() public {
        AlphaEngineIntentController newImplementation = new AlphaEngineIntentController();
        bytes memory initData =
            abi.encodeCall(AlphaEngineIntentController.initialize, (address(0), listenerOperator));

        vm.expectRevert(AlphaEngineIntentController.ZeroOwner.selector);
        new TransparentUpgradeableProxy(address(newImplementation), owner, initData);
    }

    function test_initializeRejectsZeroListenerOperator() public {
        AlphaEngineIntentController newImplementation = new AlphaEngineIntentController();
        bytes memory initData =
            abi.encodeCall(AlphaEngineIntentController.initialize, (owner, address(0)));

        vm.expectRevert(AlphaEngineIntentController.ZeroListenerOperator.selector);
        new TransparentUpgradeableProxy(address(newImplementation), owner, initData);
    }

    function test_reinitializeReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        controller.initialize(owner, listenerOperator);
    }

    function test_submitStoresMetadataHandlesPermissionsAndEvent() public {
        uint128[] memory values = new uint128[](2);
        values[0] = 125;
        values[1] = 250;
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory inputs = _inputs(values, submitter);
        uint40 deadline = _deadlineAhead(1 hours);

        vm.recordLogs();
        bytes32 intentId =
            _submit(submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, deadline);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        AlphaEngineIntentController.IntentRecord memory intentRecord =
            controller.getIntent(intentId);
        bytes32[] memory handles = controller.getIntentComponentHandles(intentId);
        bytes32 expectedPayloadHash = keccak256(
            abi.encode(intentRecord.marketIdHandle, DEFAULT_TIMEFRAME_KEY, deadline, handles)
        );

        assertEq(intentRecord.submitter, submitter);
        assertEq(mockStorage(uint256(intentRecord.marketIdHandle)), DEFAULT_MARKET_ID);
        assertEq(intentRecord.timeframeKey, DEFAULT_TIMEFRAME_KEY);
        assertEq(intentRecord.deadline, deadline);
        assertEq(intentRecord.createdAt, uint40(block.timestamp));
        assertEq(intentRecord.submitterNonce, 0);
        assertEq(intentRecord.componentCount, 2);
        assertEq(uint8(intentRecord.status), uint8(AlphaEngineIntentController.IntentStatus.Active));
        assertEq(intentRecord.payloadHash, expectedPayloadHash);
        assertEq(handles.length, 2);
        assertEq(controller.submitterNonces(submitter), 1);
        assertEq(
            intentId,
            keccak256(abi.encode(address(controller), block.chainid, submitter, uint64(0)))
        );
        assertTrue(taskManager.isAllowed(uint256(intentRecord.marketIdHandle), address(controller)));
        assertTrue(taskManager.isAllowed(uint256(intentRecord.marketIdHandle), listenerOperator));

        for (uint256 index = 0; index < handles.length; ++index) {
            assertTrue(taskManager.isAllowed(uint256(handles[index]), address(controller)));
            assertTrue(taskManager.isAllowed(uint256(handles[index]), listenerOperator));
            assertEq(mockStorage(uint256(handles[index])), values[index]);
        }

        _expectSubmittedLog(
            logs,
            intentId,
            submitter,
            intentRecord.marketIdHandle,
            DEFAULT_TIMEFRAME_KEY,
            handles,
            deadline,
            expectedPayloadHash,
            0
        );
    }

    function test_submitRejectsZeroTimeframeKey() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory inputs = _singleInput(100, submitter);

        vm.prank(submitter);
        vm.expectRevert(AlphaEngineIntentController.ZeroTimeframeKey.selector);
        controller.submitStrategyIntent(marketIdInput, bytes32(0), inputs, _deadlineAhead(1));
    }

    function test_submitRejectsPastDeadline() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory inputs = _singleInput(100, submitter);
        uint40 deadline = uint40(block.timestamp);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.DeadlineNotInFuture.selector,
                deadline,
                uint40(block.timestamp)
            )
        );
        controller.submitStrategyIntent(marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, deadline);
    }

    function test_submitRejectsZeroComponentCount() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory inputs = new InEuint128[](0);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineIntentController.InvalidComponentCount.selector, 0)
        );
        controller.submitStrategyIntent(
            marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1)
        );
    }

    function test_submitRejectsComponentCountAboveMaximum() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory inputs = new InEuint128[](17);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineIntentController.InvalidComponentCount.selector, 17)
        );
        controller.submitStrategyIntent(
            marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1)
        );
    }

    function test_pauseBlocksSubmitAndUnpauseRestoresSubmit() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Paused(owner);
        controller.pause();

        assertTrue(controller.paused());

        InEuint128[] memory inputs = _singleInput(100, submitter);
        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        controller.submitStrategyIntent(
            marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1)
        );

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Unpaused(owner);
        controller.unpause();

        assertFalse(controller.paused());

        bytes32 intentId =
            _submit(submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(2));
        assertEq(controller.getIntent(intentId).submitter, submitter);
    }

    function test_setListenerOperatorUpdatesStateAndEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ListenerOperatorUpdated(listenerOperator, updatedListenerOperator);
        controller.setListenerOperator(updatedListenerOperator);

        assertEq(controller.listenerOperator(), updatedListenerOperator);
    }

    function test_setListenerOperatorRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AlphaEngineIntentController.ZeroListenerOperator.selector);
        controller.setListenerOperator(address(0));
    }

    function test_setListenerOperatorRejectsUnauthorizedCaller() public {
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider)
        );
        controller.setListenerOperator(updatedListenerOperator);
    }

    function test_operatorRotationOnlyAffectsFutureSubmissions() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory firstInputs = _singleInput(111, submitter);
        bytes32 firstIntentId =
            _submit(submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, firstInputs, _deadlineAhead(1));
        bytes32[] memory firstHandles = controller.getIntentComponentHandles(firstIntentId);

        vm.prank(owner);
        controller.setListenerOperator(updatedListenerOperator);

        InEuint128[] memory secondInputs = _singleInput(222, submitter);
        bytes32 secondIntentId = _submit(
            submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, secondInputs, _deadlineAhead(2)
        );
        bytes32[] memory secondHandles = controller.getIntentComponentHandles(secondIntentId);

        assertTrue(taskManager.isAllowed(uint256(firstHandles[0]), listenerOperator));
        assertFalse(taskManager.isAllowed(uint256(firstHandles[0]), updatedListenerOperator));
        assertFalse(taskManager.isAllowed(uint256(secondHandles[0]), listenerOperator));
        assertTrue(taskManager.isAllowed(uint256(secondHandles[0]), updatedListenerOperator));
    }

    function test_setConfidentialVaultUpdatesStateAndEmitsEvent() public {
        AlphaEngineConfidentialVault newVault = _deployControllerVault();

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ConfidentialVaultUpdated(address(0), address(newVault));
        controller.setConfidentialVault(address(newVault));

        assertEq(controller.confidentialVault(), address(newVault));
    }

    function test_setConfidentialVaultRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AlphaEngineIntentController.ZeroConfidentialVault.selector);
        controller.setConfidentialVault(address(0));
    }

    function test_setConfidentialVaultRejectsNonContract() public {
        address invalidVault = makeAddr("invalidVault");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.InvalidConfidentialVault.selector, invalidVault
            )
        );
        controller.setConfidentialVault(invalidVault);
    }

    function test_setConfidentialVaultRejectsContractWithoutVaultSurface() public {
        MockERC20 invalidVault = new MockERC20("Invalid Vault", "BAD", 6);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.InvalidConfidentialVault.selector, address(invalidVault)
            )
        );
        controller.setConfidentialVault(address(invalidVault));
    }

    function test_setConfidentialVaultRejectsVaultForDifferentController() public {
        AlphaEngineConfidentialVault invalidVault = _deployVault(makeAddr("otherController"));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.InvalidConfidentialVault.selector, address(invalidVault)
            )
        );
        controller.setConfidentialVault(address(invalidVault));
    }

    function test_setConfidentialVaultRejectsUnauthorizedCaller() public {
        AlphaEngineConfidentialVault newVault = _deployControllerVault();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider)
        );
        controller.setConfidentialVault(address(newVault));
    }

    function test_submitSwapIntentLocksVaultAndAutoRequestsUnshield() public {
        (SwapFixture memory fixture, InEuint64 memory encryptedInputAmount) =
            _prepareSwapFixture(100e6, 40e6);
        uint40 deadline = _deadlineAhead(1 hours);

        vm.recordLogs();
        bytes32 intentId = _submitSwap(
            submitter, fixture.wrapper, DEFAULT_SWAP_ROUTE_KEY, encryptedInputAmount, deadline
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        AlphaEngineIntentController.SwapIntentRecord memory swapRecord =
            controller.getSwapIntent(intentId);
        AlphaEngineConfidentialVault.SwapIntentLock memory vaultLock =
            fixture.vault.getSwapIntentLock(intentId);
        bytes32 expectedPayloadHash = keccak256(
            abi.encode(
                address(fixture.vault),
                fixture.wrapper,
                DEFAULT_SWAP_ROUTE_KEY,
                deadline,
                swapRecord.lockedAmountHandle,
                swapRecord.unshieldRequestHandle
            )
        );

        assertEq(swapRecord.submitter, submitter);
        assertEq(swapRecord.confidentialVault, address(fixture.vault));
        assertEq(swapRecord.inputWrapper, fixture.wrapper);
        assertEq(swapRecord.routeKey, DEFAULT_SWAP_ROUTE_KEY);
        assertTrue(swapRecord.lockedAmountHandle != bytes32(0));
        assertTrue(swapRecord.unshieldRequestHandle != bytes32(0));
        assertEq(swapRecord.deadline, deadline);
        assertEq(swapRecord.createdAt, uint40(block.timestamp));
        assertEq(swapRecord.submitterNonce, 0);
        assertEq(uint8(swapRecord.status), uint8(AlphaEngineIntentController.IntentStatus.Active));
        assertEq(swapRecord.payloadHash, expectedPayloadHash);
        assertEq(controller.submitterNonces(submitter), 1);
        assertEq(
            intentId,
            keccak256(abi.encode(address(controller), block.chainid, submitter, uint64(0)))
        );
        assertTrue(taskManager.isAllowed(encryptedInputAmount.ctHash, address(controller)));
        assertTrue(taskManager.isAllowed(encryptedInputAmount.ctHash, address(fixture.vault)));

        assertEq(vaultLock.account, submitter);
        assertEq(vaultLock.wrapper, fixture.wrapper);
        assertEq(euint64.unwrap(vaultLock.lockedAmount), swapRecord.lockedAmountHandle);
        assertEq(euint64.unwrap(vaultLock.unshieldRequestHandle), swapRecord.unshieldRequestHandle);
        assertEq(
            uint8(vaultLock.status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested)
        );
        assertEq(mockStorage(uint256(swapRecord.lockedAmountHandle)), 40e6);
        assertEq(mockStorage(uint256(swapRecord.unshieldRequestHandle)), 40e6);

        euint64 submitterBalance =
            AlphaEngineFHERC20ERC20Wrapper(fixture.wrapper).confidentialBalanceOf(submitter);
        euint64 vaultBalance = AlphaEngineFHERC20ERC20Wrapper(fixture.wrapper).confidentialBalanceOf(
            address(fixture.vault)
        );
        assertEq(mockStorage(uint256(euint64.unwrap(submitterBalance))), 60e6);
        assertEq(mockStorage(uint256(euint64.unwrap(vaultBalance))), 0);

        FHERC20WrapperClaimHelper.Claim memory claim = AlphaEngineFHERC20ERC20Wrapper(
            fixture.wrapper
        ).getClaim(swapRecord.unshieldRequestHandle);
        assertEq(claim.to, address(fixture.vault));
        assertEq(claim.ctHash, swapRecord.unshieldRequestHandle);
        assertEq(claim.requestedAmount, 0);
        assertFalse(claim.claimed);

        _expectSwapSubmittedLog(
            logs,
            intentId,
            submitter,
            fixture.wrapper,
            address(fixture.vault),
            DEFAULT_SWAP_ROUTE_KEY,
            swapRecord.lockedAmountHandle,
            swapRecord.unshieldRequestHandle,
            deadline,
            expectedPayloadHash,
            0
        );
    }

    function test_submitSwapIntentRejectsUnsetVault() public {
        InEuint64 memory encryptedInputAmount = createInEuint64(1, submitter);

        vm.prank(submitter);
        vm.expectRevert(AlphaEngineIntentController.ZeroConfidentialVault.selector);
        controller.submitSwapIntent(
            makeAddr("wrapper"), DEFAULT_SWAP_ROUTE_KEY, encryptedInputAmount, _deadlineAhead(1)
        );
    }

    function test_submitSwapIntentRejectsZeroInputWrapper() public {
        _configureControllerVault();
        InEuint64 memory encryptedInputAmount = createInEuint64(1, submitter);

        vm.prank(submitter);
        vm.expectRevert(AlphaEngineIntentController.ZeroInputWrapper.selector);
        controller.submitSwapIntent(
            address(0), DEFAULT_SWAP_ROUTE_KEY, encryptedInputAmount, _deadlineAhead(1)
        );
    }

    function test_submitSwapIntentRejectsZeroRouteKey() public {
        _configureControllerVault();
        InEuint64 memory encryptedInputAmount = createInEuint64(1, submitter);

        vm.prank(submitter);
        vm.expectRevert(AlphaEngineIntentController.ZeroSwapRouteKey.selector);
        controller.submitSwapIntent(
            makeAddr("wrapper"), bytes32(0), encryptedInputAmount, _deadlineAhead(1)
        );
    }

    function test_submitSwapIntentRejectsPastDeadline() public {
        _configureControllerVault();
        InEuint64 memory encryptedInputAmount = createInEuint64(1, submitter);
        uint40 deadline = uint40(block.timestamp);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.DeadlineNotInFuture.selector,
                deadline,
                uint40(block.timestamp)
            )
        );
        controller.submitSwapIntent(
            makeAddr("wrapper"), DEFAULT_SWAP_ROUTE_KEY, encryptedInputAmount, deadline
        );
    }

    function test_pauseBlocksSwapSubmitAndUnpauseRestoresSubmit() public {
        (SwapFixture memory fixture, InEuint64 memory encryptedInputAmount) =
            _prepareSwapFixture(100e6, 40e6);

        vm.prank(owner);
        controller.pause();

        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        controller.submitSwapIntent(
            fixture.wrapper, DEFAULT_SWAP_ROUTE_KEY, encryptedInputAmount, _deadlineAhead(1)
        );

        vm.prank(owner);
        controller.unpause();

        bytes32 intentId = _submitSwap(
            submitter,
            fixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            encryptedInputAmount,
            _deadlineAhead(2)
        );
        assertEq(controller.getSwapIntent(intentId).submitter, submitter);
    }

    function test_confidentialVaultRotationOnlyAffectsFutureSwapSubmissions() public {
        (SwapFixture memory firstFixture, InEuint64 memory firstInputAmount) =
            _prepareSwapFixture(100e6, 40e6);

        bytes32 firstIntentId = _submitSwap(
            submitter,
            firstFixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            firstInputAmount,
            _deadlineAhead(1)
        );

        (SwapFixture memory secondFixture, InEuint64 memory secondInputAmount) =
            _prepareSwapFixtureForSubmitter(otherSubmitter, 200e6, 60e6);

        bytes32 secondIntentId = _submitSwap(
            otherSubmitter,
            secondFixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            secondInputAmount,
            _deadlineAhead(2)
        );

        assertEq(
            controller.getSwapIntent(firstIntentId).confidentialVault, address(firstFixture.vault)
        );
        assertEq(
            controller.getSwapIntent(secondIntentId).confidentialVault, address(secondFixture.vault)
        );
        assertEq(controller.submitterNonces(submitter), 1);
        assertEq(controller.submitterNonces(otherSubmitter), 1);

        assertEq(
            uint8(firstFixture.vault.getSwapIntentLock(firstIntentId).status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested)
        );
        assertEq(
            uint8(secondFixture.vault.getSwapIntentLock(secondIntentId).status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested)
        );
    }

    function test_cancelAllowsSubmitterAndEmitsEvent() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        vm.prank(submitter);
        vm.expectEmit(true, true, false, false);
        emit StrategyIntentCancelled(intentId, submitter);
        controller.cancelStrategyIntent(intentId);

        assertEq(
            uint8(controller.getIntent(intentId).status),
            uint8(AlphaEngineIntentController.IntentStatus.Cancelled)
        );
    }

    function test_cancelAllowsOwnerWhilePaused() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        vm.prank(owner);
        controller.pause();

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit StrategyIntentCancelled(intentId, owner);
        controller.cancelStrategyIntent(intentId);

        assertEq(
            uint8(controller.getIntent(intentId).status),
            uint8(AlphaEngineIntentController.IntentStatus.Cancelled)
        );
    }

    function test_cancelRejectsUnauthorizedCaller() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.UnauthorizedCancel.selector, outsider, intentId
            )
        );
        controller.cancelStrategyIntent(intentId);
    }

    function test_cancelRejectsUnknownIntent() public {
        bytes32 unknownIntentId = keccak256("unknown-intent");

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.IntentNotFound.selector, unknownIntentId
            )
        );
        controller.cancelStrategyIntent(unknownIntentId);
    }

    function test_cancelRejectsAlreadyCancelledIntent() public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        vm.prank(submitter);
        controller.cancelStrategyIntent(intentId);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.IntentAlreadyCancelled.selector, intentId
            )
        );
        controller.cancelStrategyIntent(intentId);
    }

    function test_gettersReturnDefaultsForUnknownIntent() public view {
        bytes32 unknownIntentId = keccak256("unknown-intent");
        AlphaEngineIntentController.IntentRecord memory intentRecord =
            controller.getIntent(unknownIntentId);
        bytes32[] memory componentHandles = controller.getIntentComponentHandles(unknownIntentId);
        AlphaEngineIntentController.SwapIntentRecord memory swapIntentRecord =
            controller.getSwapIntent(unknownIntentId);

        assertEq(intentRecord.submitter, address(0));
        assertEq(intentRecord.marketIdHandle, bytes32(0));
        assertEq(componentHandles.length, 0);
        assertEq(swapIntentRecord.submitter, address(0));
        assertEq(swapIntentRecord.confidentialVault, address(0));
        assertEq(swapIntentRecord.lockedAmountHandle, bytes32(0));
        assertEq(swapIntentRecord.unshieldRequestHandle, bytes32(0));
    }

    function _submitDefaultSwapIntent()
        private
        returns (SwapFixture memory fixture, bytes32 intentId)
    {
        InEuint64 memory encryptedInputAmount;
        (fixture, encryptedInputAmount) = _prepareSwapFixture(100e6, 40e6);
        intentId = _submitSwap(
            submitter,
            fixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            encryptedInputAmount,
            _deadlineAhead(1 hours)
        );
    }

    function _prepareSwapFixture(uint256 depositAmount, uint64 lockAmount)
        private
        returns (SwapFixture memory fixture, InEuint64 memory encryptedInputAmount)
    {
        return _prepareSwapFixtureForSubmitter(submitter, depositAmount, lockAmount);
    }

    function _prepareSwapFixtureForSubmitter(
        address fixtureSubmitter,
        uint256 depositAmount,
        uint64 lockAmount
    ) private returns (SwapFixture memory fixture, InEuint64 memory encryptedInputAmount) {
        fixture = _deploySwapFixture();

        fixture.underlying.mint(fixtureSubmitter, depositAmount);

        vm.startPrank(fixtureSubmitter);
        fixture.underlying.approve(address(fixture.vault), depositAmount);
        fixture.vault.depositAndShield(address(fixture.underlying), depositAmount, fixtureSubmitter);
        AlphaEngineFHERC20ERC20Wrapper(fixture.wrapper).setOperator(
            address(fixture.vault), uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        encryptedInputAmount = createInEuint64(lockAmount, fixtureSubmitter);
    }

    function _deploySwapFixture() private returns (SwapFixture memory fixture) {
        fixture.underlying = new MockERC20("USD Coin", "USDC", 6);
        fixture.vault = _deployControllerVault();

        vm.startPrank(owner);
        fixture.wrapper =
            fixture.vault.createWrapper(address(fixture.underlying), "Encrypted USDC", "eUSDC", "");
        controller.setConfidentialVault(address(fixture.vault));
        vm.stopPrank();
    }

    function _configureControllerVault() private returns (AlphaEngineConfidentialVault vault) {
        vault = _deployControllerVault();
        vm.prank(owner);
        controller.setConfidentialVault(address(vault));
    }

    function _deployControllerVault() private returns (AlphaEngineConfidentialVault vault) {
        vault = _deployVault(address(controller));
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
