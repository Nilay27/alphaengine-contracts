// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {AlphaEngineExecutionHashLib} from "../../src/libraries/AlphaEngineExecutionHashLib.sol";
import {AlphaEngineStrategyHashLib} from "../../src/libraries/AlphaEngineStrategyHashLib.sol";

contract AlphaEngineHashLibrariesTest is Test {
    uint256 internal constant CHAIN_ID = 421_614;
    address internal constant MANAGER = 0x1111111111111111111111111111111111111111;
    address internal constant CONTROLLER = 0x2222222222222222222222222222222222222222;
    address internal constant TRADER = 0x3333333333333333333333333333333333333333;

    HashLibraryHarness internal harness;
    string internal vectorsJson;

    function setUp() public {
        harness = new HashLibraryHarness();
        vectorsJson = vm.readFile("test/vectors/alphaengine-hash-v1.json");
    }

    function test_strategyHashesMatchDependencyFreeReferenceVectors() public view {
        bytes32 rulesHash = keccak256("alphaengine-rules-v1");
        bytes32 competitionId =
            AlphaEngineStrategyHashLib.hashCompetitionId(CHAIN_ID, MANAGER, 7, rulesHash);
        bytes32 submissionId = AlphaEngineStrategyHashLib.hashCompetitionSubmissionId(
            CHAIN_ID, MANAGER, competitionId, TRADER, 11
        );
        bytes32 capitalIntentId =
            AlphaEngineStrategyHashLib.hashCapitalIntentId(CHAIN_ID, MANAGER, TRADER, 13);
        bytes32 swapIntentId =
            AlphaEngineStrategyHashLib.hashSwapIntentId(CHAIN_ID, CONTROLLER, TRADER, 17);
        bytes32[] memory components = _components();
        bytes32 componentsHash = AlphaEngineStrategyHashLib.hashComponents(components);

        AlphaEngineStrategyHashLib.CompetitionPayloadV1 memory competitionPayload =
            _competitionPayload(competitionId, submissionId, componentsHash);
        AlphaEngineStrategyHashLib.CapitalPayloadV1 memory capitalPayload =
            _capitalPayload(capitalIntentId, componentsHash);
        AlphaEngineStrategyHashLib.SwapPayloadV1 memory swapPayload = _swapPayload(swapIntentId);

        assertEq(rulesHash, _vector("rulesHash"));
        assertEq(competitionId, _vector("competitionId"));
        assertEq(submissionId, _vector("competitionSubmissionId"));
        assertEq(capitalIntentId, _vector("capitalIntentId"));
        assertEq(swapIntentId, _vector("swapIntentId"));
        assertEq(componentsHash, _vector("componentsHash"));
        assertEq(
            AlphaEngineStrategyHashLib.hashCompetitionPayload(competitionPayload),
            _vector("competitionPayloadHash")
        );
        assertEq(
            AlphaEngineStrategyHashLib.hashCapitalPayload(capitalPayload),
            _vector("capitalPayloadHash")
        );
        assertEq(
            AlphaEngineStrategyHashLib.hashSwapPayload(swapPayload), _vector("swapPayloadHash")
        );
    }

    function test_executionHashesMatchDependencyFreeReferenceVectors() public view {
        AlphaEngineExecutionHashLib.CallV1[] memory calls = _calls();
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits = _limits();

        assertEq(AlphaEngineExecutionHashLib.hashCall(0, calls[0]), _vector("call0Hash"));
        assertEq(AlphaEngineExecutionHashLib.hashCall(1, calls[1]), _vector("call1Hash"));

        bytes32 callsHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        bytes32 riskEnvelopeHash = AlphaEngineExecutionHashLib.hashRiskEnvelope(limits);
        assertEq(callsHash, _vector("callsHash"));
        assertEq(
            AlphaEngineExecutionHashLib.hashAssetDeltaLimit(0, limits[0]),
            _vector("assetLimit0Hash")
        );
        assertEq(
            AlphaEngineExecutionHashLib.hashAssetDeltaLimit(1, limits[1]),
            _vector("assetLimit1Hash")
        );
        assertEq(riskEnvelopeHash, _vector("riskEnvelopeHash"));

        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory commitment =
            _executionCommitment(callsHash, riskEnvelopeHash);
        assertEq(
            AlphaEngineExecutionHashLib.hashExecutionCommitment(commitment),
            _vector("executionCommitment")
        );
        assertEq(
            AlphaEngineExecutionHashLib.hashSwapMinimumOutput(
                _vector("swapIntentId"), 99_000, bytes32(uint256(type(uint256).max) / 0xff * 0xcc)
            ),
            _vector("swapMinimumOutputCommitment")
        );
    }

    function test_typeStringsMatchReferenceVectors() public view {
        assertEq(
            keccak256(
                "AlphaEngineCompetitionIdV1(uint256 chainId,address manager,uint64 competitionNonce,bytes32 rulesHash)"
            ),
            _vector("competitionIdTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineCompetitionSubmissionIdV1(uint256 chainId,address manager,bytes32 competitionId,address trader,uint64 traderNonce)"
            ),
            _vector("competitionSubmissionIdTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineCapitalIntentIdV1(uint256 chainId,address manager,address trader,uint64 traderNonce)"
            ),
            _vector("capitalIntentIdTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineSwapIntentIdV1(uint256 chainId,address controller,address trader,uint64 traderNonce)"
            ),
            _vector("swapIntentIdTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineCompetitionPayloadV1(uint256 chainId,address manager,bytes32 submissionId,bytes32 competitionId,address trader,uint64 traderNonce,bytes32 marketIdHandle,bytes32 timeframeKey,uint40 evaluationDeadline,bytes32 componentsHash)"
            ),
            _vector("competitionPayloadTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineCapitalPayloadV1(uint256 chainId,address manager,bytes32 intentId,address trader,uint64 traderNonce,uint64 qualificationVersion,bytes32 marketIdHandle,bytes32 timeframeKey,uint40 deadline,bytes32 componentsHash)"
            ),
            _vector("capitalPayloadTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineSwapPayloadV1(uint256 chainId,address controller,bytes32 intentId,address trader,uint64 traderNonce,address escrow,address executor,address inputWrapper,address outputWrapper,bytes32 routeKey,bytes32 executionDataHash,bytes32 minimumOutputCommitment,uint40 deadline,bytes32 lockedAmountHandle,bytes32 unshieldRequestHandle)"
            ),
            _vector("swapPayloadTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineCallV1(uint256 index,address decoder,address target,uint256 value,bytes32 targetDataHash)"
            ),
            _vector("callTypehash")
        );
        assertEq(
            keccak256("AlphaEngineCallsV1(uint256 callCount,bytes32 callHashesHash)"),
            _vector("callsTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineAssetDeltaLimitV1(uint256 index,address asset,uint256 maxSpend,uint256 minReceive)"
            ),
            _vector("assetDeltaLimitTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineRiskEnvelopeV1(uint256 limitCount,bytes32 assetLimitHashesHash,uint256 maxNativeValue)"
            ),
            _vector("riskEnvelopeTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineExecutionCommitmentV1(uint256 chainId,address capitalStrategyManager,address vaultExecutionManager,address fundVault,bytes32 intentId,address trader,uint64 qualificationVersion,address executor,uint64 authorizationNonce,uint40 validAfter,uint40 deadline,bytes32 policyRoot,uint64 policyVersion,bytes32 callsHash,bytes32 riskEnvelopeHash,uint64 riskPolicyVersion,bytes32 submissionPayloadHash,bytes32 evaluationEvidenceHash)"
            ),
            _vector("executionCommitmentTypehash")
        );
        assertEq(
            keccak256(
                "AlphaEngineSwapMinimumOutputV1(bytes32 intentId,uint256 minimumOutput,bytes32 salt)"
            ),
            _vector("swapMinimumOutputTypehash")
        );
    }

    function test_competitionPayloadBindsEveryField() public pure {
        bytes32 componentsHash = bytes32(uint256(10));
        AlphaEngineStrategyHashLib.CompetitionPayloadV1 memory payload =
            _competitionPayload(bytes32(uint256(8)), bytes32(uint256(9)), componentsHash);
        bytes32 baseline = AlphaEngineStrategyHashLib.hashCompetitionPayload(payload);

        payload.chainId += 1;
        assertNotEq(AlphaEngineStrategyHashLib.hashCompetitionPayload(payload), baseline);
        payload.chainId -= 1;
        payload.manager = address(0x1234);
        assertNotEq(AlphaEngineStrategyHashLib.hashCompetitionPayload(payload), baseline);
        payload.manager = MANAGER;
        payload.submissionId = bytes32(uint256(11));
        assertNotEq(AlphaEngineStrategyHashLib.hashCompetitionPayload(payload), baseline);
        payload.submissionId = bytes32(uint256(9));
        payload.competitionId = bytes32(uint256(12));
        assertNotEq(AlphaEngineStrategyHashLib.hashCompetitionPayload(payload), baseline);
        payload.competitionId = bytes32(uint256(8));
        payload.trader = address(0x5678);
        assertNotEq(AlphaEngineStrategyHashLib.hashCompetitionPayload(payload), baseline);
        payload.trader = TRADER;
        payload.traderNonce += 1;
        assertNotEq(AlphaEngineStrategyHashLib.hashCompetitionPayload(payload), baseline);
        payload.traderNonce -= 1;
        payload.marketIdHandle = bytes32(uint256(13));
        assertNotEq(AlphaEngineStrategyHashLib.hashCompetitionPayload(payload), baseline);
        payload.marketIdHandle = bytes32(uint256(type(uint256).max) / 0xff * 0xaa);
        payload.timeframeKey = bytes32(uint256(14));
        assertNotEq(AlphaEngineStrategyHashLib.hashCompetitionPayload(payload), baseline);
        payload.timeframeKey = keccak256("1h");
        payload.evaluationDeadline += 1;
        assertNotEq(AlphaEngineStrategyHashLib.hashCompetitionPayload(payload), baseline);
        payload.evaluationDeadline -= 1;
        payload.componentsHash = bytes32(uint256(15));
        assertNotEq(AlphaEngineStrategyHashLib.hashCompetitionPayload(payload), baseline);
    }

    function test_capitalPayloadBindsEveryField() public pure {
        AlphaEngineStrategyHashLib.CapitalPayloadV1 memory payload =
            _capitalPayload(bytes32(uint256(7)), bytes32(uint256(8)));
        bytes32 baseline = AlphaEngineStrategyHashLib.hashCapitalPayload(payload);

        payload.chainId += 1;
        assertNotEq(AlphaEngineStrategyHashLib.hashCapitalPayload(payload), baseline);
        payload.chainId -= 1;
        payload.manager = address(0x1234);
        assertNotEq(AlphaEngineStrategyHashLib.hashCapitalPayload(payload), baseline);
        payload.manager = MANAGER;
        payload.intentId = bytes32(uint256(9));
        assertNotEq(AlphaEngineStrategyHashLib.hashCapitalPayload(payload), baseline);
        payload.intentId = bytes32(uint256(7));
        payload.trader = address(0x5678);
        assertNotEq(AlphaEngineStrategyHashLib.hashCapitalPayload(payload), baseline);
        payload.trader = TRADER;
        payload.traderNonce += 1;
        assertNotEq(AlphaEngineStrategyHashLib.hashCapitalPayload(payload), baseline);
        payload.traderNonce -= 1;
        payload.qualificationVersion += 1;
        assertNotEq(AlphaEngineStrategyHashLib.hashCapitalPayload(payload), baseline);
        payload.qualificationVersion -= 1;
        payload.marketIdHandle = bytes32(uint256(10));
        assertNotEq(AlphaEngineStrategyHashLib.hashCapitalPayload(payload), baseline);
        payload.marketIdHandle = bytes32(uint256(type(uint256).max) / 0xff * 0xaa);
        payload.timeframeKey = bytes32(uint256(11));
        assertNotEq(AlphaEngineStrategyHashLib.hashCapitalPayload(payload), baseline);
        payload.timeframeKey = keccak256("1h");
        payload.deadline += 1;
        assertNotEq(AlphaEngineStrategyHashLib.hashCapitalPayload(payload), baseline);
        payload.deadline -= 1;
        payload.componentsHash = bytes32(uint256(12));
        assertNotEq(AlphaEngineStrategyHashLib.hashCapitalPayload(payload), baseline);
    }

    function test_swapPayloadBindsEveryField() public pure {
        AlphaEngineStrategyHashLib.SwapPayloadV1 memory payload = _swapPayload(bytes32(uint256(7)));
        bytes32 baseline = AlphaEngineStrategyHashLib.hashSwapPayload(payload);

        payload.chainId += 1;
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.controller = address(0x10);
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.intentId = bytes32(uint256(8));
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.trader = address(0x11);
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.traderNonce += 1;
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.escrow = address(0x12);
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.executor = address(0x13);
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.inputWrapper = address(0x14);
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.outputWrapper = address(0x15);
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.routeKey = bytes32(uint256(16));
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.executionDataHash = bytes32(uint256(17));
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.minimumOutputCommitment = bytes32(uint256(18));
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.deadline += 1;
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.lockedAmountHandle = bytes32(uint256(19));
        _assertSwapChanged(payload, baseline);
        payload = _swapPayload(bytes32(uint256(7)));
        payload.unshieldRequestHandle = bytes32(uint256(20));
        _assertSwapChanged(payload, baseline);
    }

    function test_executionCommitmentBindsEveryField() public pure {
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory commitment =
            _executionCommitment(bytes32(uint256(1)), bytes32(uint256(2)));
        bytes32 baseline = AlphaEngineExecutionHashLib.hashExecutionCommitment(commitment);

        commitment.chainId += 1;
        _assertChanged(commitment, baseline);
        commitment.chainId -= 1;
        commitment.capitalStrategyManager = address(0x10);
        _assertChanged(commitment, baseline);
        commitment.capitalStrategyManager = MANAGER;
        commitment.vaultExecutionManager = address(0x11);
        _assertChanged(commitment, baseline);
        commitment.vaultExecutionManager = 0x9999999999999999999999999999999999999999;
        commitment.fundVault = address(0x12);
        _assertChanged(commitment, baseline);
        commitment.fundVault = 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa;
        commitment.intentId = bytes32(uint256(13));
        _assertChanged(commitment, baseline);
        commitment.intentId = _vectorStaticCapitalIntentId();
        commitment.trader = address(0x14);
        _assertChanged(commitment, baseline);
        commitment.trader = TRADER;
        commitment.qualificationVersion += 1;
        _assertChanged(commitment, baseline);
        commitment.qualificationVersion -= 1;
        commitment.executor = address(0x15);
        _assertChanged(commitment, baseline);
        commitment.executor = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
        commitment.authorizationNonce += 1;
        _assertChanged(commitment, baseline);
        commitment.authorizationNonce -= 1;
        commitment.validAfter += 1;
        _assertChanged(commitment, baseline);
        commitment.validAfter -= 1;
        commitment.deadline += 1;
        _assertChanged(commitment, baseline);
        commitment.deadline -= 1;
        commitment.policyRoot = bytes32(uint256(16));
        _assertChanged(commitment, baseline);
        commitment.policyRoot = keccak256("policy-root-v1");
        commitment.policyVersion += 1;
        _assertChanged(commitment, baseline);
        commitment.policyVersion -= 1;
        commitment.callsHash = bytes32(uint256(17));
        _assertChanged(commitment, baseline);
        commitment.callsHash = bytes32(uint256(1));
        commitment.riskEnvelopeHash = bytes32(uint256(18));
        _assertChanged(commitment, baseline);
        commitment.riskEnvelopeHash = bytes32(uint256(2));
        commitment.riskPolicyVersion += 1;
        _assertChanged(commitment, baseline);
        commitment.riskPolicyVersion -= 1;
        commitment.submissionPayloadHash = bytes32(uint256(19));
        _assertChanged(commitment, baseline);
        commitment.submissionPayloadHash = _vectorStaticCapitalPayloadHash();
        commitment.evaluationEvidenceHash = bytes32(uint256(20));
        _assertChanged(commitment, baseline);
    }

    function test_callHashBindsIndexDecoderTargetValueAndData() public {
        AlphaEngineExecutionHashLib.CallV1[] memory calls = _calls();
        bytes32 baseline = AlphaEngineExecutionHashLib.hashCall(0, calls[0]);

        assertNotEq(AlphaEngineExecutionHashLib.hashCall(1, calls[0]), baseline);
        calls[0].decoder = address(0x11);
        assertNotEq(AlphaEngineExecutionHashLib.hashCall(0, calls[0]), baseline);
        calls = _calls();
        calls[0].target = address(0x12);
        assertNotEq(AlphaEngineExecutionHashLib.hashCall(0, calls[0]), baseline);
        calls = _calls();
        calls[0].targetData[0] ^= 0x01;
        assertNotEq(AlphaEngineExecutionHashLib.hashCall(0, calls[0]), baseline);

        calls = _calls();
        calls[0].value = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineExecutionHashLib.NativeValueNotSupported.selector, 0, 1
            )
        );
        harness.hashCall(0, calls[0]);
    }

    function test_hashCallsRejectsEmptyAndOversizedBundles() public {
        AlphaEngineExecutionHashLib.CallV1[] memory calls =
            new AlphaEngineExecutionHashLib.CallV1[](0);
        vm.expectRevert(AlphaEngineExecutionHashLib.EmptyCallBundle.selector);
        harness.hashCalls(calls);

        calls = new AlphaEngineExecutionHashLib.CallV1[](17);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineExecutionHashLib.TooManyCalls.selector, 17, 16)
        );
        harness.hashCalls(calls);
    }

    function test_hashCallRejectsZeroDecoderAndTarget() public {
        AlphaEngineExecutionHashLib.CallV1 memory call_ = _calls()[0];
        call_.decoder = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineExecutionHashLib.ZeroCallDecoder.selector, 4)
        );
        harness.hashCall(4, call_);

        call_ = _calls()[0];
        call_.target = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineExecutionHashLib.ZeroCallTarget.selector, 5)
        );
        harness.hashCall(5, call_);
    }

    function test_riskEnvelopeRejectsZeroUnsortedDuplicateAndOversizedAssets() public {
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits = _limits();
        limits[0].asset = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineExecutionHashLib.ZeroRiskAsset.selector, 0)
        );
        harness.hashRiskEnvelope(limits);

        limits = _limits();
        (limits[0], limits[1]) = (limits[1], limits[0]);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineExecutionHashLib.RiskAssetsNotStrictlyAscending.selector,
                1,
                address(0x20),
                address(0x10)
            )
        );
        harness.hashRiskEnvelope(limits);

        limits = _limits();
        limits[1].asset = limits[0].asset;
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineExecutionHashLib.RiskAssetsNotStrictlyAscending.selector,
                1,
                address(0x10),
                address(0x10)
            )
        );
        harness.hashRiskEnvelope(limits);

        limits = new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](17);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineExecutionHashLib.TooManyAssetLimits.selector, 17, 16)
        );
        harness.hashRiskEnvelope(limits);
    }

    function _vector(string memory key) internal view returns (bytes32) {
        return vm.parseJsonBytes32(vectorsJson, string.concat(".", key));
    }

    function _components() internal pure returns (bytes32[] memory components) {
        components = new bytes32[](3);
        components[0] = bytes32(uint256(type(uint256).max) / 0xff * 0x01);
        components[1] = bytes32(uint256(type(uint256).max) / 0xff * 0x02);
        components[2] = bytes32(uint256(type(uint256).max) / 0xff * 0x03);
    }

    function _competitionPayload(
        bytes32 competitionId,
        bytes32 submissionId,
        bytes32 componentsHash
    ) internal pure returns (AlphaEngineStrategyHashLib.CompetitionPayloadV1 memory) {
        return AlphaEngineStrategyHashLib.CompetitionPayloadV1({
            chainId: CHAIN_ID,
            manager: MANAGER,
            submissionId: submissionId,
            competitionId: competitionId,
            trader: TRADER,
            traderNonce: 11,
            marketIdHandle: bytes32(uint256(type(uint256).max) / 0xff * 0xaa),
            timeframeKey: keccak256("1h"),
            evaluationDeadline: 2_000_000_000,
            componentsHash: componentsHash
        });
    }

    function _capitalPayload(bytes32 intentId, bytes32 componentsHash)
        internal
        pure
        returns (AlphaEngineStrategyHashLib.CapitalPayloadV1 memory)
    {
        return AlphaEngineStrategyHashLib.CapitalPayloadV1({
            chainId: CHAIN_ID,
            manager: MANAGER,
            intentId: intentId,
            trader: TRADER,
            traderNonce: 13,
            qualificationVersion: 4,
            marketIdHandle: bytes32(uint256(type(uint256).max) / 0xff * 0xaa),
            timeframeKey: keccak256("1h"),
            deadline: 1_900_004_000,
            componentsHash: componentsHash
        });
    }

    function _swapPayload(bytes32 intentId)
        internal
        pure
        returns (AlphaEngineStrategyHashLib.SwapPayloadV1 memory)
    {
        return AlphaEngineStrategyHashLib.SwapPayloadV1({
            chainId: CHAIN_ID,
            controller: CONTROLLER,
            intentId: intentId,
            trader: TRADER,
            traderNonce: 17,
            escrow: 0x4444444444444444444444444444444444444444,
            executor: 0x5555555555555555555555555555555555555555,
            inputWrapper: 0x6666666666666666666666666666666666666666,
            outputWrapper: 0x7777777777777777777777777777777777777777,
            routeKey: keccak256("uniswap-v4-exact-input"),
            executionDataHash: keccak256("encoded-v4-route"),
            minimumOutputCommitment: AlphaEngineExecutionHashLib.hashSwapMinimumOutput(
                intentId, 99_000, bytes32(uint256(type(uint256).max) / 0xff * 0xcc)
            ),
            deadline: 1_900_000_000,
            lockedAmountHandle: bytes32(uint256(type(uint256).max) / 0xff * 0xdd),
            unshieldRequestHandle: bytes32(uint256(type(uint256).max) / 0xff * 0xee)
        });
    }

    function _calls() internal pure returns (AlphaEngineExecutionHashLib.CallV1[] memory calls) {
        calls = new AlphaEngineExecutionHashLib.CallV1[](2);
        calls[0] = AlphaEngineExecutionHashLib.CallV1({
            decoder: 0x4444444444444444444444444444444444444444,
            target: 0x5555555555555555555555555555555555555555,
            value: 0,
            targetData: abi.encodeWithSelector(
                bytes4(0x095ea7b3), 0x6666666666666666666666666666666666666666, 12_345
            )
        });
        calls[1] = AlphaEngineExecutionHashLib.CallV1({
            decoder: 0x7777777777777777777777777777777777777777,
            target: 0x8888888888888888888888888888888888888888,
            value: 0,
            targetData: abi.encodeWithSelector(bytes4(0x12345678), 98_765)
        });
    }

    function _limits()
        internal
        pure
        returns (AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits)
    {
        limits = new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](2);
        limits[0] = AlphaEngineExecutionHashLib.AssetDeltaLimitV1({
            asset: address(0x10), maxSpend: 1_000_000, minReceive: 0
        });
        limits[1] = AlphaEngineExecutionHashLib.AssetDeltaLimitV1({
            asset: address(0x20), maxSpend: 0, minReceive: 900_000
        });
    }

    function _executionCommitment(bytes32 callsHash, bytes32 riskEnvelopeHash)
        internal
        pure
        returns (AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory)
    {
        return AlphaEngineExecutionHashLib.ExecutionCommitmentV1({
            chainId: CHAIN_ID,
            capitalStrategyManager: MANAGER,
            vaultExecutionManager: 0x9999999999999999999999999999999999999999,
            fundVault: 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa,
            intentId: _vectorStaticCapitalIntentId(),
            trader: TRADER,
            qualificationVersion: 4,
            executor: 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB,
            authorizationNonce: 19,
            validAfter: 1_900_000_000,
            deadline: 1_900_003_600,
            policyRoot: keccak256("policy-root-v1"),
            policyVersion: 2,
            callsHash: callsHash,
            riskEnvelopeHash: riskEnvelopeHash,
            riskPolicyVersion: 3,
            submissionPayloadHash: _vectorStaticCapitalPayloadHash(),
            evaluationEvidenceHash: keccak256("evaluation-evidence-v1")
        });
    }

    function _assertChanged(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory commitment,
        bytes32 baseline
    ) internal pure {
        assertNotEq(AlphaEngineExecutionHashLib.hashExecutionCommitment(commitment), baseline);
    }

    function _assertSwapChanged(
        AlphaEngineStrategyHashLib.SwapPayloadV1 memory payload,
        bytes32 baseline
    ) internal pure {
        assertNotEq(AlphaEngineStrategyHashLib.hashSwapPayload(payload), baseline);
    }

    function _vectorStaticCapitalIntentId() internal pure returns (bytes32) {
        return 0x87051eaac4393ccad5ef2b99c9b30ce0c3801d80bc710b7a36b381355d627230;
    }

    function _vectorStaticCapitalPayloadHash() internal pure returns (bytes32) {
        return 0xbb0c99b3ca6ddbc5168fbb747b4125ea1ac1a559554fb96f59ee2f17b54ff6b3;
    }
}

contract HashLibraryHarness {
    function hashCall(uint256 index, AlphaEngineExecutionHashLib.CallV1 calldata call_)
        external
        pure
        returns (bytes32)
    {
        return AlphaEngineExecutionHashLib.hashCall(index, call_);
    }

    function hashCalls(AlphaEngineExecutionHashLib.CallV1[] calldata calls)
        external
        pure
        returns (bytes32)
    {
        return AlphaEngineExecutionHashLib.hashCalls(calls);
    }

    function hashRiskEnvelope(AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] calldata limits)
        external
        pure
        returns (bytes32)
    {
        return AlphaEngineExecutionHashLib.hashRiskEnvelope(limits);
    }
}
