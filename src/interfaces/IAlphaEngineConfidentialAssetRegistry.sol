// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAlphaEngineConfidentialAssetRegistry
/// @notice Read surface for the append-only underlying/FHERC20 wrapper registry.
interface IAlphaEngineConfidentialAssetRegistry {
    function wrapperForUnderlying(address underlying) external view returns (address wrapper);

    function underlyingForWrapper(address wrapper) external view returns (address underlying);

    function isUnderlyingRegistered(address underlying) external view returns (bool);

    function isWrapperRegistered(address wrapper) external view returns (bool);
}
