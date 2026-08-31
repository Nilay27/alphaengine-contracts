// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IAlphaEngineDecoderAndSanitizer} from "../interfaces/IAlphaEngineDecoderAndSanitizer.sol";

/// @notice Fail-closed sanitizer for the ERC20 approval action needed by managed vault calls.
/// @dev Approval amounts remain bound by the exact calldata commitment and Stage 16 risk checks;
///      the Merkle policy binds the spender returned here. Unlimited approvals are prohibited.
contract AlphaEngineERC20DecoderAndSanitizer is IAlphaEngineDecoderAndSanitizer {
    uint256 private constant APPROVE_CALLDATA_LENGTH = 4 + 32 + 32;

    error MalformedCalldata(bytes4 selector, uint256 suppliedLength, uint256 expectedLength);
    error ZeroSpender();
    error UnlimitedApprovalNotPermitted(address spender);

    function sanitize(bytes calldata targetData)
        external
        pure
        returns (bytes memory sanitizedArguments)
    {
        if (targetData.length < 4) revert CalldataTooShort(targetData.length);

        bytes4 selector = bytes4(targetData[:4]);
        if (selector != IERC20.approve.selector) revert UnsupportedSelector(selector);
        if (targetData.length != APPROVE_CALLDATA_LENGTH) {
            revert MalformedCalldata(selector, targetData.length, APPROVE_CALLDATA_LENGTH);
        }

        (address spender, uint256 amount) = abi.decode(targetData[4:], (address, uint256));
        if (spender == address(0)) revert ZeroSpender();
        if (amount == type(uint256).max) revert UnlimitedApprovalNotPermitted(spender);

        sanitizedArguments = abi.encode(spender);
    }
}
