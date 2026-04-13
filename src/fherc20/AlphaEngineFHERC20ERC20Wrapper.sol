// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FHE, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {FHERC20} from "fhenix-confidential-contracts/FHERC20/FHERC20.sol";
import {FHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/FHERC20/extensions/FHERC20ERC20Wrapper.sol";
import {
    FHERC20InvalidReceiver,
    FHERC20UnauthorizedSpender,
    FHERC20UnauthorizedUseOfEncryptedAmount
} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20Errors.sol";

contract AlphaEngineFHERC20ERC20Wrapper is FHERC20ERC20Wrapper {
    error ZeroUnderlying();
    error InvalidUnderlying(address underlying);

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

    function unshield(address from, address to, euint64 amount)
        public
        virtual
        returns (euint64 unshieldAmount)
    {
        if (to == address(0)) {
            revert FHERC20InvalidReceiver(to);
        }
        if (from != msg.sender && !isOperator(from, msg.sender)) {
            revert FHERC20UnauthorizedSpender(from, msg.sender);
        }
        if (!FHE.isAllowed(amount, msg.sender)) {
            revert FHERC20UnauthorizedUseOfEncryptedAmount(amount, msg.sender);
        }

        unshieldAmount = _burn(from, amount);
        FHE.allowPublic(unshieldAmount);
        _createClaim(to, 0, unshieldAmount);

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
