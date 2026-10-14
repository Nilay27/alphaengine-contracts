// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {MockFundVaultCallTarget} from "test/mocks/MockFundVaultExecution.sol";

contract FundVaultExecutionInvariantHandler {
    IAlphaEngineFundVault public immutable VAULT;
    MockFundVaultCallTarget public immutable TARGET;
    address public immutable ACCOUNTING_MANAGER;

    uint256 public ghostSuccessfulTotal;
    uint256 public successfulBatches;
    uint256 public failedBatches;
    uint256 public protectedCalls;
    bool public rollbackViolation;
    bool public protectedTargetViolation;

    constructor(
        IAlphaEngineFundVault vault,
        MockFundVaultCallTarget target,
        address accountingManager
    ) {
        VAULT = vault;
        TARGET = target;
        ACCOUNTING_MANAGER = accountingManager;
    }

    function executeSuccessful(uint96 first, uint96 second) external {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory targetData = new bytes[](2);
        targets[0] = address(TARGET);
        targets[1] = address(TARGET);
        targetData[0] = abi.encodeCall(MockFundVaultCallTarget.add, (first));
        targetData[1] = abi.encodeCall(MockFundVaultCallTarget.add, (second));

        VAULT.executeBatch(targets, values, targetData);
        ghostSuccessfulTotal += uint256(first) + uint256(second);
        successfulBatches += 1;
    }

    function executeFailing(uint96 first, uint96 failureValue) external {
        uint256 totalBefore = TARGET.total();
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory targetData = new bytes[](2);
        targets[0] = address(TARGET);
        targets[1] = address(TARGET);
        targetData[0] = abi.encodeCall(MockFundVaultCallTarget.add, (first));
        targetData[1] = abi.encodeCall(MockFundVaultCallTarget.fail, (failureValue));

        (bool success, bytes memory revertData) = address(VAULT).call(
            abi.encodeCall(IAlphaEngineFundVault.executeBatch, (targets, values, targetData))
        );
        if (
            success || _selector(revertData) != AlphaEngineFundVault.BatchCallFailed.selector
                || TARGET.total() != totalBefore
        ) {
            rollbackViolation = true;
        }
        failedBatches += 1;
    }

    function attemptProtectedAccountingCall(bytes32 seed) external {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory targetData = new bytes[](1);
        targets[0] = ACCOUNTING_MANAGER;
        targetData[0] = abi.encode(seed);

        (bool success, bytes memory revertData) = address(VAULT).call(
            abi.encodeCall(IAlphaEngineFundVault.executeBatch, (targets, values, targetData))
        );
        if (success || _selector(revertData) != AlphaEngineFundVault.ProtectedBatchTarget.selector)
        {
            protectedTargetViolation = true;
        }
        protectedCalls += 1;
    }

    function _selector(bytes memory revertData) private pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
    }
}
