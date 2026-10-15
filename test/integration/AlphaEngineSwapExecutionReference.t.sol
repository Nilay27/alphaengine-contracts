// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {AlphaEngineV4SwapExecutor} from "src/executors/AlphaEngineV4SwapExecutor.sol";
import {
    AlphaEngineConfidentialAssetGateway
} from "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {
    AlphaEngineConfidentialAssetRegistry
} from "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {
    IAlphaEngineConfidentialSwapController
} from "src/interfaces/IAlphaEngineConfidentialSwapController.sol";
import {
    IAlphaEngineConfidentialSwapEscrow
} from "src/interfaces/IAlphaEngineConfidentialSwapEscrow.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";
import {
    AlphaEngineConfidentialSwapController
} from "src/swap/AlphaEngineConfidentialSwapController.sol";
import {AlphaEngineConfidentialSwapEscrow} from "src/swap/AlphaEngineConfidentialSwapEscrow.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AlphaEngineSwapExecutionReferenceTest is MockCoFheTest {
    uint160 private constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    address private constant REFERENCE_TRADER = address(0xBEEFCAFE);
    bytes32 private constant ROUTE_KEY = keccak256("UNISWAP_V4_EXACT_INPUT");
    bytes32 private constant MINIMUM_OUTPUT_SALT = keccak256("integration-random-salt");

    address private owner = makeAddr("integration-owner");
    address private pauser = makeAddr("integration-pauser");
    address private operator = makeAddr("integration-operator");
    address private trader = makeAddr("integration-trader");
    address private proxyAdminOwner = makeAddr("integration-proxy-admin");

    AlphaEngineConfidentialSwapController private controller;

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
        AlphaEngineConfidentialAssetRegistry registry;
        AlphaEngineConfidentialAssetGateway gateway;
        AlphaEngineConfidentialSwapEscrow escrow;
        address inputWrapper;
        address outputWrapper;
        AlphaEngineV4SwapExecutor executor;
        PoolFixture referencePool;
        PoolFixture intentPool;
        bool zeroForOne;
    }

    function setUp() public {
        _installMockTaskManager();
        AlphaEngineConfidentialSwapController implementation =
            new AlphaEngineConfidentialSwapController();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapController.initialize,
                (AlphaEngineConfidentialSwapController.InitializationParams({
                        initialDefaultAdmin: owner,
                        initialPauser: pauser,
                        initialSwapOperator: operator
                    }))
            )
        );
        controller = AlphaEngineConfidentialSwapController(address(proxy));
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

    function test_volatileSixToEighteenDecimalSwapMatchesReferenceAndReturnsDust() public {
        TwinPoolFixture memory fixture = _deployVolatileTwinPoolFixture(true);
        uint256 expectedOutputAmount = _assertTwinPoolParity(fixture, 3000e6);

        assertGt(expectedOutputAmount, 0.9e18);
        assertLt(expectedOutputAmount, 1.1e18);
        assertGt(expectedOutputAmount % 1e12, 0);
    }

    function test_volatileEighteenToSixDecimalSwapMatchesReference() public {
        TwinPoolFixture memory fixture = _deployVolatileTwinPoolFixture(false);
        uint256 expectedOutputAmount = _assertTwinPoolParity(fixture, 1e6);

        assertGt(expectedOutputAmount, 2900e6);
        assertLt(expectedOutputAmount, 3100e6);
    }

    function test_executeSwapIntentRejectsMinimumOutputAboveReferenceQuote() public {
        TwinPoolFixture memory fixture =
            _deployTwinPoolFixture(true, 2_000_000_000e6, 2_000_000_000e6);
        uint64 inputAmount = 40e6;
        uint256 expectedOutputAmount = _directReferenceSwap(fixture, inputAmount);
        bytes memory executionData =
            _defaultExecutionData(fixture.intentPool.poolKey, fixture.zeroForOne);
        (bytes32 intentId, bytes32 unshieldRequestHandle) = _prepareIntentSwapExecution(
            fixture, inputAmount, expectedOutputAmount + 1, executionData
        );

        taskManager.publishDecryptResult(uint256(unshieldRequestHandle), inputAmount, "");

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineV4SwapExecutor.OutputAmountBelowMinimum.selector,
                expectedOutputAmount + 1,
                expectedOutputAmount
            )
        );
        controller.executeSwapIntent(
            intentId, inputAmount, expectedOutputAmount + 1, MINIMUM_OUTPUT_SALT, "", executionData
        );
    }

    function test_largeTradeRevertsWhenPriceImpactBreachesMinimumAndRollsBack() public {
        TwinPoolFixture memory fixture = _deployTwinPoolFixtureWithLiquidity(
            true, 2_000_000_000e6, 2_000_000_000e6, 1e10, -600, 600
        );
        uint64 inputAmount = 100e6;
        uint256 expectedOutputAmount = _directReferenceSwap(fixture, inputAmount);
        uint256 noPriceImpactOutputAfterFee = uint256(inputAmount) * 997 / 1000;
        uint256 minimumOutput = noPriceImpactOutputAfterFee * 995 / 1000;

        // The minimum tolerates the 0.30% fee plus 0.50% price impact, but this
        // deliberately shallow pool moves further than that for this trade.
        assertLt(expectedOutputAmount, minimumOutput);

        bytes memory executionData =
            _defaultExecutionData(fixture.intentPool.poolKey, fixture.zeroForOne);
        (bytes32 intentId, bytes32 unshieldRequestHandle) =
            _prepareIntentSwapExecution(fixture, inputAmount, minimumOutput, executionData);
        taskManager.publishDecryptResult(uint256(unshieldRequestHandle), inputAmount, "");

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineV4SwapExecutor.OutputAmountBelowMinimum.selector,
                minimumOutput,
                expectedOutputAmount
            )
        );
        controller.executeSwapIntent(
            intentId, inputAmount, minimumOutput, MINIMUM_OUTPUT_SALT, "", executionData
        );

        assertEq(
            uint8(controller.getSwapIntent(intentId).status),
            uint8(IAlphaEngineConfidentialSwapController.SwapIntentStatus.Active)
        );
        assertEq(
            uint8(fixture.escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested)
        );
        assertEq(fixture.escrow.liveSwapLockCount(), 1);
        assertEq(fixture.inputUnderlying.balanceOf(address(fixture.escrow)), 0);
        assertEq(fixture.outputUnderlying.balanceOf(address(fixture.escrow)), 0);
        assertEq(fixture.inputUnderlying.balanceOf(address(fixture.executor)), 0);
        assertEq(fixture.outputUnderlying.balanceOf(address(fixture.executor)), 0);
    }

    // SW-14: randomized sequences, not independent fresh-pool examples. Both real
    // PoolManagers receive identical liquidity changes and alternating directions.
    function testFuzz_SW14_RepeatedBidirectionalPoolLifecycle(uint256 seed, uint8 rawSteps) public {
        TwinPoolFixture memory fixture =
            _deployTwinPoolFixture(true, 2_000_000_000e6, 2_000_000_000e6);
        uint256 steps = bound(rawSteps, 2, 8);
        for (uint256 i; i < steps; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (i != 0) {
                (fixture.inputUnderlying, fixture.outputUnderlying) =
                (fixture.outputUnderlying, fixture.inputUnderlying);
                (fixture.inputWrapper, fixture.outputWrapper) =
                (fixture.outputWrapper, fixture.inputWrapper);
                fixture.zeroForOne = !fixture.zeroForOne;
            }
            if (seed % 2 == 0) {
                int256 delta = int256(1e10 + seed % 1e10);
                fixture.referencePool.liquidityRouter
                    .modifyLiquidity(
                        fixture.referencePool.poolKey,
                        IPoolManager.ModifyLiquidityParams(-120, 120, delta, bytes32(0)),
                        ""
                    );
                fixture.intentPool.liquidityRouter
                    .modifyLiquidity(
                        fixture.intentPool.poolKey,
                        IPoolManager.ModifyLiquidityParams(-120, 120, delta, bytes32(0)),
                        ""
                    );
            }
            _assertTwinPoolParity(fixture, uint64(1e6 + seed % 40e6));
            assertEq(fixture.escrow.liveSwapLockCount(), 0);
            assertEq(controller.activeSwapIntentOf(trader), bytes32(0));
            vm.warp(block.timestamp + 1);
        }
        assertEq(controller.traderNonces(trader), steps);
    }

    // SW-13/14: repeated real high-decimal outputs use measured deltas and dust,
    // including a subsequent reverse swap of already-held confidential outputs.
    function testFuzz_SW13_HighDecimalRepeatedLifecycle(uint256 seed) public {
        TwinPoolFixture memory fixture = _deployVolatileTwinPoolFixture(true);
        for (uint256 i; i < 4; ++i) {
            uint64 amount = uint64(1000e6 + uint256(keccak256(abi.encode(seed, i))) % 4000e6);
            _assertTwinPoolParity(fixture, amount);
            vm.warp(block.timestamp + 1);
        }
    }

    // SW-15: forged and replayed callbacks cannot spend outside PoolManager's
    // unlock lifecycle. An explicit malformed-delta injection covers fail-closed
    // executor validation, then a genuine real-pool swap still succeeds.
    function testFuzz_SW15_CallbackOrderingCannotSpendOutsideSwap(uint256 seed) public {
        TwinPoolFixture memory fixture =
            _deployTwinPoolFixture(true, 2_000_000_000e6, 2_000_000_000e6);
        bytes memory callback = abi.encode(
            AlphaEngineV4SwapExecutor.CallbackData({
                key: fixture.intentPool.poolKey,
                zeroForOne: fixture.zeroForOne,
                sqrtPriceLimitX96: _defaultPriceLimit(fixture.zeroForOne),
                inputToken: address(fixture.inputUnderlying),
                outputToken: address(fixture.outputUnderlying),
                amountIn: 10e6,
                minAmountOut: 1,
                recipient: address(fixture.escrow),
                hookData: ""
            })
        );
        for (uint256 i; i < 2; ++i) {
            address attacker = address(uint160(0xA000 + seed % 1000 + i));
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineV4SwapExecutor.InvalidPoolManagerCaller.selector, attacker
                )
            );
            vm.prank(attacker);
            fixture.executor.unlockCallback(callback);
            vm.expectRevert(IPoolManager.ManagerLocked.selector);
            vm.prank(address(fixture.intentPool.poolManager));
            fixture.executor.unlockCallback(callback);
            vm.mockCall(
                address(fixture.intentPool.poolManager),
                abi.encodeWithSelector(IPoolManager.swap.selector),
                abi.encode(toBalanceDelta(int128(1), int128(1)))
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineV4SwapExecutor.InvalidSwapDirection.selector,
                    fixture.zeroForOne,
                    address(fixture.inputUnderlying),
                    address(fixture.outputUnderlying),
                    Currency.unwrap(fixture.intentPool.poolKey.currency0),
                    Currency.unwrap(fixture.intentPool.poolKey.currency1)
                )
            );
            vm.prank(address(fixture.intentPool.poolManager));
            fixture.executor.unlockCallback(callback);
            vm.clearMockedCalls();
            _assertTwinPoolParity(fixture, uint64(1e6 + seed % 10e6));
            vm.warp(block.timestamp + 1);
        }
    }

    // SW-19: withdrawing executor authority must be atomic; a real admitted lock
    // remains refundable, and restoring authority permits a fresh genuine swap.
    function testFuzz_SW19_CallerRotationPreservesRefundLifecycle(uint64 rawAmount) public {
        TwinPoolFixture memory fixture =
            _deployTwinPoolFixture(true, 2_000_000_000e6, 2_000_000_000e6);
        uint64 amount = uint64(bound(rawAmount, 1e6, 50e6));
        bytes memory executionData =
            _defaultExecutionData(fixture.intentPool.poolKey, fixture.zeroForOne);
        (bytes32 id, bytes32 handle) =
            _prepareIntentSwapExecution(fixture, amount, 1, executionData);
        bytes32 claimId = fixture.escrow.getSwapIntentLock(id).unshieldClaimId;
        taskManager.publishDecryptResult(uint256(handle), amount, "");
        vm.prank(owner);
        fixture.executor.setAuthorizedCaller(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineV4SwapExecutor.UnauthorizedCaller.selector, address(fixture.escrow)
            )
        );
        vm.prank(operator);
        controller.executeSwapIntent(id, amount, 1, MINIMUM_OUTPUT_SALT, "", executionData);
        assertEq(
            uint8(controller.getSwapIntent(id).status),
            uint8(IAlphaEngineConfidentialSwapController.SwapIntentStatus.Active)
        );
        assertFalse(AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper).getClaim(claimId).claimed);
        assertEq(fixture.inputUnderlying.balanceOf(address(fixture.executor)), 0);
        vm.prank(pauser);
        controller.pause();
        controller.refundSwapIntent(id, amount, "");
        assertEq(fixture.escrow.liveSwapLockCount(), 0);
        vm.prank(owner);
        fixture.executor.setAuthorizedCaller(address(fixture.escrow));
        vm.prank(owner);
        controller.unpause();
        _assertTwinPoolParity(fixture, amount);
    }

    // SW-16: opt-in protective probe for high-decimal assets excluded by release policy.
    function testFuzz_SW16_ConditionalUnsupportedSignedDomainMustNotBeAdmitted(
        uint8 rawDecimals,
        uint64 rawAmount
    ) public {
        vm.skip(!vm.envOr("RUN_ACCEPTED_ASSET_LIMIT_PROBES", false));
        uint8 decimals = uint8(bound(rawDecimals, 44, 46));
        uint64 amount = uint64(bound(rawAmount, 2, 128));
        TwinPoolFixture memory fixture = _deployTwinPoolFixtureFromTokens(
            new MockERC20("High decimal input", "HIGH", decimals),
            new MockERC20("Output", "OUT", 6),
            true,
            1e45,
            1e45,
            SQRT_PRICE_1_1,
            1e12,
            -120,
            120
        );
        bytes memory data = _defaultExecutionData(fixture.intentPool.poolKey, fixture.zeroForOne);
        uint256 underlyingAmount =
            uint256(amount) * AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper).rate();
        uint256 signedMaximum = uint256(uint128(type(int128).max));
        assertGt(underlyingAmount, signedMaximum, "SW-16 fixture must exceed signed domain");
        (bytes32 id,) = _prepareIntentSwapExecution(fixture, amount, 1, data);
        assertLe(
            underlyingAmount, signedMaximum, "SW-16 unsupported signed-domain lock was admitted"
        );
        assertEq(controller.activeSwapIntentOf(trader), id);
    }

    function test_SW16_HighDecimalExecutionFailureStillRefunds() public {
        TwinPoolFixture memory fixture = _deployTwinPoolFixtureFromTokens(
            new MockERC20("High decimal input", "HIGH", 44),
            new MockERC20("Output", "OUT", 6),
            true,
            1e45,
            1e45,
            SQRT_PRICE_1_1,
            1e12,
            -120,
            120
        );
        uint256 underlyingAmount = 2 * AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper).rate();
        uint256 referenceBefore = fixture.inputUnderlying.balanceOf(REFERENCE_TRADER);
        _directReferenceSwap(fixture, 2);
        uint256 spent = referenceBefore + underlyingAmount
            - fixture.inputUnderlying.balanceOf(REFERENCE_TRADER);
        bytes memory data = _defaultExecutionData(fixture.intentPool.poolKey, fixture.zeroForOne);
        (bytes32 id, bytes32 handle) = _prepareIntentSwapExecution(fixture, 2, 1, data);
        taskManager.publishDecryptResult(uint256(handle), 2, "");
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineV4SwapExecutor.UnexpectedInputAmount.selector, underlyingAmount, spent
            )
        );
        vm.prank(operator);
        controller.executeSwapIntent(id, 2, 1, MINIMUM_OUTPUT_SALT, "", data);
        assertEq(fixture.escrow.liveSwapLockCount(), 1);
        vm.prank(pauser);
        controller.pause();
        controller.refundSwapIntent(id, 2, "");
        assertEq(fixture.escrow.liveSwapLockCount(), 0);
    }

    function _assertTwinPoolParity(TwinPoolFixture memory fixture, uint64 inputAmount)
        private
        returns (uint256 expectedOutputAmount)
    {
        uint256 balanceBefore = _confidentialValue(fixture.outputWrapper, trader);
        uint256 reserveBefore = fixture.outputUnderlying.balanceOf(fixture.outputWrapper);
        uint256 dustBefore = fixture.outputUnderlying.balanceOf(trader);
        expectedOutputAmount = _directReferenceSwap(fixture, inputAmount);
        bytes memory executionData =
            _defaultExecutionData(fixture.intentPool.poolKey, fixture.zeroForOne);
        (bytes32 intentId, bytes32 unshieldRequestHandle) =
            _prepareIntentSwapExecution(fixture, inputAmount, expectedOutputAmount, executionData);
        taskManager.publishDecryptResult(uint256(unshieldRequestHandle), inputAmount, "");

        vm.prank(operator);
        (uint256 actualOutputAmount, bytes32 shieldedOutputHandle) = controller.executeSwapIntent(
            intentId, inputAmount, expectedOutputAmount, MINIMUM_OUTPUT_SALT, "", executionData
        );

        euint64 outputBalance =
            AlphaEngineFHERC20ERC20Wrapper(fixture.outputWrapper).confidentialBalanceOf(trader);
        uint256 outputRate = AlphaEngineFHERC20ERC20Wrapper(fixture.outputWrapper).rate();
        uint256 expectedDust = expectedOutputAmount % outputRate;
        uint256 expectedShieldedUnderlying = expectedOutputAmount - expectedDust;
        uint256 expectedShieldedUnits = expectedShieldedUnderlying / outputRate;

        assertEq(actualOutputAmount, expectedOutputAmount);
        assertEq(mockStorage(uint256(shieldedOutputHandle)), expectedShieldedUnits);
        assertEq(
            mockStorage(uint256(euint64.unwrap(outputBalance))),
            balanceBefore + expectedShieldedUnits
        );
        assertEq(
            fixture.outputUnderlying.balanceOf(fixture.outputWrapper),
            reserveBefore + expectedShieldedUnderlying
        );
        assertEq(fixture.outputUnderlying.balanceOf(trader), dustBefore + expectedDust);
        assertEq(fixture.inputUnderlying.balanceOf(address(fixture.escrow)), 0);
        assertEq(fixture.outputUnderlying.balanceOf(address(fixture.escrow)), 0);
        assertEq(fixture.inputUnderlying.balanceOf(address(fixture.executor)), 0);
        assertEq(fixture.outputUnderlying.balanceOf(address(fixture.executor)), 0);
    }

    function _confidentialValue(address wrapper, address account) private view returns (uint256) {
        bytes32 handle =
            euint64.unwrap(AlphaEngineFHERC20ERC20Wrapper(wrapper).confidentialBalanceOf(account));
        return handle == bytes32(0) ? 0 : mockStorage(uint256(handle));
    }

    function _directReferenceSwap(TwinPoolFixture memory fixture, uint64 inputAmount)
        private
        returns (uint256 outputAmount)
    {
        uint256 inputUnderlyingAmount = uint256(inputAmount)
            * AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper).rate();
        fixture.inputUnderlying.mint(REFERENCE_TRADER, inputUnderlyingAmount);

        vm.startPrank(REFERENCE_TRADER);
        fixture.inputUnderlying
            .approve(address(fixture.referencePool.swapRouter), type(uint256).max);
        uint256 outputBalanceBefore = fixture.outputUnderlying.balanceOf(REFERENCE_TRADER);
        fixture.referencePool.swapRouter
            .swap(
                fixture.referencePool.poolKey,
                IPoolManager.SwapParams({
                    zeroForOne: fixture.zeroForOne,
                    amountSpecified: -int256(inputUnderlyingAmount),
                    sqrtPriceLimitX96: _defaultPriceLimit(fixture.zeroForOne)
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        vm.stopPrank();

        outputAmount = fixture.outputUnderlying.balanceOf(REFERENCE_TRADER) - outputBalanceBefore;
    }

    function _prepareIntentSwapExecution(
        TwinPoolFixture memory fixture,
        uint64 inputAmount,
        uint256 minimumOutput,
        bytes memory executionData
    ) private returns (bytes32 intentId, bytes32 unshieldRequestHandle) {
        uint256 depositAmount =
            uint256(inputAmount) * AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper).rate();
        fixture.inputUnderlying.mint(trader, depositAmount);

        vm.startPrank(trader);
        fixture.inputUnderlying.approve(address(fixture.gateway), depositAmount);
        fixture.gateway.depositAndShield(address(fixture.inputUnderlying), depositAmount, trader);
        AlphaEngineFHERC20ERC20Wrapper(fixture.inputWrapper)
            .setOperator(address(fixture.escrow), uint48(block.timestamp + 1 hours));
        vm.stopPrank();

        uint64 nonce = controller.traderNonces(trader);
        intentId = controller.computeSwapIntentId(trader, nonce);
        IAlphaEngineConfidentialSwapController.SwapIntentSubmission memory submission =
            IAlphaEngineConfidentialSwapController.SwapIntentSubmission({
                inputWrapper: fixture.inputWrapper,
                outputWrapper: fixture.outputWrapper,
                routeKey: ROUTE_KEY,
                executionDataHash: keccak256(executionData),
                minimumOutputCommitment: AlphaEngineExecutionHashLib.hashSwapMinimumOutput(
                        intentId, minimumOutput, MINIMUM_OUTPUT_SALT
                    ),
                encryptedInputAmount: createExternalEuint64(inputAmount, trader),
                inputProof: "",
                deadline: uint40(block.timestamp + 1 hours)
            });
        submission.inputProof = _inputProof(address(controller), submission.encryptedInputAmount);
        vm.prank(trader);
        assertEq(controller.submitSwapIntent(submission), intentId);
        unshieldRequestHandle = controller.getSwapIntent(intentId).unshieldRequestHandle;
    }

    function _deployTwinPoolFixture(
        bool tokenAToTokenB,
        uint256 tokenALiquidityAmount,
        uint256 tokenBLiquidityAmount
    ) private returns (TwinPoolFixture memory fixture) {
        return _deployTwinPoolFixtureWithLiquidity(
            tokenAToTokenB, tokenALiquidityAmount, tokenBLiquidityAmount, 1e12, -120, 120
        );
    }

    function _deployTwinPoolFixtureWithLiquidity(
        bool tokenAToTokenB,
        uint256 tokenALiquidityAmount,
        uint256 tokenBLiquidityAmount,
        int256 liquidityDelta,
        int24 tickLower,
        int24 tickUpper
    ) private returns (TwinPoolFixture memory fixture) {
        MockERC20 tokenA = new MockERC20("Twin Token A", "TTKA", 6);
        MockERC20 tokenB = new MockERC20("Twin Token B", "TTKB", 6);
        return _deployTwinPoolFixtureFromTokens(
            tokenA,
            tokenB,
            tokenAToTokenB,
            tokenALiquidityAmount,
            tokenBLiquidityAmount,
            SQRT_PRICE_1_1,
            liquidityDelta,
            tickLower,
            tickUpper
        );
    }

    function _deployVolatileTwinPoolFixture(bool usdcToWeth)
        private
        returns (TwinPoolFixture memory fixture)
    {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        bool usdcIsCurrency0 = address(usdc) < address(weth);
        int24 initialTick = usdcIsCurrency0 ? int24(196_200) : int24(-196_200);
        return _deployTwinPoolFixtureFromTokens(
            usdc,
            weth,
            usdcToWeth,
            1e30,
            1e30,
            TickMath.getSqrtPriceAtTick(initialTick),
            1e18,
            initialTick - 600,
            initialTick + 600
        );
    }

    function _deployTwinPoolFixtureFromTokens(
        MockERC20 tokenA,
        MockERC20 tokenB,
        bool tokenAToTokenB,
        uint256 tokenALiquidityAmount,
        uint256 tokenBLiquidityAmount,
        uint160 initialSqrtPriceX96,
        int256 liquidityDelta,
        int24 tickLower,
        int24 tickUpper
    ) private returns (TwinPoolFixture memory fixture) {
        fixture.tokenA = tokenA;
        fixture.tokenB = tokenB;
        fixture.referencePool = _deployPoolFixture(
            fixture.tokenA,
            fixture.tokenB,
            tokenALiquidityAmount,
            tokenBLiquidityAmount,
            initialSqrtPriceX96,
            liquidityDelta,
            tickLower,
            tickUpper
        );
        fixture.intentPool = _deployPoolFixture(
            fixture.tokenA,
            fixture.tokenB,
            tokenALiquidityAmount,
            tokenBLiquidityAmount,
            initialSqrtPriceX96,
            liquidityDelta,
            tickLower,
            tickUpper
        );
        fixture.inputUnderlying = tokenAToTokenB ? fixture.tokenA : fixture.tokenB;
        fixture.outputUnderlying = tokenAToTokenB ? fixture.tokenB : fixture.tokenA;
        fixture.zeroForOne = Currency.unwrap(fixture.intentPool.poolKey.currency0)
            == address(fixture.inputUnderlying);

        fixture.registry = _deployAssetRegistry(owner);
        fixture.gateway = _deployAssetGateway(fixture.registry);
        vm.startPrank(owner);
        fixture.inputWrapper = fixture.registry
            .createWrapper(address(fixture.inputUnderlying), "Encrypted Input", "eINPUT", "");
        fixture.outputWrapper = fixture.registry
            .createWrapper(address(fixture.outputUnderlying), "Encrypted Output", "eOUTPUT", "");
        fixture.registry.setWrapperMinimums(fixture.inputWrapper, 1, 1);
        fixture.registry.setWrapperMinimums(fixture.outputWrapper, 1, 1);
        vm.stopPrank();

        AlphaEngineConfidentialSwapEscrow escrowImplementation =
            new AlphaEngineConfidentialSwapEscrow();
        TransparentUpgradeableProxy escrowProxy = new TransparentUpgradeableProxy(
            address(escrowImplementation),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapEscrow.initialize,
                (owner, pauser, address(controller), address(fixture.registry))
            )
        );
        fixture.escrow = AlphaEngineConfidentialSwapEscrow(address(escrowProxy));
        fixture.executor = new AlphaEngineV4SwapExecutor(
            IPoolManager(address(fixture.intentPool.poolManager)), owner, address(fixture.escrow)
        );

        vm.prank(owner);
        controller.setSwapConfiguration(address(fixture.escrow), address(fixture.executor));
        vm.prank(owner);
        fixture.escrow.unpause();
        vm.prank(owner);
        controller.unpause();
    }

    function _deployPoolFixture(
        MockERC20 tokenA,
        MockERC20 tokenB,
        uint256 tokenALiquidityAmount,
        uint256 tokenBLiquidityAmount,
        uint160 initialSqrtPriceX96,
        int256 liquidityDelta,
        int24 tickLower,
        int24 tickUpper
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

        fixture.poolManager.initialize(fixture.poolKey, initialSqrtPriceX96);
        fixture.liquidityRouter
            .modifyLiquidity(
                fixture.poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: liquidityDelta,
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
                key: poolKey, zeroForOne: zeroForOne, sqrtPriceLimitX96: 0, hookData: ""
            })
        );
    }

    function _defaultPriceLimit(bool zeroForOne) private pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}
