// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AlphaEngineExecutionHashLib} from "../libraries/AlphaEngineExecutionHashLib.sol";

interface IAlphaEngineCapitalStrategyManager {
    function consumeCapitalExecution(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization
    ) external returns (bytes32 executionCommitment);

    function getApprovedExecutionCommitment(bytes32 intentId)
        external
        view
        returns (bytes32 executionCommitment);

    function isExecutionConsumed(bytes32 executionCommitment) external view returns (bool);
}
