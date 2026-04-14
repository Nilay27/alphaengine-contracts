// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAlphaEngineSwapExecutor} from "src/interfaces/IAlphaEngineSwapExecutor.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract MockMintingSwapExecutor is IAlphaEngineSwapExecutor {
    using SafeERC20 for IERC20;

    error OutputAmountBelowMinimum(uint256 minimumAmountOut, uint256 actualAmountOut);

    address internal constant INPUT_SINK = address(0xBEEF);

    function executeExactInput(
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata executionData
    ) external returns (uint256 amountOut) {
        amountOut = executionData.length == 0 ? amountIn : abi.decode(executionData, (uint256));
        if (amountOut < minAmountOut) {
            revert OutputAmountBelowMinimum(minAmountOut, amountOut);
        }

        IERC20(inputToken).safeTransfer(INPUT_SINK, amountIn);
        MockERC20(outputToken).mint(recipient, amountOut);
    }
}
