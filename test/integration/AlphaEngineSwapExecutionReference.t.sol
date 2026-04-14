// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {AlphaEngineV4SwapExecutor} from "src/executors/AlphaEngineV4SwapExecutor.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {AlphaEngineIntentControllerTestBase} from
    "test/mocks/AlphaEngineIntentControllerTestBase.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AlphaEngineSwapExecutionReferenceTest is AlphaEngineIntentControllerTestBase {
    uint160 private constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    address private constant REFERENCE_TRADER = address(0xBEEFCAFE);

    struct PoolFixture {
        PoolManager poolManager;
        PoolModifyLiquidityTest liquidityRouter;
        PoolSwapTest swapRouter;
        PoolKey poolKey;
    }

    struct TwinPoolFixture {
        MockERC20 tokenA;
        MockERC20 tokenB;
        MockERC20 inputUnderlying;
        MockERC20 outputUnderlying;
        AlphaEngineConfidentialVault vault;
        address inputWrapper;
        address outputWrapper;
        AlphaEngineV4SwapExecutor executor;
        PoolFixture referencePool;
        PoolFixture intentPool;
        bool zeroForOne;
    }

    function test_executeSwapIntentMatchesDirectReference_tokenAToTokenB() public {
        TwinPoolFixture memory fixture =
            _deployTwinPoolFixture(true, 2_000_000_000e6, 2_000_000_000e6);
        _assertTwinPoolParity(fixture, 40e6);
    }

    function test_executeSwapIntentMatchesDirectReference_tokenBToTokenA() public {
        TwinPoolFixture memory fixture =
            _deployTwinPoolFixture(false, 2_000_000_000e6, 2_000_000_000e6);
        _assertTwinPoolParity(fixture, 25e6);
    }

    function test_executeSwapIntentRejectsMinimumOutputAboveReferenceQuote() public {
        TwinPoolFixture memory fixture =
            _deployTwinPoolFixture(true, 2_000_000_000e6, 2_000_000_000e6);
        uint64 inputAmount = 40e6;
        uint256 expectedOutputAmount = _directReferenceSwap(fixture, inputAmount);
        (bytes32 intentId, bytes32 unshieldRequestHandle) =
            _prepareIntentSwapExecution(fixture, inputAmount);

        taskManager.publishDecryptResult(uint256(unshieldRequestHandle), inputAmount, "");

        vm.prank(listenerOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineV4SwapExecutor.OutputAmountBelowMinimum.selector,
                expectedOutputAmount + 1,
                expectedOutputAmount
            )
        );
        controller.executeSwapIntent(
            intentId,
            fixture.outputWrapper,
            inputAmount,
            expectedOutputAmount + 1,
            "",
            _defaultExecutionData(fixture.intentPool.poolKey, fixture.zeroForOne)
        );
    }

    function _assertTwinPoolParity(TwinPoolFixture memory fixture, uint64 inputAmount) private {
        uint256 expectedOutputAmount = _directReferenceSwap(fixture, inputAmount);
        (bytes32 intentId, bytes32 unshieldRequestHandle) =
            _prepareIntentSwapExecution(fixture, inputAmount);
        taskManager.publishDecryptResult(uint256(unshieldRequestHandle), inputAmount, "");

        vm.prank(listenerOperator);
        (uint256 actualOutputAmount, bytes32 shieldedOutputHandle) = controller.executeSwapIntent(
            intentId,
            fixture.outputWrapper,
            inputAmount,
            expectedOutputAmount,
            "",
            _defaultExecutionData(fixture.intentPool.poolKey, fixture.zeroForOne)
        );

        euint64 outputBalance =
            AlphaEngineFHERC20ERC20Wrapper(fixture.outputWrapper).confidentialBalanceOf(submitter);

        assertEq(actualOutputAmount, expectedOutputAmount);
        assertEq(mockStorage(uint256(shieldedOutputHandle)), expectedOutputAmount);
        assertEq(mockStorage(uint256(euint64.unwrap(outputBalance))), expectedOutputAmount);
        assertEq(fixture.outputUnderlying.balanceOf(fixture.outputWrapper), expectedOutputAmount);
        assertEq(fixture.inputUnderlying.balanceOf(address(fixture.vault)), 0);
        assertEq(fixture.outputUnderlying.balanceOf(address(fixture.vault)), 0);
        assertEq(fixture.inputUnderlying.balanceOf(address(fixture.executor)), 0);
        assertEq(fixture.outputUnderlying.balanceOf(address(fixture.executor)), 0);
    }

    function _directReferenceSwap(TwinPoolFixture memory fixture, uint64 inputAmount)
        private
        returns (uint256 outputAmount)
    {
        fixture.inputUnderlying.mint(REFERENCE_TRADER, inputAmount);

        vm.startPrank(REFERENCE_TRADER);
        fixture.inputUnderlying.approve(
            address(fixture.referencePool.swapRouter), type(uint256).max
        );
        uint256 outputBalanceBefore = fixture.outputUnderlying.balanceOf(REFERENCE_TRADER);
        fixture.referencePool.swapRouter.swap(
            fixture.referencePool.poolKey,
            IPoolManager.SwapParams({
                zeroForOne: fixture.zeroForOne,
                amountSpecified: -int256(uint256(inputAmount)),
                sqrtPriceLimitX96: _defaultPriceLimit(fixture.zeroForOne)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        outputAmount = fixture.outputUnderlying.balanceOf(REFERENCE_TRADER) - outputBalanceBefore;
    }

    function _prepareIntentSwapExecution(TwinPoolFixture memory fixture, uint64 inputAmount)
        private
        returns (bytes32 intentId, bytes32 unshieldRequestHandle)
    {
        uint256 depositAmount = uint256(inputAmount) + 100e6;
        fixture.inputUnderlying.mint(submitter, depositAmount);

        vm.startPrank(submitter);
        fixture.inputUnderlying.approve(address(fixture.vault), depositAmount);
        fixture.vault.depositAndShield(address(fixture.inputUnderlying), depositAmount, submitter);
        AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper).setOperator(
            address(fixture.vault), uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        intentId = _submitSwap(
            submitter,
            fixture.inputWrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            createInEuint64(inputAmount, submitter),
            _deadlineAhead(1 hours)
        );
        unshieldRequestHandle = controller.getSwapIntent(intentId).unshieldRequestHandle;
    }

    function _deployTwinPoolFixture(
        bool tokenAToTokenB,
        uint256 tokenALiquidityAmount,
        uint256 tokenBLiquidityAmount
    ) private returns (TwinPoolFixture memory fixture) {
        fixture.tokenA = new MockERC20("Twin Token A", "TTKA", 6);
        fixture.tokenB = new MockERC20("Twin Token B", "TTKB", 6);
        fixture.referencePool = _deployPoolFixture(
            fixture.tokenA, fixture.tokenB, tokenALiquidityAmount, tokenBLiquidityAmount
        );
        fixture.intentPool = _deployPoolFixture(
            fixture.tokenA, fixture.tokenB, tokenALiquidityAmount, tokenBLiquidityAmount
        );
        fixture.inputUnderlying = tokenAToTokenB ? fixture.tokenA : fixture.tokenB;
        fixture.outputUnderlying = tokenAToTokenB ? fixture.tokenB : fixture.tokenA;
        fixture.zeroForOne = Currency.unwrap(fixture.intentPool.poolKey.currency0)
            == address(fixture.inputUnderlying);
        fixture.vault = _deployVault(address(controller));

        vm.startPrank(owner);
        fixture.inputWrapper = fixture.vault.createWrapper(
            address(fixture.inputUnderlying), "Encrypted Input", "eINPUT", ""
        );
        fixture.outputWrapper = fixture.vault.createWrapper(
            address(fixture.outputUnderlying), "Encrypted Output", "eOUTPUT", ""
        );
        fixture.executor = new AlphaEngineV4SwapExecutor(
            IPoolManager(address(fixture.intentPool.poolManager)), owner, address(fixture.vault)
        );
        controller.setConfidentialVault(address(fixture.vault));
        controller.setSwapExecutor(address(fixture.executor));
        vm.stopPrank();
    }

    function _deployPoolFixture(
        MockERC20 tokenA,
        MockERC20 tokenB,
        uint256 tokenALiquidityAmount,
        uint256 tokenBLiquidityAmount
    ) private returns (PoolFixture memory fixture) {
        fixture.poolManager = new PoolManager(owner);
        fixture.liquidityRouter =
            new PoolModifyLiquidityTest(IPoolManager(address(fixture.poolManager)));
        fixture.swapRouter = new PoolSwapTest(IPoolManager(address(fixture.poolManager)));
        fixture.poolKey = _buildPoolKey(tokenA, tokenB);

        tokenA.mint(address(this), tokenALiquidityAmount);
        tokenB.mint(address(this), tokenBLiquidityAmount);
        tokenA.approve(address(fixture.liquidityRouter), type(uint256).max);
        tokenB.approve(address(fixture.liquidityRouter), type(uint256).max);

        fixture.poolManager.initialize(fixture.poolKey, SQRT_PRICE_1_1);
        fixture.liquidityRouter.modifyLiquidity(
            fixture.poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e12,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _buildPoolKey(MockERC20 tokenA, MockERC20 tokenB)
        private
        pure
        returns (PoolKey memory poolKey)
    {
        Currency currencyA = Currency.wrap(address(tokenA));
        Currency currencyB = Currency.wrap(address(tokenB));

        if (address(tokenA) < address(tokenB)) {
            poolKey = PoolKey({
                currency0: currencyA,
                currency1: currencyB,
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
        } else {
            poolKey = PoolKey({
                currency0: currencyB,
                currency1: currencyA,
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
        }
    }

    function _defaultExecutionData(PoolKey memory poolKey, bool zeroForOne)
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(
            AlphaEngineV4SwapExecutor.ExactInputParams({
                key: poolKey,
                zeroForOne: zeroForOne,
                sqrtPriceLimitX96: 0,
                hookData: ""
            })
        );
    }

    function _defaultPriceLimit(bool zeroForOne) private pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _deployVault(address vaultIntentController)
        private
        returns (AlphaEngineConfidentialVault vault)
    {
        AlphaEngineConfidentialVault vaultImplementation = new AlphaEngineConfidentialVault();
        TransparentUpgradeableProxy vaultProxy = new TransparentUpgradeableProxy(
            address(vaultImplementation),
            owner,
            abi.encodeCall(AlphaEngineConfidentialVault.initialize, (owner, vaultIntentController))
        );
        vault = AlphaEngineConfidentialVault(address(vaultProxy));
    }
}
