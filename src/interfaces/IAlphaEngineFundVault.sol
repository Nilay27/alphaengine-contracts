// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IAlphaEngineFundVault {
    function usdc() external view returns (address);

    function totalSupply() external view returns (uint256);

    function settleDeposit(address payer, address receiver, uint256 assets, uint256 shares)
        external;

    function lockRedemptionShares(address account, uint256 shares) external;

    function releaseRedemptionShares(address account, uint256 shares) external;

    function settleRedemption(address receiver, uint256 shares, uint256 assets) external;

    function mintFeeShares(address receiver, uint256 shares) external;

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata targetData
    ) external returns (bytes[] memory results);
}
