// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FHE, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {FHERC20} from "fhenix-confidential-contracts/FHERC20/FHERC20.sol";
import {
    FHERC20ERC20Wrapper
} from "fhenix-confidential-contracts/FHERC20/extensions/FHERC20ERC20Wrapper.sol";
import {
    FHERC20InvalidReceiver,
    FHERC20UnauthorizedSpender
} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20Errors.sol";

contract AlphaEngineFHERC20ERC20Wrapper is FHERC20ERC20Wrapper {
    error ZeroUnderlying();
    error InvalidUnderlying(address underlying);

    /// @notice Latest unique claim ID created for a recipient. Read atomically after unshield.
    mapping(address recipient => bytes32 claimId) public latestUnshieldClaimId;

    constructor(
        IERC20 underlying_,
        string memory name_,
        string memory symbol_,
        string memory contractURI_
    )
        FHERC20(name_, symbol_, _cappedDecimals(underlying_), contractURI_)
        FHERC20ERC20Wrapper(underlying_)
    {
        if (address(underlying_) == address(0)) {
            revert ZeroUnderlying();
        }
        if (address(underlying_).code.length == 0) {
            revert InvalidUnderlying(address(underlying_));
        }
    }

    /// @dev Upstream unshield returns only a shared ciphertext. Retain the official claim ID
    ///      here so callers can obtain it in O(1), without enumerating every pending claim.
    ///      Both inherited, non-reentrant unshield overloads use this hook.
    function _unshield(address from, address to, euint64 amount)
        internal
        virtual
        override
        returns (euint64 unshieldAmount)
    {
        if (to == address(0)) {
            revert FHERC20InvalidReceiver(to);
        }
        if (from != msg.sender && !isOperator(from, msg.sender)) {
            revert FHERC20UnauthorizedSpender(from, msg.sender);
        }
        unshieldAmount = _burn(from, amount);
        FHE.allowPublic(unshieldAmount);
        latestUnshieldClaimId[to] = _createClaim(to, unshieldAmount);

        emit Unshielded(to, unshieldAmount);
    }

    function _cappedDecimals(IERC20 token) private view returns (uint8) {
        (bool success, bytes memory encodedDecimals) =
            address(token).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        uint8 tokenDecimals =
            success && encodedDecimals.length == 32 ? abi.decode(encodedDecimals, (uint8)) : 18;
        uint8 maxDecimals = _maxDecimals();

        return tokenDecimals > maxDecimals ? maxDecimals : tokenDecimals;
    }
}
