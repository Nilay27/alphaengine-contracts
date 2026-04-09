// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {AlphaEngineIntentControllerTestBase} from "test/mocks/AlphaEngineIntentControllerTestBase.sol";
import {IntentControllerInvariantHandler} from "test/mocks/IntentControllerInvariantHandler.sol";

contract AlphaEngineIntentControllerInvariantTest is AlphaEngineIntentControllerTestBase {
    IntentControllerInvariantHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new IntentControllerInvariantHandler(
            controller,
            market,
            DEFAULT_TIMEFRAME_KEY,
            owner,
            submitter,
            otherSubmitter
        );

        targetContract(address(handler));
    }

    function invariant_cancelledIntentNeverBecomesActiveAgain() public view {
        uint256 length = handler.intentIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.intentIdAt(index);
            AlphaEngineIntentController.IntentRecord memory intentRecord = controller.getIntent(intentId);
            if (intentRecord.status == AlphaEngineIntentController.IntentStatus.Cancelled) {
                assertEq(uint8(intentRecord.status), uint8(AlphaEngineIntentController.IntentStatus.Cancelled));
            }
        }
    }

    function invariant_storedHandleLengthMatchesComponentCount() public view {
        uint256 length = handler.intentIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.intentIdAt(index);
            AlphaEngineIntentController.IntentRecord memory intentRecord = controller.getIntent(intentId);
            assertEq(controller.getIntentComponentHandles(intentId).length, intentRecord.componentCount);
        }
    }

    function invariant_submitterNonceNeverDecreases() public view {
        assertEq(controller.submitterNonces(submitter), handler.submissionsBySubmitter(submitter));
        assertEq(
            controller.submitterNonces(otherSubmitter),
            handler.submissionsBySubmitter(otherSubmitter)
        );
    }

    function invariant_listenerOperatorNeverZero() public view {
        assertTrue(controller.listenerOperator() != address(0));
    }
}
