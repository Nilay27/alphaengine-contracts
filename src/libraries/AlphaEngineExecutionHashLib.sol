// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Canonical hashing for exact AlphaEngine execution authorizations.
/// @dev V1 deliberately rejects native value and caps ordered call bundles at 16 entries.
library AlphaEngineExecutionHashLib {
    uint256 internal constant MAX_CALL_COUNT = 16;
    uint256 internal constant MAX_ASSET_LIMIT_COUNT = 16;

    bytes32 internal constant CALL_V1_TYPEHASH = keccak256(
        "AlphaEngineCallV1(uint256 index,address decoder,address target,uint256 value,bytes32 targetDataHash)"
    );
    bytes32 internal constant CALLS_V1_TYPEHASH =
        keccak256("AlphaEngineCallsV1(uint256 callCount,bytes32 callHashesHash)");
    bytes32 internal constant ASSET_DELTA_LIMIT_V1_TYPEHASH = keccak256(
        "AlphaEngineAssetDeltaLimitV1(uint256 index,address asset,uint256 maxSpend,uint256 minReceive)"
    );
    bytes32 internal constant RISK_ENVELOPE_V1_TYPEHASH = keccak256(
        "AlphaEngineRiskEnvelopeV1(uint256 limitCount,bytes32 assetLimitHashesHash,uint256 maxNativeValue)"
    );
    bytes32 internal constant EXECUTION_COMMITMENT_V1_TYPEHASH = keccak256(
        "AlphaEngineExecutionCommitmentV1(uint256 chainId,address capitalStrategyManager,address vaultExecutionManager,address fundVault,bytes32 intentId,address trader,uint64 qualificationVersion,address executor,uint64 authorizationNonce,uint40 validAfter,uint40 deadline,bytes32 policyRoot,uint64 policyVersion,bytes32 callsHash,bytes32 riskEnvelopeHash,uint64 riskPolicyVersion,bytes32 submissionPayloadHash,bytes32 evaluationEvidenceHash)"
    );
    bytes32 internal constant SWAP_MIN_OUTPUT_V1_TYPEHASH = keccak256(
        "AlphaEngineSwapMinimumOutputV1(bytes32 intentId,uint256 minimumOutput,bytes32 salt)"
    );

    error EmptyCallBundle();
    error TooManyCalls(uint256 supplied, uint256 maximum);
    error TooManyAssetLimits(uint256 supplied, uint256 maximum);
    error ZeroCallDecoder(uint256 index);
    error ZeroCallTarget(uint256 index);
    error NativeValueNotSupported(uint256 index, uint256 value);
    error ZeroRiskAsset(uint256 index);
    error RiskAssetsNotStrictlyAscending(uint256 index, address previousAsset, address asset);

    struct CallV1 {
        address decoder;
        address target;
        uint256 value;
        bytes targetData;
    }

    struct AssetDeltaLimitV1 {
        address asset;
        uint256 maxSpend;
        uint256 minReceive;
    }

    struct ExecutionCommitmentV1 {
        uint256 chainId;
        address capitalStrategyManager;
        address vaultExecutionManager;
        address fundVault;
        bytes32 intentId;
        address trader;
        uint64 qualificationVersion;
        address executor;
        uint64 authorizationNonce;
        uint40 validAfter;
        uint40 deadline;
        bytes32 policyRoot;
        uint64 policyVersion;
        bytes32 callsHash;
        bytes32 riskEnvelopeHash;
        uint64 riskPolicyVersion;
        bytes32 submissionPayloadHash;
        bytes32 evaluationEvidenceHash;
    }

    function hashCall(uint256 index, CallV1 memory call_) internal pure returns (bytes32) {
        if (call_.decoder == address(0)) revert ZeroCallDecoder(index);
        if (call_.target == address(0)) revert ZeroCallTarget(index);
        if (call_.value != 0) revert NativeValueNotSupported(index, call_.value);

        return keccak256(
            abi.encode(
                CALL_V1_TYPEHASH,
                index,
                call_.decoder,
                call_.target,
                call_.value,
                keccak256(call_.targetData)
            )
        );
    }

    function hashCalls(CallV1[] memory calls) internal pure returns (bytes32) {
        uint256 callCount = calls.length;
        if (callCount == 0) revert EmptyCallBundle();
        if (callCount > MAX_CALL_COUNT) revert TooManyCalls(callCount, MAX_CALL_COUNT);

        bytes32[] memory callHashes = new bytes32[](callCount);
        for (uint256 i; i < callCount; ++i) {
            callHashes[i] = hashCall(i, calls[i]);
        }

        return
            keccak256(abi.encode(CALLS_V1_TYPEHASH, callCount, keccak256(abi.encode(callHashes))));
    }

    function hashAssetDeltaLimit(uint256 index, AssetDeltaLimitV1 memory limit)
        internal
        pure
        returns (bytes32)
    {
        if (limit.asset == address(0)) revert ZeroRiskAsset(index);
        return keccak256(
            abi.encode(
                ASSET_DELTA_LIMIT_V1_TYPEHASH, index, limit.asset, limit.maxSpend, limit.minReceive
            )
        );
    }

    function hashRiskEnvelope(AssetDeltaLimitV1[] memory limits) internal pure returns (bytes32) {
        uint256 limitCount = limits.length;
        if (limitCount > MAX_ASSET_LIMIT_COUNT) {
            revert TooManyAssetLimits(limitCount, MAX_ASSET_LIMIT_COUNT);
        }

        bytes32[] memory limitHashes = new bytes32[](limitCount);
        address previousAsset;
        for (uint256 i; i < limitCount; ++i) {
            address asset = limits[i].asset;
            if (i != 0 && uint160(previousAsset) >= uint160(asset)) {
                revert RiskAssetsNotStrictlyAscending(i, previousAsset, asset);
            }
            limitHashes[i] = hashAssetDeltaLimit(i, limits[i]);
            previousAsset = asset;
        }

        return keccak256(
            abi.encode(
                RISK_ENVELOPE_V1_TYPEHASH,
                limitCount,
                keccak256(abi.encode(limitHashes)),
                uint256(0)
            )
        );
    }

    function hashExecutionCommitment(ExecutionCommitmentV1 memory commitment)
        internal
        pure
        returns (bytes32)
    {
        // Every field is static-width. Concatenating the two ABI word groups is byte-for-byte
        // identical to one flat abi.encode call while avoiding a 19-value compiler stack spike
        // under Foundry's minimal-IR coverage instrumentation.
        bytes memory authorityAndReplay = abi.encode(
            EXECUTION_COMMITMENT_V1_TYPEHASH,
            commitment.chainId,
            commitment.capitalStrategyManager,
            commitment.vaultExecutionManager,
            commitment.fundVault,
            commitment.intentId,
            commitment.trader,
            commitment.qualificationVersion,
            commitment.executor,
            commitment.authorizationNonce
        );
        bytes memory policyAndEvidence = abi.encode(
            commitment.validAfter,
            commitment.deadline,
            commitment.policyRoot,
            commitment.policyVersion,
            commitment.callsHash,
            commitment.riskEnvelopeHash,
            commitment.riskPolicyVersion,
            commitment.submissionPayloadHash,
            commitment.evaluationEvidenceHash
        );
        return keccak256(bytes.concat(authorityAndReplay, policyAndEvidence));
    }

    function hashSwapMinimumOutput(bytes32 intentId, uint256 minimumOutput, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(SWAP_MIN_OUTPUT_V1_TYPEHASH, intentId, minimumOutput, salt));
    }
}
