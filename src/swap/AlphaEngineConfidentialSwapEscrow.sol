// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FHE, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {
    IFHERC20ERC20Wrapper
} from "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {IERC7984} from "fhenix-confidential-contracts/interfaces/IERC7984.sol";
import {
    IAlphaEngineEncryptedUnshieldFHERC20Wrapper
} from "../interfaces/IAlphaEngineEncryptedUnshieldFHERC20Wrapper.sol";
import {
    IAlphaEngineConfidentialAssetRegistry
} from "../interfaces/IAlphaEngineConfidentialAssetRegistry.sol";
import {
    IAlphaEngineConfidentialSwapEscrow
} from "../interfaces/IAlphaEngineConfidentialSwapEscrow.sol";
import {IAlphaEngineSwapExecutor} from "../interfaces/IAlphaEngineSwapExecutor.sol";

import {
    ERC20ConfidentialLib
} from "fhenix-confidential-contracts/ERC20Confidential/ERC20ConfidentialLib.sol";

/// @title AlphaEngineConfidentialSwapEscrow
/// @notice Temporary FHERC20 custody and settlement boundary for confidential swaps.
/// @dev Wrapper administration and ordinary user shielding are deliberately excluded. The exact
///      controller owns lifecycle decisions; this contract owns only lock accounting and assets.
contract AlphaEngineConfidentialSwapEscrow is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IAlphaEngineConfidentialSwapEscrow
{
    using SafeERC20 for IERC20;

    uint48 public constant DEFAULT_ADMIN_DELAY = 48 hours;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    error ZeroInitialDefaultAdmin();
    error ZeroInitialPauser();
    error InvalidSwapController(address controller);
    error InvalidAssetRegistry(address registry);
    error UnauthorizedSwapController(address caller);
    error ZeroIntentId();
    error ZeroAccount();
    error ZeroRecipient();
    error ZeroAmount();
    error UninitializedEncryptedAmount();
    error WrapperNotRegistered(address wrapper);
    error InvalidWrapper(address wrapper);
    error SwapIntentLockAlreadyExists(bytes32 intentId);
    error SwapIntentLockNotFound(bytes32 intentId);
    error SwapIntentLockNotActive(bytes32 intentId, SwapIntentLockStatus status);
    error ActiveSwapLocksPresent(uint256 liveSwapLockCount);
    error ConfigurationUnchanged(bytes32 field, address currentValue);
    error AmountExceedsFHERC20Precision(uint256 amount, uint256 rate);
    error UnexpectedUnderlyingBalance(
        address account, address underlying, uint256 expectedBalance, uint256 actualBalance
    );
    error InvalidSwapExecutor(address executor);
    error UnexpectedClaimedUnderlyingAmount(
        address underlying, uint256 expectedAmount, uint256 actualAmount
    );
    error InvalidUnshieldClaim(
        bytes32 requestId,
        address expectedRecipient,
        address actualRecipient,
        uint64 expectedDecryptedAmount,
        uint64 actualDecryptedAmount
    );
    error InsufficientPreclaimedUnderlying(
        address underlying, uint256 requiredAmount, uint256 availableAmount
    );
    error UnexpectedSettlementOutputAmount(
        address underlying, uint256 expectedAmount, uint256 actualAmount
    );
    error OutputAmountBelowMinimum(uint256 minimumAmount, uint256 actualAmount);

    event SwapControllerUpdated(
        address indexed previousSwapController, address indexed newSwapController
    );
    event AssetRegistryUpdated(
        address indexed previousAssetRegistry, address indexed newAssetRegistry
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
        euint64 unshieldRequestHandle,
        bytes32 unshieldClaimId
    );
    event SwapIntentSettled(
        bytes32 indexed intentId,
        address indexed account,
        address indexed outputWrapper,
        uint64 decryptedInputAmount,
        uint256 outputUnderlyingAmount,
        euint64 shieldedOutputAmount
    );
    event SwapSettlementDustReturned(
        bytes32 indexed intentId,
        address indexed account,
        address indexed outputUnderlying,
        uint256 dustAmount
    );
    event SwapIntentLockRefunded(
        bytes32 indexed intentId,
        address indexed account,
        address indexed inputWrapper,
        uint64 decryptedInputAmount,
        euint64 refundedShieldedAmount
    );

    address public override swapController;
    address public override assetRegistry;
    uint256 public override liveSwapLockCount;

    mapping(bytes32 intentId => SwapIntentLock lock) private _swapIntentLocks;

    /// @dev Four repository-owned slots plus this gap reserve 50 storage slots.
    uint256[46] private __gap;

    modifier onlySwapController() {
        _onlySwapController();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialDefaultAdmin,
        address initialPauser,
        address initialSwapController,
        address initialAssetRegistry
    ) external initializer {
        if (initialDefaultAdmin == address(0)) {
            revert ZeroInitialDefaultAdmin();
        }
        if (initialPauser == address(0)) {
            revert ZeroInitialPauser();
        }
        _validateSwapController(initialSwapController);
        _validateAssetRegistry(initialAssetRegistry);

        __AccessControlDefaultAdminRules_init(DEFAULT_ADMIN_DELAY, initialDefaultAdmin);
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(PAUSER_ROLE, initialPauser);
        swapController = initialSwapController;
        assetRegistry = initialAssetRegistry;
        _pause();

        emit SwapControllerUpdated(address(0), initialSwapController);
        emit AssetRegistryUpdated(address(0), initialAssetRegistry);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function paused()
        public
        view
        override(PausableUpgradeable, IAlphaEngineConfidentialSwapEscrow)
        returns (bool)
    {
        return super.paused();
    }

    /// @notice Unpausing is intentionally restricted to delayed governance, not the pauser.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function setSwapController(address newSwapController)
        external
        whenPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _requireNoActiveSwapLocks();
        _validateSwapController(newSwapController);
        address previousSwapController = swapController;
        if (newSwapController == previousSwapController) {
            revert ConfigurationUnchanged("SWAP_CONTROLLER", newSwapController);
        }

        swapController = newSwapController;
        emit SwapControllerUpdated(previousSwapController, newSwapController);
    }

    function setAssetRegistry(address newAssetRegistry)
        external
        whenPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _requireNoActiveSwapLocks();
        _validateAssetRegistry(newAssetRegistry);
        address previousAssetRegistry = assetRegistry;
        if (newAssetRegistry == previousAssetRegistry) {
            revert ConfigurationUnchanged("ASSET_REGISTRY", newAssetRegistry);
        }

        assetRegistry = newAssetRegistry;
        emit AssetRegistryUpdated(previousAssetRegistry, newAssetRegistry);
    }

    function lockForSwapIntent(
        bytes32 intentId,
        address account,
        address wrapper,
        euint64 requestedAmount
    )
        external
        override
        onlySwapController
        whenNotPaused
        nonReentrant
        returns (euint64 lockedAmount)
    {
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

        lockedAmount = FHE.receiveEuint64FromCall(
            IERC7984(wrapper)
                .confidentialTransferFrom(
                    account, address(this), FHE.shareEuint64(requestedAmount, wrapper)
                ),
            wrapper
        );
        FHE.allowThis(lockedAmount);
        if (euint64.unwrap(lockedAmount) == bytes32(0)) {
            revert UninitializedEncryptedAmount();
        }

        _swapIntentLocks[intentId] = SwapIntentLock({
            account: account,
            wrapper: wrapper,
            lockedAmount: lockedAmount,
            unshieldRequestHandle: euint64.wrap(bytes32(0)),
            status: SwapIntentLockStatus.Locked,
            unshieldClaimId: bytes32(0)
        });
        liveSwapLockCount += 1;

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
        override
        onlySwapController
        whenNotPaused
        nonReentrant
        returns (uint256 outputUnderlyingAmount, bytes32 shieldedOutputHandle)
    {
        if (executor == address(0) || executor.code.length == 0) {
            revert InvalidSwapExecutor(executor);
        }
        address outputUnderlying = _registeredUnderlyingForWrapper(outputWrapper);
        if (decryptedInputAmount == 0) {
            revert ZeroAmount();
        }

        SwapIntentLock storage intentLock =
            _swapIntentLockInStatus(intentId, SwapIntentLockStatus.UnshieldRequested);
        address inputUnderlying = _registeredUnderlyingForWrapper(intentLock.wrapper);
        uint256 claimedUnderlyingAmount =
            uint256(decryptedInputAmount) * _readWrapperRate(intentLock.wrapper);

        intentLock.status = SwapIntentLockStatus.Consumed;
        liveSwapLockCount -= 1;

        _claimExactInputUnderlying(
            intentLock,
            inputUnderlying,
            decryptedInputAmount,
            claimedUnderlyingAmount,
            decryptionProof
        );
        IERC20(inputUnderlying).safeTransfer(executor, claimedUnderlyingAmount);

        outputUnderlyingAmount = _executeAndMeasureOutput(
            executor,
            inputUnderlying,
            outputUnderlying,
            claimedUnderlyingAmount,
            minOutputAmount,
            executionData
        );

        euint64 shieldedOutputAmount = _shieldOutputForSettlement(
            intentId, outputWrapper, intentLock.account, outputUnderlyingAmount
        );
        shieldedOutputHandle = euint64.unwrap(shieldedOutputAmount);

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

    function refundSwapIntent(
        bytes32 intentId,
        uint64 decryptedInputAmount,
        bytes calldata decryptionProof
    ) external override onlySwapController nonReentrant returns (bytes32 refundedShieldedHandle) {
        SwapIntentLock storage intentLock =
            _swapIntentLockInStatus(intentId, SwapIntentLockStatus.UnshieldRequested);
        address inputUnderlying = _registeredUnderlyingForWrapper(intentLock.wrapper);
        uint256 claimedUnderlyingAmount =
            uint256(decryptedInputAmount) * _readWrapperRate(intentLock.wrapper);

        intentLock.status = SwapIntentLockStatus.Refunded;
        liveSwapLockCount -= 1;

        _claimExactInputUnderlying(
            intentLock,
            inputUnderlying,
            decryptedInputAmount,
            claimedUnderlyingAmount,
            decryptionProof
        );

        euint64 refundedShieldedAmount;
        if (claimedUnderlyingAmount != 0) {
            refundedShieldedAmount = _shieldOutputForSettlement(
                intentId, intentLock.wrapper, intentLock.account, claimedUnderlyingAmount
            );
        }
        refundedShieldedHandle = euint64.unwrap(refundedShieldedAmount);

        emit SwapIntentLockRefunded(
            intentId,
            intentLock.account,
            intentLock.wrapper,
            decryptedInputAmount,
            refundedShieldedAmount
        );
    }

    function existsSwapIntentLock(bytes32 intentId) external view override returns (bool) {
        return _swapIntentLocks[intentId].status != SwapIntentLockStatus.Unset;
    }

    function getSwapIntentLock(bytes32 intentId)
        external
        view
        override
        returns (SwapIntentLock memory intentLock)
    {
        intentLock = _swapIntentLocks[intentId];
        if (intentLock.status == SwapIntentLockStatus.Unset) {
            revert SwapIntentLockNotFound(intentId);
        }
    }

    function _claimExactInputUnderlying(
        SwapIntentLock storage intentLock,
        address inputUnderlying,
        uint64 decryptedInputAmount,
        uint256 expectedUnderlyingAmount,
        bytes calldata decryptionProof
    ) private {
        IERC20 inputToken = IERC20(inputUnderlying);
        uint256 balanceBefore = inputToken.balanceOf(address(this));
        bytes32 requestId = intentLock.unshieldClaimId;
        ERC20ConfidentialLib.Claim memory claim =
            IAlphaEngineEncryptedUnshieldFHERC20Wrapper(intentLock.wrapper).getClaim(requestId);

        if (
            claim.id != requestId || claim.to != address(this)
                || claim.ctHash != euint64.unwrap(intentLock.unshieldRequestHandle)
        ) {
            revert InvalidUnshieldClaim(
                requestId, address(this), claim.to, decryptedInputAmount, claim.decryptedAmount
            );
        }

        if (claim.claimed) {
            if (claim.decryptedAmount != decryptedInputAmount) {
                revert InvalidUnshieldClaim(
                    requestId, address(this), claim.to, decryptedInputAmount, claim.decryptedAmount
                );
            }
            if (balanceBefore < expectedUnderlyingAmount) {
                revert InsufficientPreclaimedUnderlying(
                    inputUnderlying, expectedUnderlyingAmount, balanceBefore
                );
            }
            return;
        }

        IFHERC20ERC20Wrapper(intentLock.wrapper)
            .claimUnshielded(requestId, decryptedInputAmount, decryptionProof);

        uint256 balanceAfter = inputToken.balanceOf(address(this));
        uint256 actualUnderlyingAmount =
            balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (actualUnderlyingAmount != expectedUnderlyingAmount) {
            revert UnexpectedClaimedUnderlyingAmount(
                inputUnderlying, expectedUnderlyingAmount, actualUnderlyingAmount
            );
        }
    }

    function _executeAndMeasureOutput(
        address executor,
        address inputUnderlying,
        address outputUnderlying,
        uint256 inputAmount,
        uint256 minOutputAmount,
        bytes calldata executionData
    ) private returns (uint256 outputUnderlyingAmount) {
        IERC20 outputToken = IERC20(outputUnderlying);
        uint256 outputBalanceBefore = outputToken.balanceOf(address(this));

        outputUnderlyingAmount = IAlphaEngineSwapExecutor(executor)
            .executeExactInput(
                inputUnderlying,
                outputUnderlying,
                inputAmount,
                minOutputAmount,
                address(this),
                executionData
            );

        uint256 outputBalanceAfter = outputToken.balanceOf(address(this));
        uint256 actualOutputUnderlyingAmount = outputBalanceAfter >= outputBalanceBefore
            ? outputBalanceAfter - outputBalanceBefore
            : 0;
        if (actualOutputUnderlyingAmount != outputUnderlyingAmount) {
            revert UnexpectedSettlementOutputAmount(
                outputUnderlying, outputUnderlyingAmount, actualOutputUnderlyingAmount
            );
        }
        if (outputUnderlyingAmount < minOutputAmount) {
            revert OutputAmountBelowMinimum(minOutputAmount, outputUnderlyingAmount);
        }
    }

    function _requestSwapIntentUnshield(bytes32 intentId, SwapIntentLock storage intentLock)
        private
    {
        address wrapper = intentLock.wrapper;
        euint64 unshieldRequestHandle = FHE.receiveEuint64FromCall(
            IFHERC20ERC20Wrapper(wrapper)
                .unshield(
                    address(this), address(this), FHE.shareEuint64(intentLock.lockedAmount, wrapper)
                ),
            wrapper
        );
        FHE.allowThis(unshieldRequestHandle);
        bytes32 claimId = IAlphaEngineEncryptedUnshieldFHERC20Wrapper(wrapper)
            .latestUnshieldClaimId(address(this));
        ERC20ConfidentialLib.Claim memory claim =
            IAlphaEngineEncryptedUnshieldFHERC20Wrapper(wrapper).getClaim(claimId);
        if (
            claimId == bytes32(0) || claim.id != claimId || claim.to != address(this)
                || claim.ctHash != euint64.unwrap(unshieldRequestHandle) || claim.claimed
        ) {
            revert InvalidUnshieldClaim(claimId, address(this), claim.to, 0, claim.decryptedAmount);
        }
        if (euint64.unwrap(unshieldRequestHandle) == bytes32(0)) {
            revert UninitializedEncryptedAmount();
        }

        intentLock.unshieldRequestHandle = unshieldRequestHandle;
        intentLock.unshieldClaimId = claimId;
        intentLock.status = SwapIntentLockStatus.UnshieldRequested;

        emit SwapIntentUnshieldRequested(
            intentId, intentLock.account, intentLock.wrapper, unshieldRequestHandle, claimId
        );
    }

    function _shieldOutputForSettlement(
        bytes32 intentId,
        address outputWrapper,
        address recipient,
        uint256 amount
    ) private returns (euint64 shieldedAmount) {
        if (recipient == address(0)) {
            revert ZeroRecipient();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        address outputUnderlying = _registeredUnderlyingForWrapper(outputWrapper);
        uint256 rate = _readWrapperRate(outputWrapper);
        uint256 dustAmount = amount % rate;
        uint256 shieldableAmount = amount - dustAmount;
        if (shieldableAmount / rate > type(uint64).max) {
            revert AmountExceedsFHERC20Precision(amount, rate);
        }

        IERC20 outputToken = IERC20(outputUnderlying);
        uint256 escrowBalanceBefore = outputToken.balanceOf(address(this));
        uint256 wrapperBalanceBefore = outputToken.balanceOf(outputWrapper);
        uint256 recipientBalanceBefore = outputToken.balanceOf(recipient);
        if (escrowBalanceBefore < amount) {
            revert UnexpectedUnderlyingBalance(
                address(this), outputUnderlying, amount, escrowBalanceBefore
            );
        }

        if (shieldableAmount != 0) {
            outputToken.forceApprove(outputWrapper, shieldableAmount);
            shieldedAmount = FHE.receiveEuint64FromCall(
                IFHERC20ERC20Wrapper(outputWrapper).shield(recipient, shieldableAmount),
                outputWrapper
            );
            outputToken.forceApprove(outputWrapper, 0);
        }
        if (dustAmount != 0) {
            outputToken.safeTransfer(recipient, dustAmount);
            emit SwapSettlementDustReturned(intentId, recipient, outputUnderlying, dustAmount);
        }

        _assertUnderlyingBalance(outputToken, address(this), escrowBalanceBefore - amount);
        _assertUnderlyingBalance(
            outputToken, outputWrapper, wrapperBalanceBefore + shieldableAmount
        );
        _assertUnderlyingBalance(outputToken, recipient, recipientBalanceBefore + dustAmount);
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

    function _registeredUnderlyingForWrapper(address wrapper)
        private
        view
        returns (address underlying)
    {
        underlying =
            IAlphaEngineConfidentialAssetRegistry(assetRegistry).underlyingForWrapper(wrapper);
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

    function _requireNoActiveSwapLocks() private view {
        if (liveSwapLockCount != 0) {
            revert ActiveSwapLocksPresent(liveSwapLockCount);
        }
    }

    function _onlySwapController() private view {
        if (msg.sender != swapController) {
            revert UnauthorizedSwapController(msg.sender);
        }
    }

    function _validateSwapController(address controller) private view {
        if (controller == address(0) || controller.code.length == 0) {
            revert InvalidSwapController(controller);
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
