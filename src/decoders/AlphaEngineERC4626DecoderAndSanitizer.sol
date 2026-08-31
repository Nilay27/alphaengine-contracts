// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IAlphaEngineDecoderAndSanitizer} from "../interfaces/IAlphaEngineDecoderAndSanitizer.sol";

/// @notice Fail-closed sanitizer for standard ERC4626 entry and exit actions.
/// @dev The target ERC4626 vault and its code hash are bound by the Merkle leaf. This decoder
///      independently forces every share or asset receiver/owner to be the AlphaEngine FundVault.
contract AlphaEngineERC4626DecoderAndSanitizer is IAlphaEngineDecoderAndSanitizer {
    uint256 private constant ENTRY_CALLDATA_LENGTH = 4 + 32 + 32;
    uint256 private constant EXIT_CALLDATA_LENGTH = 4 + 32 + 32 + 32;

    address public immutable FUND_VAULT;

    error InvalidFundVault(address fundVault);
    error MalformedCalldata(bytes4 selector, uint256 suppliedLength, uint256 expectedLength);
    error ZeroAmount(bytes4 selector);
    error InvalidReceiver(address supplied, address expected);
    error InvalidOwner(address supplied, address expected);

    constructor(address fundVault_) {
        if (fundVault_ == address(0) || fundVault_.code.length == 0) {
            revert InvalidFundVault(fundVault_);
        }
        FUND_VAULT = fundVault_;
    }

    function sanitize(bytes calldata targetData)
        external
        view
        returns (bytes memory sanitizedArguments)
    {
        if (targetData.length < 4) revert CalldataTooShort(targetData.length);

        bytes4 selector = bytes4(targetData[:4]);
        if (selector == IERC4626.deposit.selector || selector == IERC4626.mint.selector) {
            return _sanitizeEntry(selector, targetData);
        }
        if (selector == IERC4626.withdraw.selector || selector == IERC4626.redeem.selector) {
            return _sanitizeExit(selector, targetData);
        }
        revert UnsupportedSelector(selector);
    }

    function _sanitizeEntry(bytes4 selector, bytes calldata targetData)
        private
        view
        returns (bytes memory sanitizedArguments)
    {
        if (targetData.length != ENTRY_CALLDATA_LENGTH) {
            revert MalformedCalldata(selector, targetData.length, ENTRY_CALLDATA_LENGTH);
        }
        (uint256 amount, address receiver) = abi.decode(targetData[4:], (uint256, address));
        if (amount == 0) revert ZeroAmount(selector);
        if (receiver != FUND_VAULT) revert InvalidReceiver(receiver, FUND_VAULT);
        sanitizedArguments = abi.encode(receiver);
    }

    function _sanitizeExit(bytes4 selector, bytes calldata targetData)
        private
        view
        returns (bytes memory sanitizedArguments)
    {
        if (targetData.length != EXIT_CALLDATA_LENGTH) {
            revert MalformedCalldata(selector, targetData.length, EXIT_CALLDATA_LENGTH);
        }
        (uint256 amount, address receiver, address owner) =
            abi.decode(targetData[4:], (uint256, address, address));
        if (amount == 0) revert ZeroAmount(selector);
        if (receiver != FUND_VAULT) revert InvalidReceiver(receiver, FUND_VAULT);
        if (owner != FUND_VAULT) revert InvalidOwner(owner, FUND_VAULT);
        sanitizedArguments = abi.encode(receiver, owner);
    }
}
