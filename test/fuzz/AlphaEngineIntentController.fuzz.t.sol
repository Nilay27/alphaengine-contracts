// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {InEuint64, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {AlphaEngineIntentControllerTestBase} from
    "test/mocks/AlphaEngineIntentControllerTestBase.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AlphaEngineIntentControllerFuzzTest is AlphaEngineIntentControllerTestBase {
    struct StrategyRecordSnapshot {
        address submitter;
        bytes32 marketIdHandle;
        bytes32 timeframeKey;
        uint40 deadline;
        uint40 createdAt;
        uint64 submitterNonce;
        uint8 componentCount;
        AlphaEngineIntentController.IntentStatus status;
        bytes32 payloadHash;
    }

    struct SwapFixture {
        AlphaEngineConfidentialVault vault;
        address wrapper;
        InEuint64 encryptedInputAmount;
    }

    function testFuzz_nonceMonotonicityAcrossRepeatedSubmits(
        uint128 firstValue,
        uint128 secondValue
    ) public {
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        InEuint128[] memory firstInputs = _singleInput(firstValue, submitter);
        InEuint128[] memory secondInputs = _singleInput(secondValue, submitter);

        bytes32 firstIntentId = _submit(
            submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, firstInputs, _deadlineAhead(10)
        );
        bytes32 secondIntentId = _submit(
            submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, secondInputs, _deadlineAhead(20)
        );

        AlphaEngineIntentController.IntentRecord memory firstRecord =
            controller.getIntent(firstIntentId);
        AlphaEngineIntentController.IntentRecord memory secondRecord =
            controller.getIntent(secondIntentId);

        assertEq(firstRecord.submitterNonce, 0);
        assertEq(secondRecord.submitterNonce, 1);
        assertEq(controller.submitterNonces(submitter), 2);
    }

    function testFuzz_intentIdUniquenessAcrossNonceProgression(uint128 value, uint8 extraSubmits)
        public
    {
        uint256 submitCount = bound(uint256(extraSubmits), 1, 8);
        uint128 boundedValue = uint128(bound(uint256(value), 0, type(uint128).max - submitCount));
        bytes32 previousIntentId;
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);

        for (uint256 index = 0; index < submitCount; ++index) {
            bytes32 intentId = _submit(
                submitter,
                marketIdInput,
                DEFAULT_TIMEFRAME_KEY,
                // forge-lint: disable-next-line(unsafe-typecast)
                _singleInput(boundedValue + uint128(index), submitter),
                // forge-lint: disable-next-line(unsafe-typecast)
                _deadlineAhead(uint40(index + 1))
            );

            if (index > 0) {
                assertTrue(intentId != previousIntentId);
            }
            previousIntentId = intentId;
        }

        assertEq(controller.submitterNonces(submitter), submitCount);
    }

    function testFuzz_componentCountBounds(uint128 value, uint8 rawCount) public {
        uint256 count = bound(uint256(rawCount), 1, 16);
        InEuint128[] memory inputs = _repeatedInputs(value, count, submitter);
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 intentId =
            _submit(submitter, marketIdInput, DEFAULT_TIMEFRAME_KEY, inputs, _deadlineAhead(1));

        assertEq(controller.getIntent(intentId).componentCount, count);
        assertEq(controller.getIntentComponentHandles(intentId).length, count);
    }

    function testFuzz_unauthorizedCancellationRejection(address attacker, uint128 value) public {
        vm.assume(attacker != address(0));
        vm.assume(attacker != submitter);
        vm.assume(attacker != owner);
        vm.assume(attacker != _proxyAdmin());
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);

        bytes32 intentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(value, submitter),
            _deadlineAhead(1)
        );

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.UnauthorizedCancel.selector, attacker, intentId
            )
        );
        controller.cancelStrategyIntent(intentId);
    }

    function testFuzz_sharedNonceAcrossStrategyAndSwap(uint128 strategyValue, uint64 rawSwapAmount)
        public
    {
        SwapFixture memory fixture = _prepareSwapFixture(rawSwapAmount);
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);

        bytes32 strategyIntentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(strategyValue, submitter),
            _deadlineAhead(1)
        );
        bytes32 swapIntentId = _submitSwap(
            submitter,
            fixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            fixture.encryptedInputAmount,
            _deadlineAhead(2)
        );

        AlphaEngineIntentController.IntentRecord memory strategyRecord =
            controller.getIntent(strategyIntentId);
        AlphaEngineIntentController.SwapIntentRecord memory swapRecord =
            controller.getSwapIntent(swapIntentId);

        assertTrue(strategyIntentId != swapIntentId);
        assertEq(strategyRecord.submitterNonce, 0);
        assertEq(swapRecord.submitterNonce, 1);
        assertEq(controller.submitterNonces(submitter), 2);
        assertEq(
            strategyIntentId,
            keccak256(abi.encode(address(controller), block.chainid, submitter, uint64(0)))
        );
        assertEq(
            swapIntentId,
            keccak256(abi.encode(address(controller), block.chainid, submitter, uint64(1)))
        );
    }

    function testFuzz_crossFamilyCancellationIsolation(uint128 strategyValue, uint64 rawSwapAmount)
        public
    {
        SwapFixture memory fixture = _prepareSwapFixture(rawSwapAmount);
        InEuint128 memory marketIdInput = createInEuint128(DEFAULT_MARKET_ID, submitter);
        bytes32 strategyIntentId = _submit(
            submitter,
            marketIdInput,
            DEFAULT_TIMEFRAME_KEY,
            _singleInput(strategyValue, submitter),
            _deadlineAhead(1)
        );
        bytes32[] memory strategyHandlesBefore =
            controller.getIntentComponentHandles(strategyIntentId);
        StrategyRecordSnapshot memory strategyBefore = _snapshotStrategyRecord(strategyIntentId);
        bytes32 swapIntentId = _submitSwap(
            submitter,
            fixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            fixture.encryptedInputAmount,
            _deadlineAhead(2)
        );
        AlphaEngineIntentController.SwapIntentRecord memory swapBefore =
            controller.getSwapIntent(swapIntentId);

        vm.prank(submitter);
        controller.cancelSwapIntent(swapIntentId);

        _assertStrategyRecordEquals(strategyIntentId, strategyBefore);
        _assertStrategyHandlesEqual(strategyIntentId, strategyHandlesBefore);
        assertEq(
            uint8(controller.getSwapIntent(swapIntentId).status),
            uint8(AlphaEngineIntentController.IntentStatus.Cancelled)
        );
        assertEq(
            uint8(fixture.vault.getSwapIntentLock(swapIntentId).status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.Unlocked)
        );

        vm.prank(submitter);
        controller.cancelStrategyIntent(strategyIntentId);

        AlphaEngineIntentController.SwapIntentRecord memory swapAfter =
            controller.getSwapIntent(swapIntentId);
        assertEq(swapAfter.submitter, swapBefore.submitter);
        assertEq(swapAfter.confidentialVault, swapBefore.confidentialVault);
        assertEq(swapAfter.inputWrapper, swapBefore.inputWrapper);
        assertEq(swapAfter.routeKey, swapBefore.routeKey);
        assertEq(swapAfter.lockedAmountHandle, swapBefore.lockedAmountHandle);
        assertEq(swapAfter.deadline, swapBefore.deadline);
        assertEq(swapAfter.createdAt, swapBefore.createdAt);
        assertEq(swapAfter.submitterNonce, swapBefore.submitterNonce);
        assertEq(swapAfter.payloadHash, swapBefore.payloadHash);
        assertEq(uint8(swapAfter.status), uint8(AlphaEngineIntentController.IntentStatus.Cancelled));
        assertEq(
            uint8(fixture.vault.getSwapIntentLock(swapIntentId).status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.Unlocked)
        );
    }

    function testFuzz_unauthorizedSwapCancellationRejection(address attacker, uint64 rawSwapAmount)
        public
    {
        vm.assume(attacker != address(0));
        vm.assume(attacker != submitter);
        vm.assume(attacker != owner);
        vm.assume(attacker != _proxyAdmin());

        SwapFixture memory fixture = _prepareSwapFixture(rawSwapAmount);
        bytes32 swapIntentId = _submitSwap(
            submitter,
            fixture.wrapper,
            DEFAULT_SWAP_ROUTE_KEY,
            fixture.encryptedInputAmount,
            _deadlineAhead(1)
        );

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineIntentController.UnauthorizedCancel.selector, attacker, swapIntentId
            )
        );
        controller.cancelSwapIntent(swapIntentId);
    }

    function _prepareSwapFixture(uint64 rawSwapAmount)
        private
        returns (SwapFixture memory fixture)
    {
        uint64 lockAmount = uint64(bound(uint256(rawSwapAmount), 1, 1000));
        uint256 depositAmount = uint256(lockAmount) + 1000;
        MockERC20 underlying = new MockERC20("Fuzz USDC", "fUSDC", 6);
        AlphaEngineConfidentialVault vault = _deployVault(address(controller));

        vm.startPrank(owner);
        address wrapper =
            vault.createWrapper(address(underlying), "Encrypted Fuzz USDC", "efUSDC", "");
        controller.setConfidentialVault(address(vault));
        vm.stopPrank();

        underlying.mint(submitter, depositAmount);

        vm.startPrank(submitter);
        underlying.approve(address(vault), depositAmount);
        vault.depositAndShield(address(underlying), depositAmount, submitter);
        AlphaEngineFHERC20ERC20Wrapper(wrapper).setOperator(address(vault), type(uint48).max);
        vm.stopPrank();

        fixture = SwapFixture({
            vault: vault,
            wrapper: wrapper,
            encryptedInputAmount: createInEuint64(lockAmount, submitter)
        });
    }

    function _snapshotStrategyRecord(bytes32 intentId)
        private
        view
        returns (StrategyRecordSnapshot memory snapshot)
    {
        AlphaEngineIntentController.IntentRecord memory intentRecord =
            controller.getIntent(intentId);
        snapshot = StrategyRecordSnapshot({
            submitter: intentRecord.submitter,
            marketIdHandle: intentRecord.marketIdHandle,
            timeframeKey: intentRecord.timeframeKey,
            deadline: intentRecord.deadline,
            createdAt: intentRecord.createdAt,
            submitterNonce: intentRecord.submitterNonce,
            componentCount: intentRecord.componentCount,
            status: intentRecord.status,
            payloadHash: intentRecord.payloadHash
        });
    }

    function _assertStrategyRecordEquals(bytes32 intentId, StrategyRecordSnapshot memory expected)
        private
        view
    {
        AlphaEngineIntentController.IntentRecord memory actual = controller.getIntent(intentId);
        assertEq(actual.submitter, expected.submitter);
        assertEq(actual.marketIdHandle, expected.marketIdHandle);
        assertEq(actual.timeframeKey, expected.timeframeKey);
        assertEq(actual.deadline, expected.deadline);
        assertEq(actual.createdAt, expected.createdAt);
        assertEq(actual.submitterNonce, expected.submitterNonce);
        assertEq(actual.componentCount, expected.componentCount);
        assertEq(uint8(actual.status), uint8(expected.status));
        assertEq(actual.payloadHash, expected.payloadHash);
    }

    function _assertStrategyHandlesEqual(bytes32 intentId, bytes32[] memory expected)
        private
        view
    {
        bytes32[] memory actual = controller.getIntentComponentHandles(intentId);
        assertEq(actual.length, expected.length);
        for (uint256 index = 0; index < actual.length; ++index) {
            assertEq(actual[index], expected[index]);
        }
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
