// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAlphaEngineCapitalStrategyManager} from
    "src/interfaces/IAlphaEngineCapitalStrategyManager.sol";
import {IAlphaEngineVaultExecutionManager} from
    "src/interfaces/IAlphaEngineVaultExecutionManager.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";

/// @notice Stage-6 integration consumer proving the capital-consumption boundary.
/// @dev It deliberately performs no vault calls; the real Merkle/vault behavior is second pass.
contract MockVaultExecutionManager is IAlphaEngineVaultExecutionManager {
    error UnauthorizedExecutor(address actor, address expectedExecutor);
    error ForcedDownstreamFailure();

    IAlphaEngineCapitalStrategyManager public immutable CAPITAL_MANAGER;
    bytes32 public lastExecutionCommitment;
    uint256 public successfulExecutions;

    constructor(IAlphaEngineCapitalStrategyManager capitalManager) {
        CAPITAL_MANAGER = capitalManager;
    }

    function executeCapitalIntent(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization,
        AlphaEngineExecutionHashLib.CallV1[] calldata,
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] calldata,
        bytes32[][] calldata
    ) external {
        _requireExecutor(authorization.executor);
        bytes32 executionCommitment = CAPITAL_MANAGER.consumeCapitalExecution(authorization);
        lastExecutionCommitment = executionCommitment;
        successfulExecutions += 1;
    }

    function executeThenRevert(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization
    ) external {
        _requireExecutor(authorization.executor);
        CAPITAL_MANAGER.consumeCapitalExecution(authorization);
        revert ForcedDownstreamFailure();
    }

    function consumeWithoutVaultAction(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization
    ) external returns (bytes32 executionCommitment) {
        _requireExecutor(authorization.executor);
        executionCommitment = CAPITAL_MANAGER.consumeCapitalExecution(authorization);
        lastExecutionCommitment = executionCommitment;
        successfulExecutions += 1;
    }

    function _requireExecutor(address expectedExecutor) private view {
        if (msg.sender != expectedExecutor) {
            revert UnauthorizedExecutor(msg.sender, expectedExecutor);
        }
    }
}

contract MockFundVault {}
