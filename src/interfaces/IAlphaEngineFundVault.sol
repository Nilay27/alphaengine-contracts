// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IAlphaEngineFundVault {
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata targetData
    ) external returns (bytes[] memory results);
}
