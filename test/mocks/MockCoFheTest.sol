// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    externalEuint32,
    externalEuint64,
    externalEuint128
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {Utils} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";
import {MockCoFheTaskManager} from "test/mocks/MockCoFheTaskManager.sol";
import {
    AlphaEngineCompetitionStrategyManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {
    AlphaEngineCapitalStrategyManager
} from "src/strategy/AlphaEngineCapitalStrategyManager.sol";

abstract contract MockCoFheTest is Test {
    address internal constant TASK_MANAGER_ADDRESS = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;
    // Public test fixture key; never used for a network account.
    uint256 internal constant MOCK_VERIFIER_KEY = 0xC0F1E;
    MockCoFheTaskManager internal taskManager;
    uint256 private _nextCiphertextSalt;
    mapping(bytes32 => address) internal _inputSenders;

    function _installMockTaskManager() internal {
        MockCoFheTaskManager mockImplementation = new MockCoFheTaskManager();
        vm.etch(TASK_MANAGER_ADDRESS, address(mockImplementation).code);
        _bindMockTaskManager();
        taskManager.setVerifierSigner(vm.addr(MOCK_VERIFIER_KEY));
        vm.label(TASK_MANAGER_ADDRESS, "MockCoFheTaskManager");
    }

    function _bindMockTaskManager() internal {
        taskManager = MockCoFheTaskManager(TASK_MANAGER_ADDRESS);
    }

    function createExternalEuint128(uint128 value, address sender)
        internal
        returns (externalEuint128)
    {
        return externalEuint128.wrap(_registerInput(value, sender, Utils.EUINT128_TFHE));
    }

    function createExternalEuint32(uint32 value, address sender)
        internal
        returns (externalEuint32)
    {
        return externalEuint32.wrap(_registerInput(value, sender, Utils.EUINT32_TFHE));
    }

    function createExternalEuint64(uint64 value, address sender)
        internal
        returns (externalEuint64)
    {
        return externalEuint64.wrap(_registerInput(value, sender, Utils.EUINT64_TFHE));
    }

    function _registerInput(uint256 value, address sender, uint8 utype)
        private
        returns (bytes32 h)
    {
        h = keccak256(abi.encode(address(this), sender, value, _nextCiphertextSalt++));
        _inputSenders[h] = sender;
        taskManager.registerInput(uint256(h), sender, 0, utype, value);
    }

    function _strategyProof(
        address consumer,
        externalEuint128 market,
        externalEuint128[] memory components
    ) internal view returns (bytes memory) {
        bytes32[] memory hashes = new bytes32[](components.length + 1);
        hashes[0] = externalEuint128.unwrap(market);
        for (uint256 i; i < components.length; ++i) {
            hashes[i + 1] = externalEuint128.unwrap(components[i]);
        }
        return _signInputs(consumer, hashes, Utils.EUINT128_TFHE);
    }

    function _scoreProof(
        address consumer,
        externalEuint32 first,
        externalEuint32 second,
        externalEuint32 third
    ) internal view returns (bytes memory) {
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = externalEuint32.unwrap(first);
        hashes[1] = externalEuint32.unwrap(second);
        hashes[2] = externalEuint32.unwrap(third);
        return _signInputs(consumer, hashes, Utils.EUINT32_TFHE);
    }

    function _inputProof(address consumer, externalEuint64 input)
        internal
        view
        returns (bytes memory)
    {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = externalEuint64.unwrap(input);
        return _signInputs(consumer, hashes, Utils.EUINT64_TFHE);
    }

    function _withScoreProof(
        address consumer,
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores
    )
        internal
        view
        returns (AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory)
    {
        scores.inputProof = _scoreProof(
            consumer, scores.realSisterScore, scores.perturbationP25Score, scores.stressP25Score
        );
        return scores;
    }

    function _withScoreProof(
        address consumer,
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores
    ) internal view returns (AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory) {
        scores.inputProof = _scoreProof(
            consumer, scores.realSisterScore, scores.perturbationP25Score, scores.stressP25Score
        );
        return scores;
    }

    /// @dev Independently reproduce the raw v0.2.0 verifier digest (no personal-sign prefix).
    function _signInputs(address consumer, bytes32[] memory hashes, uint8 utype)
        private
        view
        returns (bytes memory)
    {
        address sender = _inputSenders[hashes[0]];
        for (uint256 i; i < hashes.length; ++i) {
            hashes[i] = keccak256(
                abi.encodePacked(
                    uint256(hashes[i]), utype, uint8(0), sender, block.chainid, consumer
                )
            );
        }
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(MOCK_VERIFIER_KEY, keccak256(abi.encodePacked(hashes)));
        return abi.encodePacked(r, s, v);
    }

    function mockStorage(uint256 ctHash) internal view returns (uint256) {
        return taskManager.mockValue(ctHash);
    }
}
