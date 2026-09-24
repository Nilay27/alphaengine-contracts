// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {
    AlphaEnginePendleV4PtDecoderAndSanitizer
} from "src/decoders/AlphaEnginePendleV4PtDecoderAndSanitizer.sol";
import {IAlphaEnginePendleRouterV4} from "src/interfaces/IAlphaEnginePendleRouterV4.sol";

contract ForkFundVaultCode {}

/// @notice Opt-in deterministic fork parity for the pinned official Pendle RouterV4 surface.
/// @dev Run with RUN_PENDLE_V4_FORK=true and an optional ARBITRUM_RPC_URL override.
contract AlphaEnginePendleV4DecoderForkTest is Test {
    uint256 private constant PINNED_BLOCK = 500_310_277;
    address private constant ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address private constant PT_FACET = 0xd8D200d9A713A1c71cF1e7F694B14E5F1D948b15;
    bytes32 private constant ROUTER_CODE_HASH =
        0x6e7e96418259651300fbc9b9035c0613bfefc601ddbd840ab39a068ab3ee4293;
    bytes32 private constant PT_FACET_CODE_HASH =
        0x5e98f3973c2fdabae1168b4afe928c16d4ca9d71803efeacd978fc3bb3898063;

    bool private runFork;

    function setUp() public {
        runFork = vm.envOr("RUN_PENDLE_V4_FORK", false);
        if (!runFork) return;

        string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc"));
        vm.createSelectFork(rpcUrl, PINNED_BLOCK);
    }

    function test_pinnedRouterV4FacetCodeAndDecoderAbiParity() public {
        if (!runFork) return;

        assertEq(ROUTER.codehash, ROUTER_CODE_HASH);
        assertEq(PT_FACET.codehash, PT_FACET_CODE_HASH);
        assertEq(
            IAlphaEnginePendleRouterV4(ROUTER)
                .selectorToFacet(IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector),
            PT_FACET
        );
        assertEq(
            IAlphaEnginePendleRouterV4(ROUTER)
                .selectorToFacet(IAlphaEnginePendleRouterV4.swapExactPtForToken.selector),
            PT_FACET
        );

        ForkFundVaultCode fundVault = new ForkFundVaultCode();
        AlphaEnginePendleV4PtDecoderAndSanitizer decoder = new AlphaEnginePendleV4PtDecoderAndSanitizer(
            address(fundVault), IAlphaEnginePendleRouterV4(ROUTER), PT_FACET
        );
        address market = address(0x1111);
        address token = address(0x2222);

        assertEq(
            decoder.sanitize(_tokenForPtData(address(fundVault), market, token)),
            abi.encode(address(fundVault), market, token)
        );
        assertEq(
            decoder.sanitize(_ptForTokenData(address(fundVault), market, token)),
            abi.encode(address(fundVault), market, token)
        );
    }

    function _tokenForPtData(address receiver, address market, address token)
        private
        pure
        returns (bytes memory)
    {
        IAlphaEnginePendleRouterV4.TokenInput memory input =
            IAlphaEnginePendleRouterV4.TokenInput({
                tokenIn: token,
                netTokenIn: 1_000_000,
                tokenMintSy: token,
                pendleSwap: address(0),
                swapData: _emptySwap()
            });
        return abi.encodeCall(
            IAlphaEnginePendleRouterV4.swapExactTokenForPt,
            (receiver, market, 990_000, _defaultApproximation(), input, _emptyLimit())
        );
    }

    function _ptForTokenData(address receiver, address market, address token)
        private
        pure
        returns (bytes memory)
    {
        IAlphaEnginePendleRouterV4.TokenOutput memory output =
            IAlphaEnginePendleRouterV4.TokenOutput({
                tokenOut: token,
                minTokenOut: 990_000,
                tokenRedeemSy: token,
                pendleSwap: address(0),
                swapData: _emptySwap()
            });
        return abi.encodeCall(
            IAlphaEnginePendleRouterV4.swapExactPtForToken,
            (receiver, market, 1_000_000, output, _emptyLimit())
        );
    }

    function _defaultApproximation()
        private
        pure
        returns (IAlphaEnginePendleRouterV4.ApproxParams memory approximation)
    {
        approximation = IAlphaEnginePendleRouterV4.ApproxParams({
            guessMin: 0, guessMax: type(uint256).max, guessOffchain: 0, maxIteration: 256, eps: 1e14
        });
    }

    function _emptySwap()
        private
        pure
        returns (IAlphaEnginePendleRouterV4.SwapData memory swapData)
    {
        swapData = IAlphaEnginePendleRouterV4.SwapData({
                swapType: IAlphaEnginePendleRouterV4.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            });
    }

    function _emptyLimit()
        private
        pure
        returns (IAlphaEnginePendleRouterV4.LimitOrderData memory limit)
    {
        limit = IAlphaEnginePendleRouterV4.LimitOrderData({
            limitRouter: address(0),
            epsSkipMarket: 0,
            normalFills: new IAlphaEnginePendleRouterV4.FillOrderParams[](0),
            flashFills: new IAlphaEnginePendleRouterV4.FillOrderParams[](0),
            optData: ""
        });
    }
}
