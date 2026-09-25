// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAlphaEngineDecoderAndSanitizer} from "../interfaces/IAlphaEngineDecoderAndSanitizer.sol";
import {IAlphaEnginePendleRouterV4} from "../interfaces/IAlphaEnginePendleRouterV4.sol";

/// @notice Fail-closed sanitizer for direct, no-aggregator Pendle RouterV4 PT entry and exit.
/// @dev Pendle RouterV4 dispatches selectors to mutable facets. The immutable decoder bytecode
///      binds the expected router, PT facet, and both deployment-time code hashes, and every call
///      rechecks the live selector mapping and hashes before decoding policy arguments.
contract AlphaEnginePendleV4PtDecoderAndSanitizer is IAlphaEngineDecoderAndSanitizer {
    uint256 public constant MAX_CALLDATA_LENGTH = 4096;
    uint256 public constant MIN_TOKEN_FOR_PT_CALLDATA_LENGTH = 900;
    uint256 public constant MIN_PT_FOR_TOKEN_CALLDATA_LENGTH = 740;
    uint256 public constant MAX_APPROX_ITERATIONS = 256;
    uint256 public constant MAX_APPROX_EPS = 1e18;

    address public immutable FUND_VAULT;
    IAlphaEnginePendleRouterV4 public immutable PENDLE_ROUTER;
    address public immutable EXPECTED_PT_FACET;
    bytes32 public immutable EXPECTED_ROUTER_CODE_HASH;
    bytes32 public immutable EXPECTED_PT_FACET_CODE_HASH;

    error InvalidContract(address account);
    error MalformedCalldata(bytes4 selector, uint256 suppliedLength, uint256 minimumLength);
    error CalldataTooLarge(uint256 suppliedLength, uint256 maximumLength);
    error NonCanonicalCalldata(bytes4 selector);
    error DependencyCodeHashChanged(address dependency, bytes32 expected, bytes32 actual);
    error UnexpectedSelectorFacet(bytes4 selector, address expected, address actual);
    error InvalidReceiver(address supplied, address expected);
    error ZeroMarket();
    error ZeroToken();
    error ZeroAmount(bytes4 selector);
    error ZeroMinimumOutput(bytes4 selector);
    error MismatchedSyToken(address token, address syToken);
    error AggregatorNotPermitted();
    error LimitOrdersNotPermitted();
    error InvalidApproximation(
        uint256 guessMin, uint256 guessMax, uint256 guessOffchain, uint256 maxIteration, uint256 eps
    );

    constructor(address fundVault_, IAlphaEnginePendleRouterV4 pendleRouter_, address ptFacet_) {
        if (fundVault_ == address(0) || fundVault_.code.length == 0) {
            revert InvalidContract(fundVault_);
        }
        if (address(pendleRouter_) == address(0) || address(pendleRouter_).code.length == 0) {
            revert InvalidContract(address(pendleRouter_));
        }
        if (ptFacet_ == address(0) || ptFacet_.code.length == 0) {
            revert InvalidContract(ptFacet_);
        }

        FUND_VAULT = fundVault_;
        PENDLE_ROUTER = pendleRouter_;
        EXPECTED_PT_FACET = ptFacet_;
        EXPECTED_ROUTER_CODE_HASH = address(pendleRouter_).codehash;
        EXPECTED_PT_FACET_CODE_HASH = ptFacet_.codehash;

        _checkSelectorFacet(IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector);
        _checkSelectorFacet(IAlphaEnginePendleRouterV4.swapExactPtForToken.selector);
    }

    function sanitize(bytes calldata targetData)
        external
        view
        returns (bytes memory sanitizedArguments)
    {
        if (targetData.length < 4) revert CalldataTooShort(targetData.length);
        if (targetData.length > MAX_CALLDATA_LENGTH) {
            revert CalldataTooLarge(targetData.length, MAX_CALLDATA_LENGTH);
        }

        bytes4 selector = bytes4(targetData[:4]);
        if (
            selector != IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector
                && selector != IAlphaEnginePendleRouterV4.swapExactPtForToken.selector
        ) {
            revert UnsupportedSelector(selector);
        }

        _checkDependencies(selector);
        if (selector == IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector) {
            if (targetData.length < MIN_TOKEN_FOR_PT_CALLDATA_LENGTH) {
                revert MalformedCalldata(
                    selector, targetData.length, MIN_TOKEN_FOR_PT_CALLDATA_LENGTH
                );
            }
            return _sanitizeTokenForPt(targetData);
        }
        if (targetData.length < MIN_PT_FOR_TOKEN_CALLDATA_LENGTH) {
            revert MalformedCalldata(selector, targetData.length, MIN_PT_FOR_TOKEN_CALLDATA_LENGTH);
        }
        return _sanitizePtForToken(targetData);
    }

    function _sanitizeTokenForPt(bytes calldata targetData)
        private
        view
        returns (bytes memory sanitizedArguments)
    {
        (
            address receiver,
            address market,
            uint256 minPtOut,
            IAlphaEnginePendleRouterV4.ApproxParams memory approximation,
            IAlphaEnginePendleRouterV4.TokenInput memory input,
            IAlphaEnginePendleRouterV4.LimitOrderData memory limit
        ) = abi.decode(
            targetData[4:],
            (
                address,
                address,
                uint256,
                IAlphaEnginePendleRouterV4.ApproxParams,
                IAlphaEnginePendleRouterV4.TokenInput,
                IAlphaEnginePendleRouterV4.LimitOrderData
            )
        );

        bytes memory canonical = abi.encodeWithSelector(
            IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector,
            receiver,
            market,
            minPtOut,
            approximation,
            input,
            limit
        );
        _requireCanonical(targetData, canonical);
        _validateCommon(receiver, market, limit);
        if (input.netTokenIn == 0) {
            revert ZeroAmount(IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector);
        }
        if (minPtOut == 0) {
            revert ZeroMinimumOutput(IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector);
        }
        if (input.tokenIn == address(0)) revert ZeroToken();
        if (input.tokenIn != input.tokenMintSy) {
            revert MismatchedSyToken(input.tokenIn, input.tokenMintSy);
        }
        _validateNoAggregator(input.pendleSwap, input.swapData);
        _validateApproximation(approximation);

        sanitizedArguments = abi.encode(receiver, market, input.tokenIn);
    }

    function _sanitizePtForToken(bytes calldata targetData)
        private
        view
        returns (bytes memory sanitizedArguments)
    {
        (
            address receiver,
            address market,
            uint256 exactPtIn,
            IAlphaEnginePendleRouterV4.TokenOutput memory output,
            IAlphaEnginePendleRouterV4.LimitOrderData memory limit
        ) = abi.decode(
            targetData[4:],
            (
                address,
                address,
                uint256,
                IAlphaEnginePendleRouterV4.TokenOutput,
                IAlphaEnginePendleRouterV4.LimitOrderData
            )
        );

        bytes memory canonical = abi.encodeWithSelector(
            IAlphaEnginePendleRouterV4.swapExactPtForToken.selector,
            receiver,
            market,
            exactPtIn,
            output,
            limit
        );
        _requireCanonical(targetData, canonical);
        _validateCommon(receiver, market, limit);
        if (exactPtIn == 0) {
            revert ZeroAmount(IAlphaEnginePendleRouterV4.swapExactPtForToken.selector);
        }
        if (output.minTokenOut == 0) {
            revert ZeroMinimumOutput(IAlphaEnginePendleRouterV4.swapExactPtForToken.selector);
        }
        if (output.tokenOut == address(0)) revert ZeroToken();
        if (output.tokenOut != output.tokenRedeemSy) {
            revert MismatchedSyToken(output.tokenOut, output.tokenRedeemSy);
        }
        _validateNoAggregator(output.pendleSwap, output.swapData);

        sanitizedArguments = abi.encode(receiver, market, output.tokenOut);
    }

    function _validateCommon(
        address receiver,
        address market,
        IAlphaEnginePendleRouterV4.LimitOrderData memory limit
    ) private view {
        if (receiver != FUND_VAULT) revert InvalidReceiver(receiver, FUND_VAULT);
        if (market == address(0)) revert ZeroMarket();
        if (
            limit.limitRouter != address(0) || limit.epsSkipMarket != 0
                || limit.normalFills.length != 0 || limit.flashFills.length != 0
                || limit.optData.length != 0
        ) {
            revert LimitOrdersNotPermitted();
        }
    }

    function _validateNoAggregator(
        address pendleSwap,
        IAlphaEnginePendleRouterV4.SwapData memory swapData
    ) private pure {
        if (
            pendleSwap != address(0)
                || swapData.swapType != IAlphaEnginePendleRouterV4.SwapType.NONE
                || swapData.extRouter != address(0) || swapData.extCalldata.length != 0
                || swapData.needScale
        ) {
            revert AggregatorNotPermitted();
        }
    }

    function _validateApproximation(IAlphaEnginePendleRouterV4.ApproxParams memory approximation)
        private
        pure
    {
        bool invalid = approximation.guessMax == 0
            || approximation.guessMin > approximation.guessMax
            || (
                approximation.guessOffchain != 0
                    && (
                        approximation.guessOffchain < approximation.guessMin
                            || approximation.guessOffchain > approximation.guessMax
                    )
            ) || approximation.maxIteration == 0 || approximation.maxIteration > MAX_APPROX_ITERATIONS
            || approximation.eps == 0 || approximation.eps > MAX_APPROX_EPS;
        if (invalid) {
            revert InvalidApproximation(
                approximation.guessMin,
                approximation.guessMax,
                approximation.guessOffchain,
                approximation.maxIteration,
                approximation.eps
            );
        }
    }

    function _requireCanonical(bytes calldata targetData, bytes memory canonical) private pure {
        if (targetData.length != canonical.length || keccak256(targetData) != keccak256(canonical))
        {
            revert NonCanonicalCalldata(bytes4(targetData[:4]));
        }
    }

    function _checkDependencies(bytes4 selector) private view {
        bytes32 routerCodeHash = address(PENDLE_ROUTER).codehash;
        if (routerCodeHash != EXPECTED_ROUTER_CODE_HASH) {
            revert DependencyCodeHashChanged(
                address(PENDLE_ROUTER), EXPECTED_ROUTER_CODE_HASH, routerCodeHash
            );
        }
        bytes32 facetCodeHash = EXPECTED_PT_FACET.codehash;
        if (facetCodeHash != EXPECTED_PT_FACET_CODE_HASH) {
            revert DependencyCodeHashChanged(
                EXPECTED_PT_FACET, EXPECTED_PT_FACET_CODE_HASH, facetCodeHash
            );
        }
        _checkSelectorFacet(selector);
    }

    function _checkSelectorFacet(bytes4 selector) private view {
        address actual = PENDLE_ROUTER.selectorToFacet(selector);
        if (actual != EXPECTED_PT_FACET) {
            revert UnexpectedSelectorFacet(selector, EXPECTED_PT_FACET, actual);
        }
    }
}
