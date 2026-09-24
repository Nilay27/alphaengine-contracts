// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAlphaEngineSwapExecutor} from "src/interfaces/IAlphaEngineSwapExecutor.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract MockBoundSwapExecutor is IAlphaEngineSwapExecutor {
    using SafeERC20 for IERC20;

    error UnauthorizedCaller(address caller);
    error OutputAmountBelowMinimum(uint256 minimumAmountOut, uint256 actualAmountOut);

    address internal constant INPUT_SINK = address(0xBEEF);

    address public immutable authorizedCaller;

    constructor(address authorizedCaller_) {
        authorizedCaller = authorizedCaller_;
    }

    function executeExactInput(
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata executionData
    ) external returns (uint256 amountOut) {
        if (msg.sender != authorizedCaller) {
            revert UnauthorizedCaller(msg.sender);
        }

        amountOut = abi.decode(executionData, (uint256));
        if (amountOut < minAmountOut) {
            revert OutputAmountBelowMinimum(minAmountOut, amountOut);
        }

        IERC20(inputToken).safeTransfer(INPUT_SINK, amountIn);
        MockERC20(outputToken).mint(recipient, amountOut);
    }
}
