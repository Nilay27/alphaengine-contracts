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

    IERC20 public immutable USDC;

    address public usdcManager;

    error ZeroAddress();
    error InvalidUSDCDecimals(uint8 decimals);
    error USDCManagerAlreadySet();
    error UnauthorizedUSDCManager(address caller);
    error ZeroAssets();
    error ZeroShares();
    error AssetTransferMismatch(uint256 expected, uint256 received);
    error InsufficientUSDC(uint256 available, uint256 required);

    event USDCManagerSet(address indexed manager);
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

    function _checkUsdcManager() private view {
        if (msg.sender != usdcManager) revert UnauthorizedUSDCManager(msg.sender);
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
        if (manager == address(0)) revert ZeroAddress();
        if (manager.code.length == 0) revert ZeroAddress();
        if (usdcManager != address(0)) revert USDCManagerAlreadySet();

        usdcManager = manager;
        emit USDCManagerSet(manager);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        if (usdcManager == address(0)) revert ZeroAddress();
        _unpause();
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
