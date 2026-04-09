// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Vm} from "forge-std/Vm.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {AlphaEngineIntentControllerTestBase} from "test/mocks/AlphaEngineIntentControllerTestBase.sol";

contract AlphaEngineIntentControllerUnitTest is AlphaEngineIntentControllerTestBase {
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
        bytes memory initData = abi.encodeCall(
            AlphaEngineIntentController.initialize,
            (address(0), listenerOperator)
        );

        vm.expectRevert(AlphaEngineIntentController.ZeroOwner.selector);
        new TransparentUpgradeableProxy(address(newImplementation), owner, initData);
    }

    function test_initializeRejectsZeroListenerOperator() public {
        AlphaEngineIntentController newImplementation = new AlphaEngineIntentController();
        bytes memory initData = abi.encodeCall(
            AlphaEngineIntentController.initialize,
            (owner, address(0))
        );

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
        InEuint128[] memory inputs = _inputs(values, submitter);
        uint40 deadline = _deadlineAhead(1 hours);

        vm.recordLogs();
        bytes32 intentId = _submit(submitter, market, DEFAULT_TIMEFRAME_KEY, inputs, deadline);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        AlphaEngineIntentController.IntentRecord memory intentRecord = controller.getIntent(intentId);
        bytes32[] memory handles = controller.getIntentComponentHandles(intentId);
        bytes32 expectedPayloadHash = keccak256(
            abi.encode(market, DEFAULT_TIMEFRAME_KEY, deadline, handles)
        );

        assertEq(intentRecord.submitter, submitter);
        assertEq(intentRecord.market, market);
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

        for (uint256 index = 0; index < handles.length; ++index) {
            assertTrue(taskManager.isAllowed(uint256(handles[index]), address(controller)));
            assertTrue(taskManager.isAllowed(uint256(handles[index]), listenerOperator));
            assertEq(mockStorage(uint256(handles[index])), values[index]);
        }

        _expectSubmittedLog(
            logs,
            intentId,
            submitter,
            market,
            DEFAULT_TIMEFRAME_KEY,
            handles,
            deadline,
            expectedPayloadHash,
            0
        );
    }

    function test_submitRejectsZeroMarket() public {
        InEuint128[] memory inputs = _singleInput(100, submitter);

        vm.prank(submitter);
        vm.expectRevert(AlphaEngineIntentController.ZeroMarket.selector);
        controller.submitStrategyIntent(address(0), DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1));
    }

    function test_submitRejectsZeroTimeframeKey() public {
        InEuint128[] memory inputs = _singleInput(100, submitter);

        vm.prank(submitter);
        vm.expectRevert(AlphaEngineIntentController.ZeroTimeframeKey.selector);
        controller.submitStrategyIntent(market, bytes32(0), inputs, _deadlineAhead(1));
    }

    function test_submitRejectsPastDeadline() public {
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
        controller.submitStrategyIntent(market, DEFAULT_TIMEFRAME_KEY, inputs, deadline);
    }

    function test_submitRejectsZeroComponentCount() public {
        InEuint128[] memory inputs = new InEuint128[](0);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineIntentController.InvalidComponentCount.selector, 0)
        );
        controller.submitStrategyIntent(market, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1));
    }

    function test_submitRejectsComponentCountAboveMaximum() public {
        InEuint128[] memory inputs = new InEuint128[](17);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineIntentController.InvalidComponentCount.selector, 17)
        );
        controller.submitStrategyIntent(market, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1));
    }

    function test_pauseBlocksSubmitAndUnpauseRestoresSubmit() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Paused(owner);
        controller.pause();

        assertTrue(controller.paused());

        InEuint128[] memory inputs = _singleInput(100, submitter);
        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        controller.submitStrategyIntent(market, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Unpaused(owner);
        controller.unpause();

        assertFalse(controller.paused());

        bytes32 intentId = _submit(submitter, market, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(2));
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
        InEuint128[] memory firstInputs = _singleInput(111, submitter);
        bytes32 firstIntentId = _submit(
            submitter,
            market,
            DEFAULT_TIMEFRAME_KEY,
            firstInputs,
            _deadlineAhead(1)
        );
        bytes32[] memory firstHandles = controller.getIntentComponentHandles(firstIntentId);

        vm.prank(owner);
        controller.setListenerOperator(updatedListenerOperator);

        InEuint128[] memory secondInputs = _singleInput(222, submitter);
        bytes32 secondIntentId = _submit(
            submitter,
            market,
            DEFAULT_TIMEFRAME_KEY,
            secondInputs,
            _deadlineAhead(2)
        );
        bytes32[] memory secondHandles = controller.getIntentComponentHandles(secondIntentId);

        assertTrue(taskManager.isAllowed(uint256(firstHandles[0]), listenerOperator));
        assertFalse(taskManager.isAllowed(uint256(firstHandles[0]), updatedListenerOperator));
        assertFalse(taskManager.isAllowed(uint256(secondHandles[0]), listenerOperator));
        assertTrue(taskManager.isAllowed(uint256(secondHandles[0]), updatedListenerOperator));
    }

    function test_cancelAllowsSubmitterAndEmitsEvent() public {
        bytes32 intentId = _submit(
            submitter,
            market,
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
        bytes32 intentId = _submit(
            submitter,
            market,
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
        bytes32 intentId = _submit(
            submitter,
            market,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.UnauthorizedCancel.selector,
                outsider,
                intentId
            )
        );
        controller.cancelStrategyIntent(intentId);
    }

    function test_cancelRejectsUnknownIntent() public {
        bytes32 unknownIntentId = keccak256("unknown-intent");

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineIntentController.IntentNotFound.selector, unknownIntentId)
        );
        controller.cancelStrategyIntent(unknownIntentId);
    }

    function test_cancelRejectsAlreadyCancelledIntent() public {
        bytes32 intentId = _submit(
            submitter,
            market,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(100, submitter),
            _deadlineAhead(1)
        );

        vm.prank(submitter);
        controller.cancelStrategyIntent(intentId);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.IntentAlreadyCancelled.selector,
                intentId
            )
        );
        controller.cancelStrategyIntent(intentId);
    }

    function test_gettersReturnDefaultsForUnknownIntent() public view {
        bytes32 unknownIntentId = keccak256("unknown-intent");
        AlphaEngineIntentController.IntentRecord memory intentRecord = controller.getIntent(unknownIntentId);
        bytes32[] memory componentHandles = controller.getIntentComponentHandles(unknownIntentId);

        assertEq(intentRecord.submitter, address(0));
        assertEq(componentHandles.length, 0);
    }
}
