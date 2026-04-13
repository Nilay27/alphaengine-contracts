// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IAlphaEngineSwapExecutor {
    function executeExactInput(
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata executionData
    ) external returns (uint256 amountOut);
}
