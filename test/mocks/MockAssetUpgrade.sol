// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    AlphaEngineConfidentialAssetRegistry
} from "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {
    AlphaEngineConfidentialAssetGateway
} from "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";

contract AssetRegistryV2 is AlphaEngineConfidentialAssetRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AssetGatewayV2 is AlphaEngineConfidentialAssetGateway {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AssetWrapperV2 is AlphaEngineFHERC20ERC20Wrapper {
    function version() external pure returns (uint256) {
        return 2;
    }
}
