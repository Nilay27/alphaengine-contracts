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
import {
    IAlphaEngineConfidentialSwapEscrow
} from "../interfaces/IAlphaEngineConfidentialSwapEscrow.sol";

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
    error InvalidSwapEscrow(address escrow);
    error ActiveSwapLocksPresent(uint256 count);
    error WrapperRegistryMismatch(address wrapper, address expected, address actual);
    error WrapperNotRegistered(address wrapper);
    error InvalidWrapperMinimums(uint64 swapMinimum, uint64 unshieldMinimum);
    error InvalidUnshieldRateLimits(uint16 perSecond, uint16 burst);
    error UnshieldRateLimitExceeded(uint256 nextAvailableAt);

    event ConfidentialWrapperRegistered(address indexed underlying, address indexed wrapper);
    event TrustedSwapEscrowUpdated(address indexed previousEscrow, address indexed newEscrow);
    event WrapperMinimumsUpdated(
        address indexed wrapper, uint64 swapMinimum, uint64 unshieldMinimum
    );
    event UnshieldRateLimitsUpdated(uint16 perSecond, uint16 burst);
    event UnshieldAdmissionConsumed(address indexed wrapper, uint16 remainingTokens);

    address public override trustedSwapEscrow;

    mapping(address underlying => address wrapper) private _wrappersByUnderlying;
    mapping(address wrapper => address underlying) private _underlyingByWrapper;
    mapping(address wrapper => uint64 minimum) public override minimumSwapInput;
    mapping(address wrapper => uint64 minimum) public override minimumUnshieldAmount;

    // Independent of the swap budget: shared by ordinary exits from all registered wrappers.
    uint16 public unshieldRequestsPerSecond = 1;
    uint16 public unshieldBurst = 8;
    uint16 public availableUnshieldTokens = 8;
    uint40 public unshieldTokensUpdatedAt;

    constructor(address initialOwner) Ownable(_validatedOwner(initialOwner)) {
        unshieldTokensUpdatedAt = uint40(block.timestamp);
    }

    /// @notice Amounts use each wrapper's confidential base units, never underlying base units.
    /// @dev Zero/unconfigured policies prohibit new swaps and ordinary partial exits.
    function setWrapperMinimums(address wrapper, uint64 swapMinimum, uint64 unshieldMinimum)
        external
        onlyOwner
    {
        if (_underlyingByWrapper[wrapper] == address(0)) revert WrapperNotRegistered(wrapper);
        if (swapMinimum == 0 || unshieldMinimum == 0) {
            revert InvalidWrapperMinimums(swapMinimum, unshieldMinimum);
        }
        minimumSwapInput[wrapper] = swapMinimum;
        minimumUnshieldAmount[wrapper] = unshieldMinimum;
        emit WrapperMinimumsUpdated(wrapper, swapMinimum, unshieldMinimum);
    }

    function setUnshieldRateLimits(uint16 perSecond, uint16 burst) external onlyOwner {
        if (perSecond == 0 || perSecond > 16 || burst < perSecond || burst > 128) {
            revert InvalidUnshieldRateLimits(perSecond, burst);
        }
        uint256 tokens = _unshieldTokens();
        availableUnshieldTokens = uint16(tokens > burst ? burst : tokens);
        unshieldTokensUpdatedAt = uint40(block.timestamp);
        unshieldRequestsPerSecond = perSecond;
        unshieldBurst = burst;
        emit UnshieldRateLimitsUpdated(perSecond, burst);
    }

    function consumeUnshieldAdmission() external override {
        if (_underlyingByWrapper[msg.sender] == address(0)) {
            revert WrapperNotRegistered(msg.sender);
        }
        uint256 tokens = _unshieldTokens();
        if (tokens == 0) revert UnshieldRateLimitExceeded(block.timestamp + 1);
        availableUnshieldTokens = uint16(tokens - 1);
        unshieldTokensUpdatedAt = uint40(block.timestamp);
        emit UnshieldAdmissionConsumed(msg.sender, uint16(tokens - 1));
    }

    function _unshieldTokens() private view returns (uint256) {
        uint256 tokens = uint256(availableUnshieldTokens)
            + (block.timestamp - unshieldTokensUpdatedAt) * unshieldRequestsPerSecond;
        return tokens > unshieldBurst ? unshieldBurst : tokens;
    }

    function setTrustedSwapEscrow(address newEscrow) external onlyOwner {
        address previousEscrow = trustedSwapEscrow;
        if (previousEscrow != address(0)) {
            uint256 activeLocks =
                IAlphaEngineConfidentialSwapEscrow(previousEscrow).liveSwapLockCount();
            if (activeLocks != 0) revert ActiveSwapLocksPresent(activeLocks);
        }
        if (newEscrow == address(0) || newEscrow.code.length == 0) {
            revert InvalidSwapEscrow(newEscrow);
        }
        (bool success, bytes memory encodedRegistry) = newEscrow.staticcall(
            abi.encodeCall(IAlphaEngineConfidentialSwapEscrow.assetRegistry, ())
        );
        if (
            !success || encodedRegistry.length != 32
                || abi.decode(encodedRegistry, (address)) != address(this)
        ) revert InvalidSwapEscrow(newEscrow);
        trustedSwapEscrow = newEscrow;
        emit TrustedSwapEscrowUpdated(previousEscrow, newEscrow);
    }

    function createWrapper(
        address underlying,
        string calldata name,
        string calldata symbol,
        string calldata contractUri
    ) external onlyOwner returns (address wrapper) {
        _validateUnregisteredUnderlying(underlying);

        wrapper = address(
            new AlphaEngineFHERC20ERC20Wrapper(
                IERC20(underlying), name, symbol, contractUri, address(this)
            )
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
        (success, claimId) = wrapper.staticcall(
            abi.encodeCall(IAlphaEngineEncryptedUnshieldFHERC20Wrapper.wrapperRegistry, ())
        );
        if (!success || claimId.length != 32) revert InvalidWrapper(wrapper);
        address binding = abi.decode(claimId, (address));
        if (binding != address(this)) {
            revert WrapperRegistryMismatch(wrapper, address(this), binding);
        }

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
