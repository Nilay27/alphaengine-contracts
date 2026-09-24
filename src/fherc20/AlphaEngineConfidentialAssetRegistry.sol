// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {
    IFHERC20ERC20Wrapper
} from "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "./AlphaEngineFHERC20ERC20Wrapper.sol";
import {
    IAlphaEngineConfidentialAssetRegistry
} from "../interfaces/IAlphaEngineConfidentialAssetRegistry.sol";
import {
    IAlphaEngineEncryptedUnshieldFHERC20Wrapper
} from "../interfaces/IAlphaEngineEncryptedUnshieldFHERC20Wrapper.sol";

/// @title AlphaEngineConfidentialAssetRegistry
/// @notice Append-only registry for canonical underlying/FHERC20 wrapper pairs.
/// @dev A registered association can never be replaced. The registry neither holds assets nor
///      participates in swap execution.
contract AlphaEngineConfidentialAssetRegistry is Ownable, IAlphaEngineConfidentialAssetRegistry {
    error ZeroInitialOwner();
    error ZeroUnderlying();
    error ZeroWrapper();
    error InvalidUnderlying(address underlying);
    error InvalidWrapper(address wrapper);
    error WrapperAlreadyRegistered(address underlying, address wrapper);
    error WrapperUnderlyingMismatch(
        address wrapper, address expectedUnderlying, address actualUnderlying
    );

    event ConfidentialWrapperRegistered(address indexed underlying, address indexed wrapper);

    mapping(address underlying => address wrapper) private _wrappersByUnderlying;
    mapping(address wrapper => address underlying) private _underlyingByWrapper;

    constructor(address initialOwner) Ownable(_validatedOwner(initialOwner)) {}

    function createWrapper(
        address underlying,
        string calldata name,
        string calldata symbol,
        string calldata contractUri
    ) external onlyOwner returns (address wrapper) {
        _validateUnregisteredUnderlying(underlying);

        wrapper = address(
            new AlphaEngineFHERC20ERC20Wrapper(IERC20(underlying), name, symbol, contractUri)
        );
        _registerWrapper(underlying, wrapper);
    }

    function registerWrapper(address underlying, address wrapper) external onlyOwner {
        _validateUnregisteredUnderlying(underlying);
        if (wrapper == address(0)) {
            revert ZeroWrapper();
        }

        address registeredUnderlying = _underlyingByWrapper[wrapper];
        if (registeredUnderlying != address(0)) {
            revert WrapperAlreadyRegistered(registeredUnderlying, wrapper);
        }

        address wrapperUnderlying = _readWrapperUnderlying(wrapper);
        if (wrapperUnderlying != underlying) {
            revert WrapperUnderlyingMismatch(wrapper, underlying, wrapperUnderlying);
        }
        _readWrapperRate(wrapper);
        (bool success, bytes memory claimId) = wrapper.staticcall(
            abi.encodeCall(
                IAlphaEngineEncryptedUnshieldFHERC20Wrapper.latestUnshieldClaimId, (address(0))
            )
        );
        if (!success || claimId.length != 32) revert InvalidWrapper(wrapper);

        _registerWrapper(underlying, wrapper);
    }

    function wrapperForUnderlying(address underlying) external view returns (address wrapper) {
        return _wrappersByUnderlying[underlying];
    }

    function underlyingForWrapper(address wrapper) external view returns (address underlying) {
        return _underlyingByWrapper[wrapper];
    }

    function isUnderlyingRegistered(address underlying) external view returns (bool) {
        return _wrappersByUnderlying[underlying] != address(0);
    }

    function isWrapperRegistered(address wrapper) external view returns (bool) {
        return _underlyingByWrapper[wrapper] != address(0);
    }

    function _registerWrapper(address underlying, address wrapper) private {
        _wrappersByUnderlying[underlying] = wrapper;
        _underlyingByWrapper[wrapper] = underlying;

        emit ConfidentialWrapperRegistered(underlying, wrapper);
    }

    function _validateUnregisteredUnderlying(address underlying) private view {
        if (underlying == address(0)) {
            revert ZeroUnderlying();
        }
        if (underlying.code.length == 0) {
            revert InvalidUnderlying(underlying);
        }

        address registeredWrapper = _wrappersByUnderlying[underlying];
        if (registeredWrapper != address(0)) {
            revert WrapperAlreadyRegistered(underlying, registeredWrapper);
        }
    }

    function _readWrapperUnderlying(address wrapper) private view returns (address) {
        if (wrapper.code.length == 0) {
            revert InvalidWrapper(wrapper);
        }

        (bool success, bytes memory encodedUnderlying) =
            wrapper.staticcall(abi.encodeCall(IFHERC20ERC20Wrapper.underlying, ()));
        if (!success || encodedUnderlying.length != 32) {
            revert InvalidWrapper(wrapper);
        }

        return abi.decode(encodedUnderlying, (address));
    }

    function _readWrapperRate(address wrapper) private view returns (uint256) {
        (bool success, bytes memory encodedRate) =
            wrapper.staticcall(abi.encodeCall(IFHERC20ERC20Wrapper.rate, ()));
        if (!success || encodedRate.length != 32) {
            revert InvalidWrapper(wrapper);
        }

        uint256 rate = abi.decode(encodedRate, (uint256));
        if (rate == 0) {
            revert InvalidWrapper(wrapper);
        }

        return rate;
    }

    function _validatedOwner(address initialOwner) private pure returns (address) {
        if (initialOwner == address(0)) {
            revert ZeroInitialOwner();
        }
        return initialOwner;
    }
}
