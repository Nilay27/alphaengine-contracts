// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

interface IAlphaEngineFundVault {
    function executionManager() external view returns (address);

    function emergencyAuthority() external view returns (address);

    function recoveryVault() external view returns (address);

    function recoveryActivated() external view returns (bool);

    function usdc() external view returns (address);

    function totalSupply() external view returns (uint256);

    function settleDeposit(address payer, address receiver, uint256 assets, uint256 shares)
        external;

    function lockRedemptionShares(address account, uint256 shares) external;

    function releaseRedemptionShares(address account, uint256 shares) external;

    function settleRedemption(address receiver, uint256 shares, uint256 assets) external;

    function mintFeeShares(address receiver, uint256 shares) external;

    function setExecutionManager(address manager) external;

    function setEmergencyConfiguration(address authority, address recoveryVault_) external;

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata targetData
    ) external returns (bytes[] memory results);

    function recoverAsset(IERC20 asset) external returns (uint256 amount);
}
