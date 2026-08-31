// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice USDC and position custody plus the AlphaEngine fund-share ledger.
/// @dev NAV and user-request accounting live in AlphaEngineUSDCVaultManager.
contract AlphaEngineFundVault is ERC20, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BATCH_CALLS = 16;

    IERC20 public immutable USDC;

    address public usdcManager;
    address public executionManager;
    address public emergencyAuthority;
    address public recoveryVault;
    bool public recoveryActivated;

    error ZeroAddress();
    error InvalidContract(address account);
    error InvalidUSDCDecimals(uint8 decimals);
    error USDCManagerAlreadySet();
    error ExecutionManagerAlreadySet();
    error EmergencyConfigurationAlreadySet();
    error IncompleteConfiguration();
    error AuthorityOverlap(address authority);
    error UnauthorizedUSDCManager(address caller);
    error UnauthorizedExecutionManager(address caller);
    error UnauthorizedPauser(address caller);
    error UnauthorizedEmergencyAuthority(address caller);
    error ZeroAssets();
    error ZeroShares();
    error AssetTransferMismatch(uint256 expected, uint256 received);
    error InsufficientUSDC(uint256 available, uint256 required);
    error EmptyBatch();
    error BatchTooLarge(uint256 supplied, uint256 maximum);
    error BatchLengthMismatch(uint256 targets, uint256 values, uint256 targetData);
    error InvalidBatchTarget(uint256 index, address target);
    error ProtectedBatchTarget(uint256 index, address target);
    error BatchCallFailed(uint256 index, address target, bytes revertData);
    error RecoveryAlreadyActivated();
    error AssetNotRecoverable(address asset);

    event USDCManagerSet(address indexed manager);
    event ExecutionManagerSet(address indexed manager);
    event EmergencyConfigurationSet(
        address indexed emergencyAuthority, address indexed recoveryVault
    );
    event BatchExecuted(address indexed manager, bytes32 indexed batchHash, uint256 callCount);
    event AssetRecovered(address indexed asset, address indexed recoveryVault, uint256 amount);
    event DepositSettled(
        address indexed payer, address indexed receiver, uint256 assets, uint256 shares
    );
    event RedemptionSharesLocked(address indexed account, uint256 shares);
    event RedemptionSharesReleased(address indexed account, uint256 shares);
    event RedemptionSettled(address indexed receiver, uint256 shares, uint256 assets);
    event FeeSharesMinted(address indexed receiver, uint256 shares);

    modifier onlyUsdcManager() {
        _checkUsdcManager();
        _;
    }

    modifier onlyExecutionManager() {
        _checkExecutionManager();
        _;
    }

    modifier onlyEmergencyAuthority() {
        _checkEmergencyAuthority();
        _;
    }

    function _checkUsdcManager() private view {
        if (msg.sender != usdcManager) revert UnauthorizedUSDCManager(msg.sender);
    }

    function _checkExecutionManager() private view {
        if (msg.sender != executionManager) revert UnauthorizedExecutionManager(msg.sender);
    }

    function _checkEmergencyAuthority() private view {
        if (msg.sender != emergencyAuthority) {
            revert UnauthorizedEmergencyAuthority(msg.sender);
        }
    }

    constructor(address owner_, IERC20 usdc_)
        ERC20("AlphaEngine USDC Fund", "aeUSDC")
        Ownable(owner_)
    {
        if (owner_ == address(0) || address(usdc_) == address(0)) revert ZeroAddress();

        uint8 assetDecimals = IERC20Metadata(address(usdc_)).decimals();
        if (assetDecimals != 6) revert InvalidUSDCDecimals(assetDecimals);

        USDC = usdc_;
        _pause();
    }

    function usdc() external view returns (address) {
        return address(USDC);
    }

    function setUsdcManager(address manager) external onlyOwner {
        if (manager == address(0) || manager.code.length == 0) revert InvalidContract(manager);
        if (usdcManager != address(0)) revert USDCManagerAlreadySet();
        if (
            manager == executionManager || manager == emergencyAuthority || manager == recoveryVault
        ) {
            revert AuthorityOverlap(manager);
        }

        usdcManager = manager;
        emit USDCManagerSet(manager);
    }

    function setExecutionManager(address manager) external onlyOwner {
        if (manager == address(0) || manager.code.length == 0) revert InvalidContract(manager);
        if (executionManager != address(0)) revert ExecutionManagerAlreadySet();
        if (manager == usdcManager || manager == emergencyAuthority || manager == recoveryVault) {
            revert AuthorityOverlap(manager);
        }

        executionManager = manager;
        emit ExecutionManagerSet(manager);
    }

    function setEmergencyConfiguration(address authority, address recoveryVault_)
        external
        onlyOwner
    {
        if (emergencyAuthority != address(0) || recoveryVault != address(0)) {
            revert EmergencyConfigurationAlreadySet();
        }
        if (authority == address(0)) revert ZeroAddress();
        if (recoveryVault_ == address(0) || recoveryVault_.code.length == 0) {
            revert InvalidContract(recoveryVault_);
        }
        if (
            authority == usdcManager || authority == executionManager || authority == recoveryVault_
        ) {
            revert AuthorityOverlap(authority);
        }
        if (
            recoveryVault_ == address(this) || recoveryVault_ == usdcManager
                || recoveryVault_ == executionManager
        ) {
            revert AuthorityOverlap(recoveryVault_);
        }

        emergencyAuthority = authority;
        recoveryVault = recoveryVault_;
        emit EmergencyConfigurationSet(authority, recoveryVault_);
    }

    function pause() external {
        if (msg.sender != owner() && msg.sender != emergencyAuthority) {
            revert UnauthorizedPauser(msg.sender);
        }
        _pause();
    }

    function unpause() external onlyOwner {
        if (
            usdcManager == address(0) || executionManager == address(0)
                || emergencyAuthority == address(0) || recoveryVault == address(0)
        ) {
            revert IncompleteConfiguration();
        }
        if (recoveryActivated) revert RecoveryAlreadyActivated();
        _unpause();
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata targetData
    ) external onlyExecutionManager whenNotPaused nonReentrant returns (bytes[] memory results) {
        uint256 callCount = targets.length;
        if (callCount == 0) revert EmptyBatch();
        if (callCount > MAX_BATCH_CALLS) revert BatchTooLarge(callCount, MAX_BATCH_CALLS);
        if (values.length != callCount || targetData.length != callCount) {
            revert BatchLengthMismatch(callCount, values.length, targetData.length);
        }

        address accountingManager = usdcManager;
        address vaultExecutionManager = executionManager;
        for (uint256 i; i < callCount; ++i) {
            address target = targets[i];
            if (
                target == address(this) || target == accountingManager
                    || target == vaultExecutionManager || target == emergencyAuthority
                    || target == recoveryVault || target == owner()
            ) {
                revert ProtectedBatchTarget(i, target);
            }
            if (target == address(0) || target.code.length == 0) {
                revert InvalidBatchTarget(i, target);
            }
        }

        results = new bytes[](callCount);
        for (uint256 i; i < callCount; ++i) {
            (bool success, bytes memory returnData) =
                targets[i].call{value: values[i]}(targetData[i]);
            if (!success) revert BatchCallFailed(i, targets[i], returnData);
            results[i] = returnData;
        }

        emit BatchExecuted(
            vaultExecutionManager, keccak256(abi.encode(targets, values, targetData)), callCount
        );
    }

    function recoverAsset(IERC20 asset)
        external
        onlyEmergencyAuthority
        whenPaused
        nonReentrant
        returns (uint256 amount)
    {
        address assetAddress = address(asset);
        if (
            assetAddress == address(0) || assetAddress == address(this)
                || assetAddress.code.length == 0
        ) {
            revert AssetNotRecoverable(assetAddress);
        }

        amount = asset.balanceOf(address(this));
        if (amount == 0) revert ZeroAssets();

        recoveryActivated = true;
        uint256 balanceBefore = asset.balanceOf(recoveryVault);
        asset.safeTransfer(recoveryVault, amount);
        uint256 received = asset.balanceOf(recoveryVault) - balanceBefore;
        if (received != amount) revert AssetTransferMismatch(amount, received);

        emit AssetRecovered(assetAddress, recoveryVault, amount);
    }

    function settleDeposit(address payer, address receiver, uint256 assets, uint256 shares)
        external
        onlyUsdcManager
        whenNotPaused
        nonReentrant
    {
        if (payer == address(0) || receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAssets();
        if (shares == 0) revert ZeroShares();

        uint256 balanceBefore = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(payer, address(this), assets);
        uint256 received = USDC.balanceOf(address(this)) - balanceBefore;
        if (received != assets) revert AssetTransferMismatch(assets, received);

        _mint(receiver, shares);
        emit DepositSettled(payer, receiver, assets, shares);
    }

    function lockRedemptionShares(address account, uint256 shares)
        external
        onlyUsdcManager
        whenNotPaused
    {
        if (account == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroShares();

        _spendAllowance(account, msg.sender, shares);
        _transfer(account, address(this), shares);
        emit RedemptionSharesLocked(account, shares);
    }

    function releaseRedemptionShares(address account, uint256 shares) external onlyUsdcManager {
        if (account == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroShares();

        _transfer(address(this), account, shares);
        emit RedemptionSharesReleased(account, shares);
    }

    function settleRedemption(address receiver, uint256 shares, uint256 assets)
        external
        onlyUsdcManager
        nonReentrant
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroShares();

        uint256 available = USDC.balanceOf(address(this));
        if (available < assets) revert InsufficientUSDC(available, assets);

        _burn(address(this), shares);
        if (assets != 0) USDC.safeTransfer(receiver, assets);
        emit RedemptionSettled(receiver, shares, assets);
    }

    function mintFeeShares(address receiver, uint256 shares) external onlyUsdcManager {
        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroShares();

        _mint(receiver, shares);
        emit FeeSharesMinted(receiver, shares);
    }
}
