// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {externalEuint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title IAlphaEngineConfidentialSwapController
/// @notice Bound confidential-swap lifecycle surface consumed by users and operators.
interface IAlphaEngineConfidentialSwapController {
    enum SwapIntentStatus {
        Unset,
        Active,
        Executed,
        Refunded
    }

    struct SwapIntentSubmission {
        address inputWrapper;
        address outputWrapper;
        bytes32 routeKey;
        bytes32 executionDataHash;
        bytes32 minimumOutputCommitment;
        externalEuint64 encryptedInputAmount;
        bytes inputProof;
        uint40 deadline;
    }

    struct SwapIntentRecord {
        address trader;
        address escrow;
        address executor;
        address inputWrapper;
        address outputWrapper;
        bytes32 routeKey;
        bytes32 executionDataHash;
        bytes32 minimumOutputCommitment;
        bytes32 lockedAmountHandle;
        bytes32 unshieldRequestHandle;
        bytes32 payloadHash;
        uint40 deadline;
        uint40 createdAt;
        uint64 traderNonce;
        SwapIntentStatus status;
    }

    function submitSwapIntent(SwapIntentSubmission calldata submission)
        external
        returns (bytes32 intentId);

    function executeSwapIntent(
        bytes32 intentId,
        uint64 decryptedInputAmount,
        uint256 minimumOutput,
        bytes32 minimumOutputSalt,
        bytes calldata decryptionProof,
        bytes calldata executionData
    ) external returns (uint256 outputUnderlyingAmount, bytes32 shieldedOutputHandle);

    function refundSwapIntent(
        bytes32 intentId,
        uint64 decryptedInputAmount,
        bytes calldata decryptionProof
    ) external returns (bytes32 refundedShieldedHandle);

    function existsSwapIntent(bytes32 intentId) external view returns (bool);

    function getSwapIntent(bytes32 intentId) external view returns (SwapIntentRecord memory record);

    function computeSwapIntentId(address trader, uint64 traderNonce)
        external
        view
        returns (bytes32 intentId);

    function computeMinimumOutputCommitment(
        bytes32 intentId,
        uint256 minimumOutput,
        bytes32 minimumOutputSalt
    ) external pure returns (bytes32 commitment);
}
