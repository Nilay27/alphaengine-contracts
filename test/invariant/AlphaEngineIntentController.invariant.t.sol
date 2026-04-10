// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {AlphaEngineIntentControllerTestBase} from "test/mocks/AlphaEngineIntentControllerTestBase.sol";
import {IntentControllerInvariantHandler} from "test/handlers/IntentControllerInvariantHandler.sol";

contract AlphaEngineIntentControllerInvariantTest is AlphaEngineIntentControllerTestBase {
    IntentControllerInvariantHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new IntentControllerInvariantHandler(
            controller,
            DEFAULT_MARKET_ID,
            DEFAULT_TIMEFRAME_KEY,
            owner,
            submitter,
            otherSubmitter
        );

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = IntentControllerInvariantHandler.submitAsA.selector;
        selectors[1] = IntentControllerInvariantHandler.submitAsB.selector;
        selectors[2] = IntentControllerInvariantHandler.cancelAsOwner.selector;
        selectors[3] = IntentControllerInvariantHandler.cancelAsSubmitterA.selector;
        selectors[4] = IntentControllerInvariantHandler.cancelAsSubmitterB.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_cancelledIntentNeverBecomesActiveAgain() public view {
        uint256 length = handler.intentIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.intentIdAt(index);
            AlphaEngineIntentController.IntentRecord memory intentRecord = controller.getIntent(intentId);
            if (handler.observedCancelledIntent(intentId)) {
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
