// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IFHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "../fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";

contract AlphaEngineConfidentialVault is Initializable, OwnableUpgradeable, PausableUpgradeable {
    error ZeroOwner();
    error ZeroIntentController();
    error ZeroUnderlying();
    error ZeroWrapper();
    error InvalidUnderlying(address underlying);
    error InvalidWrapper(address wrapper);
    error WrapperAlreadyRegistered(address underlying, address wrapper);
    error WrapperUnderlyingMismatch(
        address wrapper, address expectedUnderlying, address actualUnderlying
    );

    event IntentControllerUpdated(
        address indexed previousIntentController, address indexed newIntentController
    );
    event ConfidentialWrapperRegistered(address indexed underlying, address indexed wrapper);

    address public intentController;

    mapping(address underlying => address wrapper) private _wrappersByUnderlying;
    mapping(address wrapper => address underlying) private _underlyingByWrapper;

    uint256[47] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address intentController_) external initializer {
        if (owner_ == address(0)) {
            revert ZeroOwner();
        }
        if (intentController_ == address(0)) {
            revert ZeroIntentController();
        }

        __Ownable_init(owner_);
        __Pausable_init();

        intentController = intentController_;
        emit IntentControllerUpdated(address(0), intentController_);
    }

    function setIntentController(address newIntentController) external onlyOwner {
        if (newIntentController == address(0)) {
            revert ZeroIntentController();
        }

        address previousIntentController = intentController;
        intentController = newIntentController;

        emit IntentControllerUpdated(previousIntentController, newIntentController);
    }

    function createWrapper(
        address underlying,
        string calldata name,
        string calldata symbol,
        string calldata contractURI
    ) external onlyOwner returns (address wrapper) {
        if (underlying == address(0)) {
            revert ZeroUnderlying();
        }
        if (underlying.code.length == 0) {
            revert InvalidUnderlying(underlying);
        }
        if (_wrappersByUnderlying[underlying] != address(0)) {
            revert WrapperAlreadyRegistered(underlying, _wrappersByUnderlying[underlying]);
        }

        wrapper = address(
            new AlphaEngineFHERC20ERC20Wrapper(IERC20(underlying), name, symbol, contractURI)
        );
        _registerWrapper(underlying, wrapper);
    }

    function registerWrapper(address underlying, address wrapper) external onlyOwner {
        if (underlying == address(0)) {
            revert ZeroUnderlying();
        }
        if (underlying.code.length == 0) {
            revert InvalidUnderlying(underlying);
        }
        if (wrapper == address(0)) {
            revert ZeroWrapper();
        }
        if (_wrappersByUnderlying[underlying] != address(0)) {
            revert WrapperAlreadyRegistered(underlying, _wrappersByUnderlying[underlying]);
        }
        if (_underlyingByWrapper[wrapper] != address(0)) {
            revert WrapperAlreadyRegistered(_underlyingByWrapper[wrapper], wrapper);
        }
        address wrapperUnderlying = _readWrapperUnderlying(wrapper);
        if (wrapperUnderlying != underlying) {
            revert WrapperUnderlyingMismatch(wrapper, underlying, wrapperUnderlying);
        }

        _registerWrapper(underlying, wrapper);
    }

    function wrapperForUnderlying(address underlying) external view returns (address) {
        return _wrappersByUnderlying[underlying];
    }

    function underlyingForWrapper(address wrapper) external view returns (address) {
        return _underlyingByWrapper[wrapper];
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _registerWrapper(address underlying, address wrapper) private {
        _wrappersByUnderlying[underlying] = wrapper;
        _underlyingByWrapper[wrapper] = underlying;

        emit ConfidentialWrapperRegistered(underlying, wrapper);
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
}
