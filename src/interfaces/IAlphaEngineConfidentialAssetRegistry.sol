// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAlphaEngineConfidentialAssetRegistry
/// @notice Canonical assets, explicit amount policies and ordinary-unshield admission.
interface IAlphaEngineConfidentialAssetRegistry {
    function trustedSwapEscrow() external view returns (address);
    function minimumSwapInput(address wrapper) external view returns (uint64);
    function minimumUnshieldAmount(address wrapper) external view returns (uint64);
    function consumeUnshieldAdmission() external;
    function wrapperForUnderlying(address underlying) external view returns (address wrapper);

    function underlyingForWrapper(address wrapper) external view returns (address underlying);

    function isUnderlyingRegistered(address underlying) external view returns (bool);

    function isWrapperRegistered(address wrapper) external view returns (bool);
}
