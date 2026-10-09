// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";

contract MockFundVaultExecutionManager {
    address public immutable AUTHORIZED_CALLER;

    error UnauthorizedCaller(address caller);

    constructor(address authorizedCaller) {
        AUTHORIZED_CALLER = authorizedCaller;
    }

    function executeBatch(
        IAlphaEngineFundVault vault,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata targetData
    ) external returns (bytes[] memory results) {
        if (msg.sender != AUTHORIZED_CALLER) {
            revert UnauthorizedCaller(msg.sender);
        }
        results = vault.executeBatch(targets, values, targetData);
    }
}

contract MockFundVaultCallTarget {
    uint256 public total;

    error ForcedFailure(uint256 supplied);

    function add(uint256 amount) external payable returns (uint256 newTotal) {
        total += amount;
        return total;
    }

    function fail(uint256 supplied) external pure {
        revert ForcedFailure(supplied);
    }
}

contract MockRecoveryVault {}
