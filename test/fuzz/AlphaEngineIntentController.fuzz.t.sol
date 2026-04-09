// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {AlphaEngineIntentControllerTestBase} from "test/mocks/AlphaEngineIntentControllerTestBase.sol";

contract AlphaEngineIntentControllerFuzzTest is AlphaEngineIntentControllerTestBase {
    function testFuzz_nonceMonotonicityAcrossRepeatedSubmits(uint128 firstValue, uint128 secondValue) public {
        InEuint128[] memory firstInputs = _singleInput(firstValue, submitter);
        InEuint128[] memory secondInputs = _singleInput(secondValue, submitter);

        bytes32 firstIntentId = _submit(
            submitter,
            market,
            DEFAULT_TIMEFRAME_KEY,
            firstInputs,
            _deadlineAhead(10)
        );
        bytes32 secondIntentId = _submit(
            submitter,
            market,
            DEFAULT_TIMEFRAME_KEY,
            secondInputs,
            _deadlineAhead(20)
        );

        AlphaEngineIntentController.IntentRecord memory firstRecord = controller.getIntent(firstIntentId);
        AlphaEngineIntentController.IntentRecord memory secondRecord = controller.getIntent(secondIntentId);

        assertEq(firstRecord.submitterNonce, 0);
        assertEq(secondRecord.submitterNonce, 1);
        assertEq(controller.submitterNonces(submitter), 2);
    }

    function testFuzz_intentIdUniquenessAcrossNonceProgression(uint128 value, uint8 extraSubmits) public {
        uint256 submitCount = bound(uint256(extraSubmits), 1, 8);
        uint128 boundedValue = uint128(bound(uint256(value), 0, type(uint128).max - submitCount));
        bytes32 previousIntentId;

        for (uint256 index = 0; index < submitCount; ++index) {
            bytes32 intentId = _submit(
                submitter,
                market,
                DEFAULT_TIMEFRAME_KEY,
                // forge-lint: disable-next-line(unsafe-typecast)
                _singleInput(boundedValue + uint128(index), submitter),
                // forge-lint: disable-next-line(unsafe-typecast)
                _deadlineAhead(uint40(index + 1))
            );

            if (index > 0) {
                assertTrue(intentId != previousIntentId);
            }
            previousIntentId = intentId;
        }

        assertEq(controller.submitterNonces(submitter), submitCount);
    }

    function testFuzz_componentCountBounds(uint128 value, uint8 rawCount) public {
        uint256 count = bound(uint256(rawCount), 1, 16);
        InEuint128[] memory inputs = _repeatedInputs(value, count, submitter);
        bytes32 intentId = _submit(
            submitter,
            market,
            DEFAULT_TIMEFRAME_KEY,
            inputs,
            _deadlineAhead(1)
        );

        assertEq(controller.getIntent(intentId).componentCount, count);
        assertEq(controller.getIntentComponentHandles(intentId).length, count);
    }

    function testFuzz_unauthorizedCancellationRejection(address attacker, uint128 value) public {
        vm.assume(attacker != address(0));
        vm.assume(attacker != submitter);
        vm.assume(attacker != owner);
        vm.assume(attacker != _proxyAdmin());

        bytes32 intentId = _submit(
            submitter,
            market,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(value, submitter),
            _deadlineAhead(1)
        );

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.UnauthorizedCancel.selector,
                attacker,
                intentId
            )
        );
        controller.cancelStrategyIntent(intentId);
    }
}
