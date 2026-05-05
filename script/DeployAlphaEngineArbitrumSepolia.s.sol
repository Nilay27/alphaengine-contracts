// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {AlphaEngineV4SwapExecutor} from "src/executors/AlphaEngineV4SwapExecutor.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DeployAlphaEngineArbitrumSepolia is Script {
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    error UnexpectedChainId(uint256 expectedChainId, uint256 actualChainId);
    error BroadcastSignerMustBeOwner(address broadcaster, address owner);
    error ConflictingSwapExecutorConfig(address existingExecutor, address poolManager);
    error MissingPoolManager();
    error MissingUnderlyingForWrapper(string prefix, address wrapper);

    struct Deployment {
        address owner;
        address listenerOperator;
        address controllerImplementation;
        address controllerProxy;
        address controllerProxyAdmin;
        address vaultImplementation;
        address vaultProxy;
        address vaultProxyAdmin;
        address swapExecutor;
        address poolManager;
        address inputWrapper;
        address outputWrapper;
    }

    function run() external returns (Deployment memory deployment) {
        address owner = vm.envAddress("OWNER");
        address listenerOperator = vm.envAddress("LISTENER_OPERATOR");
        address broadcaster = vm.envOr("BROADCASTER", address(0));
        bool skipChainCheck = vm.envOr("SKIP_CHAIN_CHECK", false);
        bool performOwnerSetup = vm.envOr("PERFORM_OWNER_SETUP", true);

        if (!skipChainCheck && block.chainid != ARBITRUM_SEPOLIA_CHAIN_ID) {
            revert UnexpectedChainId(ARBITRUM_SEPOLIA_CHAIN_ID, block.chainid);
        }
        if (performOwnerSetup && broadcaster != address(0) && broadcaster != owner) {
            revert BroadcastSignerMustBeOwner(broadcaster, owner);
        }

        address existingSwapExecutor = vm.envOr("SWAP_EXECUTOR", address(0));
        address poolManager = vm.envOr("POOL_MANAGER", address(0));
        bool deploySwapExecutor = vm.envOr("DEPLOY_SWAP_EXECUTOR", false);

        if (existingSwapExecutor != address(0) && poolManager != address(0)) {
            revert ConflictingSwapExecutorConfig(existingSwapExecutor, poolManager);
        }
        if (poolManager != address(0)) {
            deploySwapExecutor = true;
        }
        if (deploySwapExecutor && poolManager == address(0)) {
            revert MissingPoolManager();
        }

        vm.startBroadcast();

        AlphaEngineIntentController controllerImplementation = new AlphaEngineIntentController();
        TransparentUpgradeableProxy controllerProxyContract = new TransparentUpgradeableProxy(
            address(controllerImplementation),
            owner,
            abi.encodeCall(AlphaEngineIntentController.initialize, (owner, listenerOperator))
        );
        AlphaEngineIntentController controller =
            AlphaEngineIntentController(address(controllerProxyContract));

        AlphaEngineConfidentialVault vaultImplementation = new AlphaEngineConfidentialVault();
        TransparentUpgradeableProxy vaultProxyContract = new TransparentUpgradeableProxy(
            address(vaultImplementation),
            owner,
            abi.encodeCall(AlphaEngineConfidentialVault.initialize, (owner, address(controller)))
        );
        AlphaEngineConfidentialVault vault =
            AlphaEngineConfidentialVault(address(vaultProxyContract));

        address swapExecutor = existingSwapExecutor;
        if (deploySwapExecutor) {
            swapExecutor = address(
                new AlphaEngineV4SwapExecutor(IPoolManager(poolManager), owner, address(vault))
            );
        }

        address inputWrapper;
        address outputWrapper;
        if (performOwnerSetup) {
            controller.setConfidentialVault(address(vault));

            if (swapExecutor != address(0)) {
                controller.setSwapExecutor(swapExecutor);
            }

            inputWrapper = _configureWrapper(vault, "INPUT");
            outputWrapper = _configureWrapper(vault, "OUTPUT");
        }

        vm.stopBroadcast();

        deployment = Deployment({
            owner: owner,
            listenerOperator: listenerOperator,
            controllerImplementation: address(controllerImplementation),
            controllerProxy: address(controller),
            controllerProxyAdmin: _proxyAdmin(address(controller)),
            vaultImplementation: address(vaultImplementation),
            vaultProxy: address(vault),
            vaultProxyAdmin: _proxyAdmin(address(vault)),
            swapExecutor: swapExecutor,
            poolManager: poolManager,
            inputWrapper: inputWrapper,
            outputWrapper: outputWrapper
        });

        _writeManifest(deployment);
        _logDeployment(deployment);
    }

    function _configureWrapper(AlphaEngineConfidentialVault vault, string memory prefix)
        internal
        returns (address wrapper)
    {
        address underlying = vm.envOr(string.concat(prefix, "_UNDERLYING"), address(0));
        address existingWrapper = vm.envOr(string.concat(prefix, "_WRAPPER"), address(0));

        if (underlying == address(0) && existingWrapper == address(0)) {
            return address(0);
        }
        if (underlying == address(0)) {
            revert MissingUnderlyingForWrapper(prefix, existingWrapper);
        }
        if (existingWrapper != address(0)) {
            vault.registerWrapper(underlying, existingWrapper);
            return existingWrapper;
        }

        string memory name = vm.envOr(
            string.concat(prefix, "_WRAPPER_NAME"), string.concat("AlphaEngine Encrypted ", prefix)
        );
        string memory symbol =
            vm.envOr(string.concat(prefix, "_WRAPPER_SYMBOL"), string.concat("ae", prefix));
        string memory wrapperContractUri =
            vm.envOr(string.concat(prefix, "_WRAPPER_CONTRACT_URI"), string(""));

        wrapper = vault.createWrapper(underlying, name, symbol, wrapperContractUri);
    }

    function _writeManifest(Deployment memory deployment) internal {
        string memory path =
            vm.envOr("DEPLOYMENT_MANIFEST", string("deployments/arbitrum-sepolia-latest.json"));
        vm.createDir("deployments", true);

        string memory object = "deployment";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeAddress(object, "owner", deployment.owner);
        vm.serializeAddress(object, "listenerOperator", deployment.listenerOperator);
        vm.serializeAddress(object, "controllerImplementation", deployment.controllerImplementation);
        vm.serializeAddress(object, "controllerProxy", deployment.controllerProxy);
        vm.serializeAddress(object, "controllerProxyAdmin", deployment.controllerProxyAdmin);
        vm.serializeAddress(object, "vaultImplementation", deployment.vaultImplementation);
        vm.serializeAddress(object, "vaultProxy", deployment.vaultProxy);
        vm.serializeAddress(object, "vaultProxyAdmin", deployment.vaultProxyAdmin);
        vm.serializeAddress(object, "swapExecutor", deployment.swapExecutor);
        vm.serializeAddress(object, "poolManager", deployment.poolManager);
        vm.serializeAddress(object, "inputWrapper", deployment.inputWrapper);
        string memory json = vm.serializeAddress(object, "outputWrapper", deployment.outputWrapper);

        vm.writeJson(json, path);
    }

    function _logDeployment(Deployment memory deployment) internal pure {
        console2.log("AlphaEngine Arbitrum Sepolia deployment");
        console2.log("owner:", deployment.owner);
        console2.log("listener operator:", deployment.listenerOperator);
        console2.log("controller implementation:", deployment.controllerImplementation);
        console2.log("controller proxy:", deployment.controllerProxy);
        console2.log("controller proxy admin:", deployment.controllerProxyAdmin);
        console2.log("vault implementation:", deployment.vaultImplementation);
        console2.log("vault proxy:", deployment.vaultProxy);
        console2.log("vault proxy admin:", deployment.vaultProxyAdmin);
        console2.log("swap executor:", deployment.swapExecutor);
        console2.log("pool manager:", deployment.poolManager);
        console2.log("input wrapper:", deployment.inputWrapper);
        console2.log("output wrapper:", deployment.outputWrapper);
    }

    function _proxyAdmin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
    }
}
