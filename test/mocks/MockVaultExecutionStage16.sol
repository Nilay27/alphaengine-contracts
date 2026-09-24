// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    IAlphaEngineCapitalStrategyManager
} from "src/interfaces/IAlphaEngineCapitalStrategyManager.sol";
import {IAlphaEngineDecoderAndSanitizer} from "src/interfaces/IAlphaEngineDecoderAndSanitizer.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";

contract MockCapitalStrategyManagerStage16 is IAlphaEngineCapitalStrategyManager {
    mapping(bytes32 intentId => bytes32 commitment) public approvedCommitments;
    mapping(bytes32 commitment => bool consumed) public consumedCommitments;
    bool public returnWrongCommitment;

    error CommitmentNotApproved(bytes32 supplied, bytes32 approved);
    error CommitmentAlreadyConsumed(bytes32 commitment);

    function approve(AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization)
        external
        returns (bytes32 commitment)
    {
        commitment = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);
        approvedCommitments[authorization.intentId] = commitment;
    }

    function setReturnWrongCommitment(bool enabled) external {
        returnWrongCommitment = enabled;
    }

    function consumeCapitalExecution(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization
    ) external returns (bytes32 executionCommitment) {
        executionCommitment = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);
        bytes32 approved = approvedCommitments[authorization.intentId];
        if (executionCommitment != approved) {
            revert CommitmentNotApproved(executionCommitment, approved);
        }
        if (consumedCommitments[executionCommitment]) {
            revert CommitmentAlreadyConsumed(executionCommitment);
        }
        consumedCommitments[executionCommitment] = true;
        if (returnWrongCommitment) return bytes32(uint256(executionCommitment) ^ 1);
    }

    function getApprovedExecutionCommitment(bytes32 intentId)
        external
        view
        returns (bytes32 executionCommitment)
    {
        return approvedCommitments[intentId];
    }

    function isExecutionConsumed(bytes32 executionCommitment) external view returns (bool) {
        return consumedCommitments[executionCommitment];
    }
}

contract MockStrategyActionDecoder is IAlphaEngineDecoderAndSanitizer {
    bytes4 public constant SWAP_SELECTOR = MockVaultStrategyTarget.swapExact.selector;

    error MalformedSwapCalldata(uint256 suppliedLength);
    error ZeroSwapAsset();

    function sanitize(bytes calldata targetData)
        external
        pure
        returns (bytes memory sanitizedArguments)
    {
        if (targetData.length < 4) revert CalldataTooShort(targetData.length);
        bytes4 selector = bytes4(targetData[:4]);
        if (selector != SWAP_SELECTOR) revert UnsupportedSelector(selector);
        if (targetData.length != 4 + 32 * 4) revert MalformedSwapCalldata(targetData.length);
        (address assetIn, address assetOut,,) =
            abi.decode(targetData[4:], (address, address, uint256, uint256));
        if (assetIn == address(0) || assetOut == address(0)) revert ZeroSwapAsset();
        sanitizedArguments = abi.encode(assetIn, assetOut);
    }
}

contract MockVaultStrategyTarget {
    using SafeERC20 for IERC20;

    error ForcedFailure();

    function swapExact(address assetIn, address assetOut, uint256 amountIn, uint256 amountOut)
        external
    {
        IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(assetOut).safeTransfer(msg.sender, amountOut);
    }

    function fail() external pure {
        revert ForcedFailure();
    }
}
