// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {Utils} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";
import {MockCoFheTaskManager} from "test/mocks/MockCoFheTaskManager.sol";

abstract contract MockCoFheTest is Test {
    address internal constant TASK_MANAGER_ADDRESS = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    MockCoFheTaskManager internal taskManager;
    uint256 private _nextCiphertextSalt;

    function _installMockTaskManager() internal {
        MockCoFheTaskManager mockImplementation = new MockCoFheTaskManager();
        vm.etch(TASK_MANAGER_ADDRESS, address(mockImplementation).code);
        _bindMockTaskManager();
        vm.label(TASK_MANAGER_ADDRESS, "MockCoFheTaskManager");
    }

    function _bindMockTaskManager() internal {
        taskManager = MockCoFheTaskManager(TASK_MANAGER_ADDRESS);
    }

    function createInEuint128(uint128 value, address sender) internal returns (InEuint128 memory input) {
        uint256 ctHash = uint256(keccak256(abi.encode(sender, value, _nextCiphertextSalt)));
        _nextCiphertextSalt += 1;

        bytes memory signature = abi.encode(sender, value, ctHash);
        taskManager.registerInput(ctHash, sender, 0, Utils.EUINT128_TFHE, value, signature);

        input = InEuint128({
            ctHash: ctHash,
            securityZone: 0,
            utype: Utils.EUINT128_TFHE,
            signature: signature
        });
    }

    function mockStorage(uint256 ctHash) internal view returns (uint256) {
        return taskManager.mockValue(ctHash);
    }
}
