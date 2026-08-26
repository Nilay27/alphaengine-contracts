// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Domain-separated identifiers and encrypted strategy-payload hashes.
/// @dev Every dynamic value is hashed before inclusion in a fixed-width abi.encode tuple.
library AlphaEngineStrategyHashLib {
    bytes32 internal constant COMPETITION_ID_V1_TYPEHASH = keccak256(
        "AlphaEngineCompetitionIdV1(uint256 chainId,address manager,uint64 competitionNonce,bytes32 rulesHash)"
    );
    bytes32 internal constant COMPETITION_SUBMISSION_ID_V1_TYPEHASH = keccak256(
        "AlphaEngineCompetitionSubmissionIdV1(uint256 chainId,address manager,bytes32 competitionId,address trader,uint64 traderNonce)"
    );
    bytes32 internal constant CAPITAL_INTENT_ID_V1_TYPEHASH = keccak256(
        "AlphaEngineCapitalIntentIdV1(uint256 chainId,address manager,address trader,uint64 traderNonce)"
    );
    bytes32 internal constant SWAP_INTENT_ID_V1_TYPEHASH = keccak256(
        "AlphaEngineSwapIntentIdV1(uint256 chainId,address controller,address trader,uint64 traderNonce)"
    );
    bytes32 internal constant COMPETITION_PAYLOAD_V1_TYPEHASH = keccak256(
        "AlphaEngineCompetitionPayloadV1(uint256 chainId,address manager,bytes32 submissionId,bytes32 competitionId,address trader,uint64 traderNonce,bytes32 marketIdHandle,bytes32 timeframeKey,uint40 evaluationDeadline,bytes32 componentsHash)"
    );
    bytes32 internal constant CAPITAL_PAYLOAD_V1_TYPEHASH = keccak256(
        "AlphaEngineCapitalPayloadV1(uint256 chainId,address manager,bytes32 intentId,address trader,uint64 traderNonce,uint64 qualificationVersion,bytes32 marketIdHandle,bytes32 timeframeKey,uint40 deadline,bytes32 componentsHash)"
    );

    struct CompetitionPayloadV1 {
        uint256 chainId;
        address manager;
        bytes32 submissionId;
        bytes32 competitionId;
        address trader;
        uint64 traderNonce;
        bytes32 marketIdHandle;
        bytes32 timeframeKey;
        uint40 evaluationDeadline;
        bytes32 componentsHash;
    }

    struct CapitalPayloadV1 {
        uint256 chainId;
        address manager;
        bytes32 intentId;
        address trader;
        uint64 traderNonce;
        uint64 qualificationVersion;
        bytes32 marketIdHandle;
        bytes32 timeframeKey;
        uint40 deadline;
        bytes32 componentsHash;
    }

    function hashCompetitionId(
        uint256 chainId,
        address manager,
        uint64 competitionNonce,
        bytes32 rulesHash
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(COMPETITION_ID_V1_TYPEHASH, chainId, manager, competitionNonce, rulesHash)
        );
    }

    function hashCompetitionSubmissionId(
        uint256 chainId,
        address manager,
        bytes32 competitionId,
        address trader,
        uint64 traderNonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                COMPETITION_SUBMISSION_ID_V1_TYPEHASH,
                chainId,
                manager,
                competitionId,
                trader,
                traderNonce
            )
        );
    }

    function hashCapitalIntentId(
        uint256 chainId,
        address manager,
        address trader,
        uint64 traderNonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(CAPITAL_INTENT_ID_V1_TYPEHASH, chainId, manager, trader, traderNonce)
        );
    }

    function hashSwapIntentId(
        uint256 chainId,
        address controller,
        address trader,
        uint64 traderNonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(SWAP_INTENT_ID_V1_TYPEHASH, chainId, controller, trader, traderNonce)
        );
    }

    function hashComponents(bytes32[] memory componentHandles) internal pure returns (bytes32) {
        return keccak256(abi.encode(componentHandles));
    }

    function hashCompetitionPayload(CompetitionPayloadV1 memory payload)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                COMPETITION_PAYLOAD_V1_TYPEHASH,
                payload.chainId,
                payload.manager,
                payload.submissionId,
                payload.competitionId,
                payload.trader,
                payload.traderNonce,
                payload.marketIdHandle,
                payload.timeframeKey,
                payload.evaluationDeadline,
                payload.componentsHash
            )
        );
    }

    function hashCapitalPayload(CapitalPayloadV1 memory payload) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CAPITAL_PAYLOAD_V1_TYPEHASH,
                payload.chainId,
                payload.manager,
                payload.intentId,
                payload.trader,
                payload.traderNonce,
                payload.qualificationVersion,
                payload.marketIdHandle,
                payload.timeframeKey,
                payload.deadline,
                payload.componentsHash
            )
        );
    }
}
