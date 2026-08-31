// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Stateless policy decoder used by AlphaEngineVaultExecutionManager.
/// @dev Implementations must reject every selector they do not explicitly support and return
///      deterministic ABI-encoded policy arguments for the target calldata.
interface IAlphaEngineDecoderAndSanitizer {
    error CalldataTooShort(uint256 length);
    error UnsupportedSelector(bytes4 selector);

    function sanitize(bytes calldata targetData)
        external
        view
        returns (bytes memory sanitizedArguments);
}
