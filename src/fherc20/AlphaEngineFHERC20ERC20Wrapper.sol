// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {FHERC20} from "fhenix-confidential-contracts/FHERC20/FHERC20.sol";
import {FHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/FHERC20/extensions/FHERC20ERC20Wrapper.sol";

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

    function _cappedDecimals(IERC20 token) private view returns (uint8) {
        (bool success, bytes memory encodedDecimals) =
            address(token).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        uint8 tokenDecimals =
            success && encodedDecimals.length == 32 ? abi.decode(encodedDecimals, (uint8)) : 18;
        uint8 maxDecimals = _maxDecimals();

        return tokenDecimals > maxDecimals ? maxDecimals : tokenDecimals;
    }
}
