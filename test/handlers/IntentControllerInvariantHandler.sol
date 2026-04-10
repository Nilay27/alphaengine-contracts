// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";

contract IntentControllerInvariantHandler is MockCoFheTest {
    AlphaEngineIntentController public immutable CONTROLLER;
    uint128 public immutable MARKET_ID;
    bytes32 public immutable TIMEFRAME_KEY;
    address public immutable OWNER;
    address public immutable SUBMITTER_A;
    address public immutable SUBMITTER_B;
    mapping(address submitter => uint64 submissions) public submissionsBySubmitter;
    mapping(bytes32 intentId => bool) public observedCancelledIntent;

    bytes32[] private _intentIds;
    mapping(bytes32 intentId => bool) public knownIntent;

    constructor(
        AlphaEngineIntentController controller_,
        uint128 marketId_,
        bytes32 timeframeKey_,
        address owner_,
        address submitterA_,
        address submitterB_
    ) {
        _bindMockTaskManager();
        CONTROLLER = controller_;
        MARKET_ID = marketId_;
        TIMEFRAME_KEY = timeframeKey_;
        OWNER = owner_;
        SUBMITTER_A = submitterA_;
        SUBMITTER_B = submitterB_;
    }

    function submitAsA(uint128 value, uint8 rawCount) external {
        _submit(SUBMITTER_A, value, rawCount);
    }

    function submitAsB(uint128 value, uint8 rawCount) external {
        _submit(SUBMITTER_B, value, rawCount);
    }

    function cancelAsOwner(uint8 rawIndex) external {
        if (_intentIds.length == 0) {
            return;
        }

        bytes32 intentId = _intentIds[bound(uint256(rawIndex), 0, _intentIds.length - 1)];
        vm.prank(OWNER);
        try CONTROLLER.cancelStrategyIntent(intentId) {
            observedCancelledIntent[intentId] = true;
        } catch {}
    }

    function cancelAsSubmitterA(uint8 rawIndex) external {
        if (_intentIds.length == 0) {
            return;
        }

        bytes32 intentId = _intentIds[bound(uint256(rawIndex), 0, _intentIds.length - 1)];
        vm.prank(SUBMITTER_A);
        try CONTROLLER.cancelStrategyIntent(intentId) {
            observedCancelledIntent[intentId] = true;
        } catch {}
    }

    function cancelAsSubmitterB(uint8 rawIndex) external {
        if (_intentIds.length == 0) {
            return;
        }

        bytes32 intentId = _intentIds[bound(uint256(rawIndex), 0, _intentIds.length - 1)];
        vm.prank(SUBMITTER_B);
        try CONTROLLER.cancelStrategyIntent(intentId) {
            observedCancelledIntent[intentId] = true;
        } catch {}
    }

    function intentIdsLength() external view returns (uint256) {
        return _intentIds.length;
    }

    function intentIdAt(uint256 index) external view returns (bytes32) {
        return _intentIds[index];
    }

    function _submit(address sender, uint128 value, uint8 rawCount) internal {
        uint256 count = bound(uint256(rawCount), 1, 16);
        InEuint128 memory input = createInEuint128(value, sender);
        InEuint128[] memory inputs = new InEuint128[](count);
        for (uint256 index = 0; index < count; ++index) {
            inputs[index] = input;
        }
        InEuint128 memory marketIdInput = createInEuint128(MARKET_ID, sender);

        vm.prank(sender);
        try CONTROLLER.submitStrategyIntent(
            marketIdInput,
            TIMEFRAME_KEY,
            inputs,
            uint40(block.timestamp) + 1 hours
        ) returns (bytes32 intentId) {
            if (!knownIntent[intentId]) {
                knownIntent[intentId] = true;
                _intentIds.push(intentId);
                submissionsBySubmitter[sender] += 1;
            }
        } catch {}
    }
}
