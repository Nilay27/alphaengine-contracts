// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title IAlphaEngineConfidentialSwapEscrow
/// @notice Temporary confidential custody boundary used by the swap controller.
interface IAlphaEngineConfidentialSwapEscrow {
    enum SwapIntentLockStatus {
        Unset,
        Locked,
        UnshieldRequested,
        Consumed,
        Refunded
    }

    struct SwapIntentLock {
        address account;
        address wrapper;
        euint64 lockedAmount;
        euint64 unshieldRequestHandle;
        SwapIntentLockStatus status;
    }

    function swapController() external view returns (address);

    function assetRegistry() external view returns (address);

    function liveSwapLockCount() external view returns (uint256);

    function paused() external view returns (bool);

    function existsSwapIntentLock(bytes32 intentId) external view returns (bool);

    function getSwapIntentLock(bytes32 intentId)
        external
        view
        returns (SwapIntentLock memory intentLock);

    function lockForSwapIntent(
        bytes32 intentId,
        address account,
        address wrapper,
        euint64 requestedAmount
    ) external returns (euint64 lockedAmount);

    function settleSwapIntent(
        bytes32 intentId,
        address executor,
        address outputWrapper,
        uint64 decryptedInputAmount,
        uint256 minOutputAmount,
        bytes calldata decryptionProof,
        bytes calldata executionData
    ) external returns (uint256 outputUnderlyingAmount, bytes32 shieldedOutputHandle);

    function refundSwapIntent(
        bytes32 intentId,
        uint64 decryptedInputAmount,
        bytes calldata decryptionProof
    ) external returns (bytes32 refundedShieldedHandle);
}
