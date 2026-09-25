// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AlphaEngineERC20DecoderAndSanitizer} from
    "src/decoders/AlphaEngineERC20DecoderAndSanitizer.sol";
import {AlphaEngineERC4626DecoderAndSanitizer} from
    "src/decoders/AlphaEngineERC4626DecoderAndSanitizer.sol";
import {AlphaEnginePendleV4PtDecoderAndSanitizer} from
    "src/decoders/AlphaEnginePendleV4PtDecoderAndSanitizer.sol";
import {IAlphaEngineDecoderAndSanitizer} from "src/interfaces/IAlphaEngineDecoderAndSanitizer.sol";
import {IAlphaEnginePendleRouterV4} from "src/interfaces/IAlphaEnginePendleRouterV4.sol";

contract DecoderTestCode {}

contract MockPendleRouterV4 {
    mapping(bytes4 selector => address facet) private facets;

    function setFacet(bytes4 selector, address facet) external {
        facets[selector] = facet;
    }

    function selectorToFacet(bytes4 selector) external view returns (address facet) {
        facet = facets[selector];
    }
}

contract AlphaEngineDecoderAndSanitizerTest is Test {
    address private constant SPENDER = address(0xA11CE);
    address private constant MARKET = address(0xBEEF);
    address private constant TOKEN = address(0xC0FFEE);
    address private constant OTHER = address(0xBAD);

    DecoderTestCode private fundVault;
    DecoderTestCode private ptFacet;
    MockPendleRouterV4 private router;
    AlphaEngineERC20DecoderAndSanitizer private erc20Decoder;
    AlphaEngineERC4626DecoderAndSanitizer private erc4626Decoder;
    AlphaEnginePendleV4PtDecoderAndSanitizer private pendleDecoder;

    function setUp() public {
        fundVault = new DecoderTestCode();
        ptFacet = new DecoderTestCode();
        router = new MockPendleRouterV4();
        router.setFacet(IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector, address(ptFacet));
        router.setFacet(IAlphaEnginePendleRouterV4.swapExactPtForToken.selector, address(ptFacet));

        erc20Decoder = new AlphaEngineERC20DecoderAndSanitizer();
        erc4626Decoder = new AlphaEngineERC4626DecoderAndSanitizer(address(fundVault));
        pendleDecoder = new AlphaEnginePendleV4PtDecoderAndSanitizer(
            address(fundVault), IAlphaEnginePendleRouterV4(address(router)), address(ptFacet)
        );
    }

    function test_officialPendleV4SelectorsAreLocked() public pure {
        assertEq(IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector, bytes4(0xc81f847a));
        assertEq(IAlphaEnginePendleRouterV4.swapExactPtForToken.selector, bytes4(0x594a88cc));
    }

    function test_erc20ApproveAndResetReturnOnlySpender() public view {
        bytes memory approved =
            erc20Decoder.sanitize(abi.encodeCall(IERC20.approve, (SPENDER, uint256(123_456))));
        bytes memory reset = erc20Decoder.sanitize(abi.encodeCall(IERC20.approve, (SPENDER, 0)));

        assertEq(approved, abi.encode(SPENDER));
        assertEq(reset, abi.encode(SPENDER));
    }

    function testFuzz_erc20ApprovalAmountCannotChangePolicyArguments(
        address spender,
        uint256 amount
    ) public view {
        spender = address(uint160(bound(uint160(spender), 1, type(uint160).max)));
        amount = bound(amount, 0, type(uint256).max - 1);

        assertEq(
            erc20Decoder.sanitize(abi.encodeCall(IERC20.approve, (spender, amount))),
            abi.encode(spender)
        );
    }

    function test_erc20FailsClosedForZeroUnlimitedUnsupportedAndMalformedCalls() public {
        vm.expectRevert(AlphaEngineERC20DecoderAndSanitizer.ZeroSpender.selector);
        erc20Decoder.sanitize(abi.encodeCall(IERC20.approve, (address(0), 1)));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineERC20DecoderAndSanitizer.UnlimitedApprovalNotPermitted.selector, SPENDER
            )
        );
        erc20Decoder.sanitize(abi.encodeCall(IERC20.approve, (SPENDER, type(uint256).max)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphaEngineDecoderAndSanitizer.UnsupportedSelector.selector,
                IERC20.transfer.selector
            )
        );
        erc20Decoder.sanitize(abi.encodeCall(IERC20.transfer, (SPENDER, 1)));

        vm.expectRevert(
            abi.encodeWithSelector(IAlphaEngineDecoderAndSanitizer.CalldataTooShort.selector, 3)
        );
        erc20Decoder.sanitize(hex"010203");

        bytes memory canonical = abi.encodeCall(IERC20.approve, (SPENDER, 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineERC20DecoderAndSanitizer.MalformedCalldata.selector,
                IERC20.approve.selector,
                canonical.length + 1,
                canonical.length
            )
        );
        erc20Decoder.sanitize(bytes.concat(canonical, hex"00"));
    }

    function test_erc4626EntryAndExitReturnOnlyFundVaultAddresses() public view {
        address vault = address(fundVault);

        assertEq(
            erc4626Decoder.sanitize(abi.encodeCall(IERC4626.deposit, (100, vault))),
            abi.encode(vault)
        );
        assertEq(
            erc4626Decoder.sanitize(abi.encodeCall(IERC4626.mint, (100, vault))), abi.encode(vault)
        );
        assertEq(
            erc4626Decoder.sanitize(abi.encodeCall(IERC4626.withdraw, (100, vault, vault))),
            abi.encode(vault, vault)
        );
        assertEq(
            erc4626Decoder.sanitize(abi.encodeCall(IERC4626.redeem, (100, vault, vault))),
            abi.encode(vault, vault)
        );
    }

    function testFuzz_erc4626AmountsCannotChangePolicyArguments(uint256 amount) public view {
        amount = bound(amount, 1, type(uint256).max);
        address vault = address(fundVault);

        assertEq(
            erc4626Decoder.sanitize(abi.encodeCall(IERC4626.deposit, (amount, vault))),
            abi.encode(vault)
        );
        assertEq(
            erc4626Decoder.sanitize(abi.encodeCall(IERC4626.redeem, (amount, vault, vault))),
            abi.encode(vault, vault)
        );
    }

    function test_erc4626ConstructorAndAllRecipientBoundariesFailClosed() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineERC4626DecoderAndSanitizer.InvalidFundVault.selector, address(0)
            )
        );
        new AlphaEngineERC4626DecoderAndSanitizer(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineERC4626DecoderAndSanitizer.InvalidFundVault.selector, OTHER
            )
        );
        new AlphaEngineERC4626DecoderAndSanitizer(OTHER);

        vm.expectPartialRevert(AlphaEngineERC4626DecoderAndSanitizer.InvalidReceiver.selector);
        erc4626Decoder.sanitize(abi.encodeCall(IERC4626.deposit, (1, OTHER)));

        vm.expectPartialRevert(AlphaEngineERC4626DecoderAndSanitizer.InvalidReceiver.selector);
        erc4626Decoder.sanitize(abi.encodeCall(IERC4626.withdraw, (1, OTHER, address(fundVault))));

        vm.expectPartialRevert(AlphaEngineERC4626DecoderAndSanitizer.InvalidOwner.selector);
        erc4626Decoder.sanitize(abi.encodeCall(IERC4626.redeem, (1, address(fundVault), OTHER)));
    }

    function test_erc4626AllZeroAmountBranchesFailClosed() public {
        address vault = address(fundVault);
        bytes[4] memory calls = [
            abi.encodeCall(IERC4626.deposit, (0, vault)),
            abi.encodeCall(IERC4626.mint, (0, vault)),
            abi.encodeCall(IERC4626.withdraw, (0, vault, vault)),
            abi.encodeCall(IERC4626.redeem, (0, vault, vault))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.expectPartialRevert(AlphaEngineERC4626DecoderAndSanitizer.ZeroAmount.selector);
            erc4626Decoder.sanitize(calls[i]);
        }
    }

    function test_erc4626UnsupportedShortAndNonCanonicalStaticCallsFailClosed() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphaEngineDecoderAndSanitizer.UnsupportedSelector.selector,
                IERC4626.asset.selector
            )
        );
        erc4626Decoder.sanitize(abi.encodeCall(IERC4626.asset, ()));

        vm.expectRevert(
            abi.encodeWithSelector(IAlphaEngineDecoderAndSanitizer.CalldataTooShort.selector, 1)
        );
        erc4626Decoder.sanitize(hex"01");

        bytes memory canonical = abi.encodeCall(IERC4626.deposit, (1, address(fundVault)));
        vm.expectPartialRevert(AlphaEngineERC4626DecoderAndSanitizer.MalformedCalldata.selector);
        erc4626Decoder.sanitize(bytes.concat(canonical, hex"00"));
    }

    function test_pendleTokenForPtAndPtForTokenReturnOnlyPolicyAddresses() public view {
        assertEq(
            _validTokenForPtData(1_000_000, 990_000).length,
            pendleDecoder.MIN_TOKEN_FOR_PT_CALLDATA_LENGTH()
        );
        assertEq(
            _validPtForTokenData(1_000_000, 990_000).length,
            pendleDecoder.MIN_PT_FOR_TOKEN_CALLDATA_LENGTH()
        );
        assertEq(
            pendleDecoder.sanitize(_validTokenForPtData(1_000_000, 990_000)),
            abi.encode(address(fundVault), MARKET, TOKEN)
        );
        assertEq(
            pendleDecoder.sanitize(_validPtForTokenData(1_000_000, 990_000)),
            abi.encode(address(fundVault), MARKET, TOKEN)
        );
    }

    function testFuzz_pendleAmountsAndApproximationCannotChangePolicyArguments(
        uint128 exactInput,
        uint128 minimumOutput,
        uint16 iterations,
        uint128 eps
    ) public view {
        exactInput = uint128(bound(exactInput, 1, type(uint128).max));
        minimumOutput = uint128(bound(minimumOutput, 1, type(uint128).max));
        iterations = uint16(bound(iterations, 1, 256));
        eps = uint128(bound(eps, 1, 1e18));

        IAlphaEnginePendleRouterV4.ApproxParams memory approximation = _validApproximation();
        approximation.maxIteration = iterations;
        approximation.eps = eps;
        assertEq(
            pendleDecoder.sanitize(
                _tokenForPtData(
                    exactInput, minimumOutput, approximation, _validInput(exactInput), _emptyLimit()
                )
            ),
            abi.encode(address(fundVault), MARKET, TOKEN)
        );
        assertEq(
            pendleDecoder.sanitize(_validPtForTokenData(exactInput, minimumOutput)),
            abi.encode(address(fundVault), MARKET, TOKEN)
        );
    }

    function test_pendleConstructorRejectsMissingCodeAndWrongFacetMappings() public {
        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.InvalidContract.selector);
        new AlphaEnginePendleV4PtDecoderAndSanitizer(
            address(0), IAlphaEnginePendleRouterV4(address(router)), address(ptFacet)
        );

        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.InvalidContract.selector);
        new AlphaEnginePendleV4PtDecoderAndSanitizer(
            address(fundVault), IAlphaEnginePendleRouterV4(OTHER), address(ptFacet)
        );

        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.InvalidContract.selector);
        new AlphaEnginePendleV4PtDecoderAndSanitizer(
            address(fundVault), IAlphaEnginePendleRouterV4(address(router)), OTHER
        );

        DecoderTestCode wrongFacet = new DecoderTestCode();
        router.setFacet(
            IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector, address(wrongFacet)
        );
        vm.expectPartialRevert(
            AlphaEnginePendleV4PtDecoderAndSanitizer.UnexpectedSelectorFacet.selector
        );
        new AlphaEnginePendleV4PtDecoderAndSanitizer(
            address(fundVault), IAlphaEnginePendleRouterV4(address(router)), address(ptFacet)
        );
    }

    function test_pendleDependencyCodeAndSelectorDriftFailClosed() public {
        bytes memory callData = _validTokenForPtData(1, 1);

        vm.etch(address(ptFacet), hex"60006000");
        vm.expectPartialRevert(
            AlphaEnginePendleV4PtDecoderAndSanitizer.DependencyCodeHashChanged.selector
        );
        pendleDecoder.sanitize(callData);

        setUp();
        DecoderTestCode replacementFacet = new DecoderTestCode();
        router.setFacet(
            IAlphaEnginePendleRouterV4.swapExactTokenForPt.selector, address(replacementFacet)
        );
        vm.expectPartialRevert(
            AlphaEnginePendleV4PtDecoderAndSanitizer.UnexpectedSelectorFacet.selector
        );
        pendleDecoder.sanitize(callData);

        setUp();
        vm.etch(address(router), hex"60006000");
        vm.expectPartialRevert(
            AlphaEnginePendleV4PtDecoderAndSanitizer.DependencyCodeHashChanged.selector
        );
        pendleDecoder.sanitize(callData);
    }

    function test_pendleReceiverMarketAmountsTokensAndCanonicalEncodingFailClosed() public {
        IAlphaEnginePendleRouterV4.ApproxParams memory approximation = _validApproximation();
        IAlphaEnginePendleRouterV4.TokenInput memory input = _validInput(1);
        IAlphaEnginePendleRouterV4.TokenOutput memory output = _validOutput(1);
        IAlphaEnginePendleRouterV4.LimitOrderData memory limit = _emptyLimit();

        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.InvalidReceiver.selector);
        pendleDecoder.sanitize(
            _tokenForPtDataWithReceiver(OTHER, MARKET, 1, approximation, input, limit)
        );

        vm.expectRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.ZeroMarket.selector);
        pendleDecoder.sanitize(
            _tokenForPtDataWithReceiver(
                address(fundVault), address(0), 1, approximation, input, limit
            )
        );

        input.netTokenIn = 0;
        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.ZeroAmount.selector);
        pendleDecoder.sanitize(_tokenForPtData(0, 1, approximation, input, limit));
        input = _validInput(1);

        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.ZeroMinimumOutput.selector);
        pendleDecoder.sanitize(_tokenForPtData(1, 0, approximation, input, limit));

        input.tokenIn = address(0);
        input.tokenMintSy = address(0);
        vm.expectRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.ZeroToken.selector);
        pendleDecoder.sanitize(_tokenForPtData(1, 1, approximation, input, limit));
        input = _validInput(1);

        input.tokenMintSy = OTHER;
        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.MismatchedSyToken.selector);
        pendleDecoder.sanitize(_tokenForPtData(1, 1, approximation, input, limit));

        output.tokenRedeemSy = OTHER;
        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.MismatchedSyToken.selector);
        pendleDecoder.sanitize(_ptForTokenData(1, output, limit));

        output = _validOutput(1);
        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.ZeroAmount.selector);
        pendleDecoder.sanitize(_ptForTokenData(0, output, limit));

        output = _validOutput(0);
        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.ZeroMinimumOutput.selector);
        pendleDecoder.sanitize(_ptForTokenData(1, output, limit));

        output = _validOutput(1);
        output.tokenOut = address(0);
        output.tokenRedeemSy = address(0);
        vm.expectRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.ZeroToken.selector);
        pendleDecoder.sanitize(_ptForTokenData(1, output, limit));

        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.InvalidReceiver.selector);
        pendleDecoder.sanitize(
            abi.encodeCall(
                IAlphaEnginePendleRouterV4.swapExactPtForToken,
                (OTHER, MARKET, 1, _validOutput(1), limit)
            )
        );

        bytes memory canonical = _validPtForTokenData(1, 1);
        vm.expectPartialRevert(
            AlphaEnginePendleV4PtDecoderAndSanitizer.NonCanonicalCalldata.selector
        );
        pendleDecoder.sanitize(bytes.concat(canonical, hex"00"));
    }

    function test_pendleEveryAggregatorFieldFailsClosed() public {
        IAlphaEnginePendleRouterV4.TokenInput memory input = _validInput(1);

        input.pendleSwap = OTHER;
        _expectAggregatorRejected(input);
        input = _validInput(1);
        input.swapData.swapType = IAlphaEnginePendleRouterV4.SwapType.ODOS;
        _expectAggregatorRejected(input);
        input = _validInput(1);
        input.swapData.extRouter = OTHER;
        _expectAggregatorRejected(input);
        input = _validInput(1);
        input.swapData.extCalldata = hex"01";
        _expectAggregatorRejected(input);
        input = _validInput(1);
        input.swapData.needScale = true;
        _expectAggregatorRejected(input);

        IAlphaEnginePendleRouterV4.TokenOutput memory output = _validOutput(1);
        output.swapData.extRouter = OTHER;
        vm.expectRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.AggregatorNotPermitted.selector);
        pendleDecoder.sanitize(_ptForTokenData(1, output, _emptyLimit()));
    }

    function test_pendleEveryLimitOrderFieldFailsClosed() public {
        IAlphaEnginePendleRouterV4.LimitOrderData memory limit = _emptyLimit();
        limit.limitRouter = OTHER;
        _expectLimitRejected(limit);

        limit = _emptyLimit();
        limit.epsSkipMarket = 1;
        _expectLimitRejected(limit);

        limit = _emptyLimit();
        limit.normalFills = new IAlphaEnginePendleRouterV4.FillOrderParams[](1);
        _expectLimitRejected(limit);

        limit = _emptyLimit();
        limit.flashFills = new IAlphaEnginePendleRouterV4.FillOrderParams[](1);
        _expectLimitRejected(limit);

        limit = _emptyLimit();
        limit.optData = hex"01";
        _expectLimitRejected(limit);
    }

    function test_pendleInvalidApproximationBoundariesFailClosed() public {
        IAlphaEnginePendleRouterV4.ApproxParams memory approximation = _validApproximation();
        approximation.guessMax = 0;
        _expectApproximationRejected(approximation);

        approximation = _validApproximation();
        approximation.guessMin = 2;
        approximation.guessMax = 1;
        _expectApproximationRejected(approximation);

        approximation = _validApproximation();
        approximation.guessMax = 100;
        approximation.guessOffchain = approximation.guessMax + 1;
        _expectApproximationRejected(approximation);

        approximation = _validApproximation();
        approximation.maxIteration = 0;
        _expectApproximationRejected(approximation);

        approximation = _validApproximation();
        approximation.maxIteration = 257;
        _expectApproximationRejected(approximation);

        approximation = _validApproximation();
        approximation.eps = 0;
        _expectApproximationRejected(approximation);

        approximation = _validApproximation();
        approximation.eps = 1e18 + 1;
        _expectApproximationRejected(approximation);
    }

    function test_pendleUnsupportedShortAndOversizedCallsFailClosed() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAlphaEngineDecoderAndSanitizer.CalldataTooShort.selector, 0)
        );
        pendleDecoder.sanitize("");

        vm.expectPartialRevert(IAlphaEngineDecoderAndSanitizer.UnsupportedSelector.selector);
        pendleDecoder.sanitize(abi.encodeCall(IERC20.approve, (SPENDER, 1)));

        bytes memory truncatedEntry = _validTokenForPtData(1, 1);
        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.MalformedCalldata.selector);
        pendleDecoder.sanitize(_truncateOne(truncatedEntry));

        bytes memory truncatedExit = _validPtForTokenData(1, 1);
        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.MalformedCalldata.selector);
        pendleDecoder.sanitize(_truncateOne(truncatedExit));

        bytes memory oversized =
            bytes.concat(_validTokenForPtData(1, 1), new bytes(pendleDecoder.MAX_CALLDATA_LENGTH()));
        vm.expectPartialRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.CalldataTooLarge.selector);
        pendleDecoder.sanitize(oversized);
    }

    function _expectAggregatorRejected(IAlphaEnginePendleRouterV4.TokenInput memory input)
        private
    {
        vm.expectRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.AggregatorNotPermitted.selector);
        pendleDecoder.sanitize(_tokenForPtData(1, 1, _validApproximation(), input, _emptyLimit()));
    }

    function _expectLimitRejected(IAlphaEnginePendleRouterV4.LimitOrderData memory limit) private {
        vm.expectRevert(AlphaEnginePendleV4PtDecoderAndSanitizer.LimitOrdersNotPermitted.selector);
        pendleDecoder.sanitize(_tokenForPtData(1, 1, _validApproximation(), _validInput(1), limit));
    }

    function _expectApproximationRejected(
        IAlphaEnginePendleRouterV4.ApproxParams memory approximation
    ) private {
        vm.expectPartialRevert(
            AlphaEnginePendleV4PtDecoderAndSanitizer.InvalidApproximation.selector
        );
        pendleDecoder.sanitize(_tokenForPtData(1, 1, approximation, _validInput(1), _emptyLimit()));
    }

    function _validTokenForPtData(uint256 netTokenIn, uint256 minPtOut)
        private
        view
        returns (bytes memory)
    {
        return _tokenForPtData(
            netTokenIn, minPtOut, _validApproximation(), _validInput(netTokenIn), _emptyLimit()
        );
    }

    function _tokenForPtData(
        uint256 netTokenIn,
        uint256 minPtOut,
        IAlphaEnginePendleRouterV4.ApproxParams memory approximation,
        IAlphaEnginePendleRouterV4.TokenInput memory input,
        IAlphaEnginePendleRouterV4.LimitOrderData memory limit
    ) private view returns (bytes memory) {
        input.netTokenIn = netTokenIn;
        return _tokenForPtDataWithReceiver(
            address(fundVault), MARKET, minPtOut, approximation, input, limit
        );
    }

    function _tokenForPtDataWithReceiver(
        address receiver,
        address market,
        uint256 minPtOut,
        IAlphaEnginePendleRouterV4.ApproxParams memory approximation,
        IAlphaEnginePendleRouterV4.TokenInput memory input,
        IAlphaEnginePendleRouterV4.LimitOrderData memory limit
    ) private pure returns (bytes memory) {
        return abi.encodeCall(
            IAlphaEnginePendleRouterV4.swapExactTokenForPt,
            (receiver, market, minPtOut, approximation, input, limit)
        );
    }

    function _validPtForTokenData(uint256 exactPtIn, uint256 minTokenOut)
        private
        view
        returns (bytes memory)
    {
        return _ptForTokenData(exactPtIn, _validOutput(minTokenOut), _emptyLimit());
    }

    function _ptForTokenData(
        uint256 exactPtIn,
        IAlphaEnginePendleRouterV4.TokenOutput memory output,
        IAlphaEnginePendleRouterV4.LimitOrderData memory limit
    ) private view returns (bytes memory) {
        return abi.encodeCall(
            IAlphaEnginePendleRouterV4.swapExactPtForToken,
            (address(fundVault), MARKET, exactPtIn, output, limit)
        );
    }

    function _validApproximation()
        private
        pure
        returns (IAlphaEnginePendleRouterV4.ApproxParams memory approximation)
    {
        approximation = IAlphaEnginePendleRouterV4.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e14
        });
    }

    function _validInput(uint256 amount)
        private
        pure
        returns (IAlphaEnginePendleRouterV4.TokenInput memory input)
    {
        input = IAlphaEnginePendleRouterV4.TokenInput({
            tokenIn: TOKEN,
            netTokenIn: amount,
            tokenMintSy: TOKEN,
            pendleSwap: address(0),
            swapData: IAlphaEnginePendleRouterV4.SwapData({
                swapType: IAlphaEnginePendleRouterV4.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });
    }

    function _validOutput(uint256 minimumOutput)
        private
        pure
        returns (IAlphaEnginePendleRouterV4.TokenOutput memory output)
    {
        output = IAlphaEnginePendleRouterV4.TokenOutput({
            tokenOut: TOKEN,
            minTokenOut: minimumOutput,
            tokenRedeemSy: TOKEN,
            pendleSwap: address(0),
            swapData: IAlphaEnginePendleRouterV4.SwapData({
                swapType: IAlphaEnginePendleRouterV4.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
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

    function _truncateOne(bytes memory source) private pure returns (bytes memory truncated) {
        truncated = new bytes(source.length - 1);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = source[i];
        }
    }
}
