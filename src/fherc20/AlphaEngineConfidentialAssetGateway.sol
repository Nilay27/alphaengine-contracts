// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FHE, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {
    IFHERC20ERC20Wrapper
} from "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {
    IAlphaEngineConfidentialAssetRegistry
} from "../interfaces/IAlphaEngineConfidentialAssetRegistry.sol";

import {
    IAlphaEngineEncryptedUnshieldFHERC20Wrapper
} from "../interfaces/IAlphaEngineEncryptedUnshieldFHERC20Wrapper.sol";

/// @title AlphaEngineConfidentialAssetGateway
/// @notice Non-custodial convenience surface for shielding and ordinary unshield claims.
/// @dev The gateway has no configurable business state and must retain no underlying token after
///      a successful operation. Registry administration and swap locks live elsewhere.
contract AlphaEngineConfidentialAssetGateway is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidAssetRegistry(address registry);
    error ZeroRecipient();
    error ZeroAmount();
    error UnderlyingNotRegistered(address underlying);
    error WrapperNotRegistered(address wrapper);
    error InvalidWrapper(address wrapper);
    error AmountNotMultipleOfRate(uint256 amount, uint256 rate);
    error AmountExceedsFHERC20Precision(uint256 amount, uint256 rate);
    error UnexpectedUnderlyingBalance(
        address account, address underlying, uint256 expectedBalance, uint256 actualBalance
    );

    event DepositedAndShielded(
        address indexed underlying,
        address indexed wrapper,
        address indexed depositor,
        address recipient,
        uint256 amount,
        euint64 shieldedAmount
    );
    event UnshieldRequested(
        address indexed wrapper,
        address indexed account,
        address indexed recipient,
        uint64 amount,
        euint64 unshieldRequestHandle,
        bytes32 unshieldClaimId
    );
    event UnshieldClaimed(
        address indexed wrapper, bytes32 indexed unshieldRequestId, uint64 decryptedAmount
    );

    IAlphaEngineConfidentialAssetRegistry private immutable ASSET_REGISTRY;

    constructor(IAlphaEngineConfidentialAssetRegistry assetRegistry_) {
        _validateAssetRegistry(address(assetRegistry_));
        ASSET_REGISTRY = assetRegistry_;
    }

    function assetRegistry() external view returns (address) {
        return address(ASSET_REGISTRY);
    }

    function depositAndShield(address underlying, uint256 amount, address recipient)
        external
        nonReentrant
        returns (address wrapper, euint64 shieldedAmount)
    {
        if (recipient == address(0)) {
            revert ZeroRecipient();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        wrapper = _registeredWrapperForUnderlying(underlying);
        uint256 rate = _readWrapperRate(wrapper);
        if (amount % rate != 0) {
            revert AmountNotMultipleOfRate(amount, rate);
        }
        if (amount / rate > type(uint64).max) {
            revert AmountExceedsFHERC20Precision(amount, rate);
        }

        IERC20 token = IERC20(underlying);
        uint256 gatewayBalanceBefore = token.balanceOf(address(this));
        uint256 wrapperBalanceBefore = token.balanceOf(wrapper);

        token.safeTransferFrom(msg.sender, address(this), amount);
        _assertUnderlyingBalance(token, address(this), gatewayBalanceBefore + amount);

        token.forceApprove(wrapper, amount);
        shieldedAmount = FHE.receiveEuint64FromCall(
            IFHERC20ERC20Wrapper(wrapper).shield(recipient, amount), wrapper
        );
        token.forceApprove(wrapper, 0);

        _assertUnderlyingBalance(token, address(this), gatewayBalanceBefore);
        _assertUnderlyingBalance(token, wrapper, wrapperBalanceBefore + amount);

        emit DepositedAndShielded(
            underlying, wrapper, msg.sender, recipient, amount, shieldedAmount
        );
    }

    function requestUnshield(address wrapper, address recipient, uint64 amount)
        external
        nonReentrant
        returns (euint64 unshieldRequestHandle, bytes32 unshieldClaimId)
    {
        _registeredUnderlyingForWrapper(wrapper);
        if (recipient == address(0)) {
            revert ZeroRecipient();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        unshieldRequestHandle = FHE.receiveEuint64FromCall(
            IFHERC20ERC20Wrapper(wrapper).unshield(msg.sender, recipient, amount), wrapper
        );
        unshieldClaimId =
            IAlphaEngineEncryptedUnshieldFHERC20Wrapper(wrapper).latestUnshieldClaimId(recipient);

        emit UnshieldRequested(
            wrapper, msg.sender, recipient, amount, unshieldRequestHandle, unshieldClaimId
        );
    }

    function claimUnshielded(
        address wrapper,
        bytes32 unshieldRequestId,
        uint64 decryptedAmount,
        bytes calldata decryptionProof
    ) external nonReentrant {
        _registeredUnderlyingForWrapper(wrapper);

        IFHERC20ERC20Wrapper(wrapper)
            .claimUnshielded(unshieldRequestId, decryptedAmount, decryptionProof);

        emit UnshieldClaimed(wrapper, unshieldRequestId, decryptedAmount);
    }

    function _registeredWrapperForUnderlying(address underlying)
        private
        view
        returns (address wrapper)
    {
        wrapper = ASSET_REGISTRY.wrapperForUnderlying(underlying);
        if (wrapper == address(0)) {
            revert UnderlyingNotRegistered(underlying);
        }
    }

    function _registeredUnderlyingForWrapper(address wrapper)
        private
        view
        returns (address underlying)
    {
        underlying = ASSET_REGISTRY.underlyingForWrapper(wrapper);
        if (underlying == address(0)) {
            revert WrapperNotRegistered(wrapper);
        }
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

    function _assertUnderlyingBalance(IERC20 token, address account, uint256 expectedBalance)
        private
        view
    {
        uint256 actualBalance = token.balanceOf(account);
        if (actualBalance != expectedBalance) {
            revert UnexpectedUnderlyingBalance(
                account, address(token), expectedBalance, actualBalance
            );
        }
    }

    function _validateAssetRegistry(address registry) private view {
        if (registry == address(0) || registry.code.length == 0) {
            revert InvalidAssetRegistry(registry);
        }

        (bool success, bytes memory result) = registry.staticcall(
            abi.encodeCall(IAlphaEngineConfidentialAssetRegistry.wrapperForUnderlying, (address(0)))
        );
        if (!success || result.length != 32) {
            revert InvalidAssetRegistry(registry);
        }
    }
}
