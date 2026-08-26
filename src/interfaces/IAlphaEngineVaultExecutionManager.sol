// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AlphaEngineExecutionHashLib} from "../libraries/AlphaEngineExecutionHashLib.sol";

interface IAlphaEngineVaultExecutionManager {
    function executeCapitalIntent(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization,
        AlphaEngineExecutionHashLib.CallV1[] calldata calls,
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] calldata limits,
        bytes32[][] calldata proofs
    ) external;
}
