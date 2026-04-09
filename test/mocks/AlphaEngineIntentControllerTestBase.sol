// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Vm} from "forge-std/Vm.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";

abstract contract AlphaEngineIntentControllerTestBase is MockCoFheTest {
    event StrategyIntentCancelled(bytes32 indexed intentId, address indexed actor);
    event ListenerOperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event Paused(address account);
    event Unpaused(address account);

    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant STRATEGY_INTENT_SUBMITTED_TOPIC =
        keccak256(
            "StrategyIntentSubmitted(bytes32,address,address,bytes32,bytes32[],uint40,bytes32,uint64)"
        );
    bytes32 internal constant DEFAULT_TIMEFRAME_KEY = keccak256("1h");

    address internal owner = makeAddr("owner");
    address internal listenerOperator = makeAddr("listenerOperator");
    address internal updatedListenerOperator = makeAddr("updatedListenerOperator");
    address internal submitter = makeAddr("submitter");
    address internal otherSubmitter = makeAddr("otherSubmitter");
    address internal outsider = makeAddr("outsider");
    address internal market = makeAddr("market");

    AlphaEngineIntentController internal implementation;
    AlphaEngineIntentController internal controller;
    TransparentUpgradeableProxy internal proxy;

    function setUp() public virtual {
        _installMockTaskManager();

        implementation = new AlphaEngineIntentController();
        proxy = new TransparentUpgradeableProxy(
            address(implementation),
            owner,
            abi.encodeCall(AlphaEngineIntentController.initialize, (owner, listenerOperator))
        );
        controller = AlphaEngineIntentController(address(proxy));
    }

    function _proxyAdmin() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT))));
    }

    function _deadlineAhead(uint40 delta) internal view returns (uint40) {
        return uint40(block.timestamp) + delta;
    }

    function _singleInput(uint128 value, address sender) internal returns (InEuint128[] memory inputs) {
        inputs = new InEuint128[](1);
        inputs[0] = createInEuint128(value, sender);
    }

    function _inputs(uint128[] memory values, address sender) internal returns (InEuint128[] memory inputs) {
        inputs = new InEuint128[](values.length);
        for (uint256 index = 0; index < values.length; ++index) {
            inputs[index] = createInEuint128(values[index], sender);
        }
    }

    function _repeatedInputs(
        uint128 value,
        uint256 count,
        address sender
    ) internal returns (InEuint128[] memory inputs) {
        InEuint128 memory input = createInEuint128(value, sender);
        inputs = new InEuint128[](count);
        for (uint256 index = 0; index < count; ++index) {
            inputs[index] = input;
        }
    }

    function _submit(
        address sender,
        address marketAddress,
        bytes32 timeframeKey,
        InEuint128[] memory inputs,
        uint40 deadline
    ) internal returns (bytes32 intentId) {
        vm.prank(sender);
        intentId = controller.submitStrategyIntent(marketAddress, timeframeKey, inputs, deadline);
    }

    function _expectSubmittedLog(
        Vm.Log[] memory logs,
        bytes32 expectedIntentId,
        address expectedSubmitter,
        address expectedMarket,
        bytes32 expectedTimeframeKey,
        bytes32[] memory expectedHandles,
        uint40 expectedDeadline,
        bytes32 expectedPayloadHash,
        uint64 expectedSubmitterNonce
    ) internal pure {
        bool found;

        for (uint256 index = 0; index < logs.length; ++index) {
            Vm.Log memory logEntry = logs[index];
            if (logEntry.topics.length == 4 && logEntry.topics[0] == STRATEGY_INTENT_SUBMITTED_TOPIC) {
                found = true;
                assertEq(logEntry.topics[1], expectedIntentId);
                assertEq(address(uint160(uint256(logEntry.topics[2]))), expectedSubmitter);
                assertEq(address(uint160(uint256(logEntry.topics[3]))), expectedMarket);

                (
                    bytes32 timeframeKey,
                    bytes32[] memory componentHandles,
                    uint40 deadline,
                    bytes32 payloadHash,
                    uint64 submitterNonce
                ) = abi.decode(logEntry.data, (bytes32, bytes32[], uint40, bytes32, uint64));

                assertEq(timeframeKey, expectedTimeframeKey);
                assertEq(deadline, expectedDeadline);
                assertEq(payloadHash, expectedPayloadHash);
                assertEq(submitterNonce, expectedSubmitterNonce);
                assertEq(componentHandles.length, expectedHandles.length);
                for (uint256 handleIndex = 0; handleIndex < componentHandles.length; ++handleIndex) {
                    assertEq(componentHandles[handleIndex], expectedHandles[handleIndex]);
                }
                break;
            }
        }

        assertTrue(found, "StrategyIntentSubmitted log not found");
    }
}
