// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IAlphaEngineSwapExecutor} from "../interfaces/IAlphaEngineSwapExecutor.sol";

contract AlphaEngineV4SwapExecutor is Ownable, IUnlockCallback, IAlphaEngineSwapExecutor {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    struct ExactInputParams {
        PoolKey key;
        bool zeroForOne;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct CallbackData {
        PoolKey key;
        bool zeroForOne;
        uint160 sqrtPriceLimitX96;
        address inputToken;
        address outputToken;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        bytes hookData;
    }

    error ZeroPoolManager();
    error ZeroAuthorizedCaller();
    error UnauthorizedCaller(address caller);
    error InvalidPoolManagerCaller(address caller);
    error ZeroAmountIn();
    error ZeroRecipient();
    error InvalidInputToken(address inputToken);
    error InvalidOutputToken(address outputToken);
    error NativeCurrencyNotSupported();
    error InvalidSwapDirection(
        bool zeroForOne,
        address expectedInputToken,
        address expectedOutputToken,
        address actualCurrency0,
        address actualCurrency1
    );
    error UnexpectedInputAmount(uint256 expectedAmountIn, uint256 actualAmountIn);
    error ZeroOutputAmount();
    error OutputAmountBelowMinimum(uint256 minimumAmountOut, uint256 actualAmountOut);

    event AuthorizedCallerUpdated(address indexed previousCaller, address indexed newCaller);

    IPoolManager public immutable poolManager;
    address public authorizedCaller;

    constructor(IPoolManager poolManager_, address owner_, address authorizedCaller_)
        Ownable(owner_)
    {
        if (address(poolManager_) == address(0)) {
            revert ZeroPoolManager();
        }
        if (authorizedCaller_ == address(0)) {
            revert ZeroAuthorizedCaller();
        }

        poolManager = poolManager_;
        authorizedCaller = authorizedCaller_;
    }

    function setAuthorizedCaller(address newAuthorizedCaller) external onlyOwner {
        if (newAuthorizedCaller == address(0)) {
            revert ZeroAuthorizedCaller();
        }

        address previousCaller = authorizedCaller;
        authorizedCaller = newAuthorizedCaller;
        emit AuthorizedCallerUpdated(previousCaller, newAuthorizedCaller);
    }

    function executeExactInput(
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata executionData
    ) external override returns (uint256 amountOut) {
        if (msg.sender != authorizedCaller) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (amountIn == 0) {
            revert ZeroAmountIn();
        }
        if (recipient == address(0)) {
            revert ZeroRecipient();
        }
        if (inputToken == address(0)) {
            revert InvalidInputToken(inputToken);
        }
        if (outputToken == address(0)) {
            revert InvalidOutputToken(outputToken);
        }

        ExactInputParams memory params = abi.decode(executionData, (ExactInputParams));
        _validateCurrencies(params.key, params.zeroForOne, inputToken, outputToken);

        amountOut = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        key: params.key,
                        zeroForOne: params.zeroForOne,
                        sqrtPriceLimitX96: _priceLimit(params.zeroForOne, params.sqrtPriceLimitX96),
                        inputToken: inputToken,
                        outputToken: outputToken,
                        amountIn: amountIn,
                        minAmountOut: minAmountOut,
                        recipient: recipient,
                        hookData: params.hookData
                    })
                )
            ),
            (uint256)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert InvalidPoolManagerCaller(msg.sender);
        }

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta swapDelta = poolManager.swap(
            data.key,
            IPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -int256(data.amountIn),
                sqrtPriceLimitX96: data.sqrtPriceLimitX96
            }),
            data.hookData
        );

        uint256 inputAmountOwed;
        uint256 outputAmountReceived;
        int128 delta0 = swapDelta.amount0();
        int128 delta1 = swapDelta.amount1();

        if (data.zeroForOne) {
            if (delta0 >= 0 || delta1 <= 0) {
                revert InvalidSwapDirection(
                    data.zeroForOne,
                    data.inputToken,
                    data.outputToken,
                    Currency.unwrap(data.key.currency0),
                    Currency.unwrap(data.key.currency1)
                );
            }
            inputAmountOwed = uint256(uint128(-delta0));
            outputAmountReceived = uint256(uint128(delta1));
        } else {
            if (delta1 >= 0 || delta0 <= 0) {
                revert InvalidSwapDirection(
                    data.zeroForOne,
                    data.inputToken,
                    data.outputToken,
                    Currency.unwrap(data.key.currency0),
                    Currency.unwrap(data.key.currency1)
                );
            }
            inputAmountOwed = uint256(uint128(-delta1));
            outputAmountReceived = uint256(uint128(delta0));
        }

        if (inputAmountOwed != data.amountIn) {
            revert UnexpectedInputAmount(data.amountIn, inputAmountOwed);
        }
        if (outputAmountReceived == 0) {
            revert ZeroOutputAmount();
        }
        if (outputAmountReceived < data.minAmountOut) {
            revert OutputAmountBelowMinimum(data.minAmountOut, outputAmountReceived);
        }

        if (delta0 < 0) {
            _settleCurrency(data.key.currency0, uint256(uint128(-delta0)));
        }
        if (delta1 < 0) {
            _settleCurrency(data.key.currency1, uint256(uint128(-delta1)));
        }
        if (delta0 > 0) {
            poolManager.take(data.key.currency0, data.recipient, uint256(uint128(delta0)));
        }
        if (delta1 > 0) {
            poolManager.take(data.key.currency1, data.recipient, uint256(uint128(delta1)));
        }

        return abi.encode(outputAmountReceived);
    }

    function _settleCurrency(Currency currency, uint256 amount) private {
        if (currency == CurrencyLibrary.ADDRESS_ZERO) {
            revert NativeCurrencyNotSupported();
        }

        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _validateCurrencies(
        PoolKey memory key,
        bool zeroForOne,
        address inputToken,
        address outputToken
    ) private pure {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);

        if (currency0 == address(0) || currency1 == address(0)) {
            revert NativeCurrencyNotSupported();
        }

        bool validDirection = zeroForOne
            ? currency0 == inputToken && currency1 == outputToken
            : currency1 == inputToken && currency0 == outputToken;
        if (!validDirection) {
            revert InvalidSwapDirection(zeroForOne, inputToken, outputToken, currency0, currency1);
        }
    }

    function _priceLimit(bool zeroForOne, uint160 sqrtPriceLimitX96)
        private
        pure
        returns (uint160)
    {
        if (sqrtPriceLimitX96 != 0) {
            return sqrtPriceLimitX96;
        }

        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}
