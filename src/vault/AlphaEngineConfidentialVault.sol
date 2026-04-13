// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IFHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {IERC7984} from "fhenix-confidential-contracts/interfaces/IERC7984.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "../fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {IAlphaEngineEncryptedUnshieldFHERC20Wrapper} from
    "../interfaces/IAlphaEngineEncryptedUnshieldFHERC20Wrapper.sol";
import {IAlphaEngineSwapExecutor} from "../interfaces/IAlphaEngineSwapExecutor.sol";

contract AlphaEngineConfidentialVault is Initializable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    enum SwapIntentLockStatus {
        Unset,
        Locked,
        Unlocked,
        Consumed,
        UnshieldRequested
    }

    struct SwapIntentLock {
        address account;
        address wrapper;
        euint64 lockedAmount;
        euint64 unshieldRequestHandle;
        SwapIntentLockStatus status;
    }

    error ZeroOwner();
    error ZeroIntentController();
    error UnauthorizedIntentController(address caller);
    error ZeroIntentId();
    error ZeroAccount();
    error ZeroUnderlying();
    error ZeroWrapper();
    error ZeroRecipient();
    error ZeroAmount();
    error UninitializedEncryptedAmount();
    error InvalidUnderlying(address underlying);
    error InvalidWrapper(address wrapper);
    error WrapperAlreadyRegistered(address underlying, address wrapper);
    error WrapperNotRegistered(address wrapper);
    error UnderlyingNotRegistered(address underlying);
    error WrapperUnderlyingMismatch(
        address wrapper, address expectedUnderlying, address actualUnderlying
    );
    error SwapIntentLockAlreadyExists(bytes32 intentId);
    error SwapIntentLockNotFound(bytes32 intentId);
    error SwapIntentLockNotActive(bytes32 intentId, SwapIntentLockStatus status);
    error AmountNotMultipleOfRate(uint256 amount, uint256 rate);
    error AmountExceedsFHERC20Precision(uint256 amount, uint256 rate);
    error UnexpectedUnderlyingBalance(
        address account, address underlying, uint256 expectedBalance, uint256 actualBalance
    );
    error InvalidSwapExecutor(address executor);
    error UnexpectedClaimedUnderlyingAmount(
        address underlying, uint256 expectedAmount, uint256 actualAmount
    );
    error UnexpectedSettlementOutputAmount(
        address underlying, uint256 expectedAmount, uint256 actualAmount
    );

    event IntentControllerUpdated(
        address indexed previousIntentController, address indexed newIntentController
    );
    event ConfidentialWrapperRegistered(address indexed underlying, address indexed wrapper);
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
        euint64 unshieldRequestHandle
    );
    event UnshieldClaimed(
        address indexed wrapper, bytes32 indexed unshieldRequestId, uint64 decryptedAmount
    );
    event SwapIntentLocked(
        bytes32 indexed intentId,
        address indexed account,
        address indexed wrapper,
        euint64 lockedAmount
    );
    event SwapIntentLockConsumed(
        bytes32 indexed intentId,
        address indexed account,
        address indexed wrapper,
        euint64 consumedAmount
    );
    event SwapIntentUnshieldRequested(
        bytes32 indexed intentId,
        address indexed account,
        address indexed inputWrapper,
        euint64 unshieldRequestHandle
    );
    event SwapIntentSettled(
        bytes32 indexed intentId,
        address indexed account,
        address indexed outputWrapper,
        uint64 decryptedInputAmount,
        uint256 outputUnderlyingAmount,
        euint64 shieldedOutputAmount
    );

    address public intentController;

    mapping(address underlying => address wrapper) private _wrappersByUnderlying;
    mapping(address wrapper => address underlying) private _underlyingByWrapper;
    mapping(bytes32 intentId => SwapIntentLock lock) private _swapIntentLocks;

    uint256[46] private __gap;

    modifier onlyIntentController() {
        _onlyIntentController();
        _;
    }

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
        _readWrapperRate(wrapper);

        _registerWrapper(underlying, wrapper);
    }

    function depositAndShield(address underlying, uint256 amount, address recipient)
        external
        whenNotPaused
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
        uint256 vaultBalanceBefore = token.balanceOf(address(this));
        uint256 wrapperBalanceBefore = token.balanceOf(wrapper);

        token.safeTransferFrom(msg.sender, address(this), amount);
        _assertUnderlyingBalance(token, address(this), vaultBalanceBefore + amount);

        token.forceApprove(wrapper, amount);
        shieldedAmount = IFHERC20ERC20Wrapper(wrapper).shield(recipient, amount);
        token.forceApprove(wrapper, 0);

        _assertUnderlyingBalance(token, address(this), vaultBalanceBefore);
        _assertUnderlyingBalance(token, wrapper, wrapperBalanceBefore + amount);

        emit DepositedAndShielded(
            underlying, wrapper, msg.sender, recipient, amount, shieldedAmount
        );
    }

    function requestUnshield(address wrapper, address recipient, uint64 amount)
        external
        whenNotPaused
        returns (euint64 unshieldRequestHandle)
    {
        _registeredUnderlyingForWrapper(wrapper);
        if (recipient == address(0)) {
            revert ZeroRecipient();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        unshieldRequestHandle =
            IFHERC20ERC20Wrapper(wrapper).unshield(msg.sender, recipient, amount);

        emit UnshieldRequested(wrapper, msg.sender, recipient, amount, unshieldRequestHandle);
    }

    function claimUnshielded(
        address wrapper,
        bytes32 unshieldRequestId,
        uint64 decryptedAmount,
        bytes calldata decryptionProof
    ) external whenNotPaused {
        _registeredUnderlyingForWrapper(wrapper);

        IFHERC20ERC20Wrapper(wrapper).claimUnshielded(
            unshieldRequestId, decryptedAmount, decryptionProof
        );

        emit UnshieldClaimed(wrapper, unshieldRequestId, decryptedAmount);
    }

    function lockForSwapIntent(
        bytes32 intentId,
        address account,
        address wrapper,
        euint64 requestedAmount
    ) external onlyIntentController whenNotPaused returns (euint64 lockedAmount) {
        if (intentId == bytes32(0)) {
            revert ZeroIntentId();
        }
        if (account == address(0)) {
            revert ZeroAccount();
        }
        if (euint64.unwrap(requestedAmount) == bytes32(0)) {
            revert UninitializedEncryptedAmount();
        }
        _registeredUnderlyingForWrapper(wrapper);
        if (_swapIntentLocks[intentId].status != SwapIntentLockStatus.Unset) {
            revert SwapIntentLockAlreadyExists(intentId);
        }

        lockedAmount =
            IERC7984(wrapper).confidentialTransferFrom(account, address(this), requestedAmount);
        if (euint64.unwrap(lockedAmount) == bytes32(0)) {
            revert UninitializedEncryptedAmount();
        }

        _swapIntentLocks[intentId] = SwapIntentLock({
            account: account,
            wrapper: wrapper,
            lockedAmount: lockedAmount,
            unshieldRequestHandle: euint64.wrap(bytes32(0)),
            status: SwapIntentLockStatus.Locked
        });

        emit SwapIntentLocked(intentId, account, wrapper, lockedAmount);
        _requestSwapIntentUnshield(intentId, _swapIntentLocks[intentId]);
    }

    function settleSwapIntent(
        bytes32 intentId,
        address executor,
        address outputWrapper,
        uint64 decryptedInputAmount,
        uint256 minOutputAmount,
        bytes calldata decryptionProof,
        bytes calldata executionData
    )
        external
        onlyIntentController
        whenNotPaused
        returns (uint256 outputUnderlyingAmount, bytes32 shieldedOutputHandle)
    {
        if (executor == address(0) || executor.code.length == 0) {
            revert InvalidSwapExecutor(executor);
        }
        _registeredUnderlyingForWrapper(outputWrapper);
        if (decryptedInputAmount == 0) {
            revert ZeroAmount();
        }

        SwapIntentLock storage intentLock =
            _swapIntentLockInStatus(intentId, SwapIntentLockStatus.UnshieldRequested);
        address inputUnderlying = _registeredUnderlyingForWrapper(intentLock.wrapper);
        uint256 inputRate = _readWrapperRate(intentLock.wrapper);
        uint256 claimedUnderlyingAmount = uint256(decryptedInputAmount) * inputRate;

        IERC20 inputToken = IERC20(inputUnderlying);
        uint256 inputVaultBalanceBefore = inputToken.balanceOf(address(this));
        _claimUnshielded(
            intentLock.wrapper,
            euint64.unwrap(intentLock.unshieldRequestHandle),
            decryptedInputAmount,
            decryptionProof
        );

        uint256 inputVaultBalanceAfterClaim = inputToken.balanceOf(address(this));
        uint256 actualClaimedUnderlyingAmount =
            inputVaultBalanceAfterClaim - inputVaultBalanceBefore;
        if (actualClaimedUnderlyingAmount != claimedUnderlyingAmount) {
            revert UnexpectedClaimedUnderlyingAmount(
                inputUnderlying, claimedUnderlyingAmount, actualClaimedUnderlyingAmount
            );
        }

        inputToken.safeTransfer(executor, claimedUnderlyingAmount);

        address outputUnderlying = _registeredUnderlyingForWrapper(outputWrapper);
        IERC20 outputToken = IERC20(outputUnderlying);
        uint256 outputVaultBalanceBefore = outputToken.balanceOf(address(this));
        outputUnderlyingAmount = IAlphaEngineSwapExecutor(executor).executeExactInput(
            inputUnderlying,
            outputUnderlying,
            claimedUnderlyingAmount,
            minOutputAmount,
            address(this),
            executionData
        );
        uint256 actualOutputUnderlyingAmount =
            outputToken.balanceOf(address(this)) - outputVaultBalanceBefore;
        if (actualOutputUnderlyingAmount != outputUnderlyingAmount) {
            revert UnexpectedSettlementOutputAmount(
                outputUnderlying, outputUnderlyingAmount, actualOutputUnderlyingAmount
            );
        }

        euint64 shieldedOutputAmount =
            _shieldOutputForSettlement(outputWrapper, intentLock.account, outputUnderlyingAmount);
        shieldedOutputHandle = euint64.unwrap(shieldedOutputAmount);

        intentLock.status = SwapIntentLockStatus.Consumed;
        emit SwapIntentLockConsumed(
            intentId, intentLock.account, intentLock.wrapper, intentLock.lockedAmount
        );
        emit SwapIntentSettled(
            intentId,
            intentLock.account,
            outputWrapper,
            decryptedInputAmount,
            outputUnderlyingAmount,
            shieldedOutputAmount
        );
    }

    function wrapperForUnderlying(address underlying) external view returns (address) {
        return _wrappersByUnderlying[underlying];
    }

    function underlyingForWrapper(address wrapper) external view returns (address) {
        return _underlyingByWrapper[wrapper];
    }

    function getSwapIntentLock(bytes32 intentId) external view returns (SwapIntentLock memory) {
        return _swapIntentLocks[intentId];
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

    function _onlyIntentController() private view {
        if (msg.sender != intentController) {
            revert UnauthorizedIntentController(msg.sender);
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

    function _registeredWrapperForUnderlying(address underlying)
        private
        view
        returns (address wrapper)
    {
        wrapper = _wrappersByUnderlying[underlying];
        if (wrapper == address(0)) {
            revert UnderlyingNotRegistered(underlying);
        }
    }

    function _registeredUnderlyingForWrapper(address wrapper)
        private
        view
        returns (address underlying)
    {
        underlying = _underlyingByWrapper[wrapper];
        if (underlying == address(0)) {
            revert WrapperNotRegistered(wrapper);
        }
    }

    function _swapIntentLockInStatus(bytes32 intentId, SwapIntentLockStatus expectedStatus)
        private
        view
        returns (SwapIntentLock storage intentLock)
    {
        if (intentId == bytes32(0)) {
            revert ZeroIntentId();
        }

        intentLock = _swapIntentLocks[intentId];
        if (intentLock.status == SwapIntentLockStatus.Unset) {
            revert SwapIntentLockNotFound(intentId);
        }
        if (intentLock.status != expectedStatus) {
            revert SwapIntentLockNotActive(intentId, intentLock.status);
        }
    }

    function _requestSwapIntentUnshield(bytes32 intentId, SwapIntentLock storage intentLock)
        private
    {
        euint64 unshieldRequestHandle = IAlphaEngineEncryptedUnshieldFHERC20Wrapper(
            intentLock.wrapper
        ).unshield(address(this), address(this), intentLock.lockedAmount);
        if (euint64.unwrap(unshieldRequestHandle) == bytes32(0)) {
            revert UninitializedEncryptedAmount();
        }

        intentLock.unshieldRequestHandle = unshieldRequestHandle;
        intentLock.status = SwapIntentLockStatus.UnshieldRequested;

        emit SwapIntentUnshieldRequested(
            intentId, intentLock.account, intentLock.wrapper, unshieldRequestHandle
        );
    }

    function _claimUnshielded(
        address wrapper,
        bytes32 unshieldRequestId,
        uint64 decryptedAmount,
        bytes calldata decryptionProof
    ) private {
        IFHERC20ERC20Wrapper(wrapper).claimUnshielded(
            unshieldRequestId, decryptedAmount, decryptionProof
        );

        emit UnshieldClaimed(wrapper, unshieldRequestId, decryptedAmount);
    }

    function _shieldOutputForSettlement(address outputWrapper, address recipient, uint256 amount)
        private
        returns (euint64 shieldedAmount)
    {
        if (recipient == address(0)) {
            revert ZeroRecipient();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        address outputUnderlying = _registeredUnderlyingForWrapper(outputWrapper);
        uint256 rate = _readWrapperRate(outputWrapper);
        if (amount % rate != 0) {
            revert AmountNotMultipleOfRate(amount, rate);
        }
        if (amount / rate > type(uint64).max) {
            revert AmountExceedsFHERC20Precision(amount, rate);
        }

        IERC20 outputToken = IERC20(outputUnderlying);
        uint256 vaultBalanceBefore = outputToken.balanceOf(address(this));
        outputToken.forceApprove(outputWrapper, amount);
        shieldedAmount = IFHERC20ERC20Wrapper(outputWrapper).shield(recipient, amount);
        outputToken.forceApprove(outputWrapper, 0);
        _assertUnderlyingBalance(outputToken, address(this), vaultBalanceBefore - amount);
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
}
