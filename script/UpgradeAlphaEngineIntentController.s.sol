// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";

contract UpgradeAlphaEngineIntentController is Script {
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    string internal constant DEPLOYMENT_MANIFEST =
        "deployments/arbitrum-sepolia-latest.json";

    error MissingControllerProxy();

    function run()
        external
        returns (AlphaEngineIntentController implementation, address proxyAdmin)
    {
        string memory manifestPath =
            vm.envOr("DEPLOYMENT_MANIFEST", string(DEPLOYMENT_MANIFEST));
        address proxy = vm.envOr("PROXY_ADDRESS", address(0));
        if (proxy == address(0)) {
            proxy = _readControllerProxy(manifestPath);
            if (proxy == address(0)) {
                revert MissingControllerProxy();
            }
        }
        address oldImplementation = _implementation(proxy);

        vm.startBroadcast();

        implementation = new AlphaEngineIntentController();
        proxyAdmin = _proxyAdmin(proxy);
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)), address(implementation), bytes("")
        );

        vm.stopBroadcast();
        address newImplementation = _implementation(proxy);

        console2.log("Upgraded proxy:", proxy);
        console2.log("Implementation before:", oldImplementation);
        console2.log("New implementation:", newImplementation);
        console2.log("Proxy admin:", proxyAdmin);

        _writeManifest(manifestPath, newImplementation);
    }

    function _proxyAdmin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _readControllerProxy(string memory manifestPath)
        internal
        view
        returns (address)
    {
        string memory manifest = vm.readFile(manifestPath);
        return vm.parseJsonAddress(manifest, ".controllerProxy");
    }

    function _readDeploymentChainId(string memory manifest)
        internal
        view
        returns (uint256)
    {
        return vm.parseJsonUint(manifest, ".chainId");
    }

    function _readAddressField(string memory manifest, string memory key)
        internal
        pure
        returns (address)
    {
        return vm.parseJsonAddress(manifest, string.concat(".", key));
    }

    function _writeManifest(string memory manifestPath, address newImplementation) internal {
        string memory manifest = vm.readFile(manifestPath);
        uint256 chainId = _readDeploymentChainId(manifest);
        address owner = _readAddressField(manifest, "owner");
        address listenerOperator = _readAddressField(manifest, "listenerOperator");
        address controllerProxy = _readAddressField(manifest, "controllerProxy");
        address controllerProxyAdmin = _readAddressField(manifest, "controllerProxyAdmin");
        address vaultImplementation = _readAddressField(manifest, "vaultImplementation");
        address vaultProxy = _readAddressField(manifest, "vaultProxy");
        address vaultProxyAdmin = _readAddressField(manifest, "vaultProxyAdmin");
        address swapExecutor = _readAddressField(manifest, "swapExecutor");
        address poolManager = _readAddressField(manifest, "poolManager");
        address inputWrapper = _readAddressField(manifest, "inputWrapper");
        address outputWrapper = _readAddressField(manifest, "outputWrapper");

        string memory object = "deployment";
        vm.serializeUint(object, "chainId", chainId);
        vm.serializeAddress(object, "owner", owner);
        vm.serializeAddress(object, "listenerOperator", listenerOperator);
        vm.serializeAddress(object, "controllerImplementation", newImplementation);
        vm.serializeAddress(object, "controllerProxy", controllerProxy);
        vm.serializeAddress(object, "controllerProxyAdmin", controllerProxyAdmin);
        vm.serializeAddress(object, "vaultImplementation", vaultImplementation);
        vm.serializeAddress(object, "vaultProxy", vaultProxy);
        vm.serializeAddress(object, "vaultProxyAdmin", vaultProxyAdmin);
        vm.serializeAddress(object, "swapExecutor", swapExecutor);
        vm.serializeAddress(object, "poolManager", poolManager);
        vm.serializeAddress(object, "inputWrapper", inputWrapper);
        string memory updated = vm.serializeAddress(object, "outputWrapper", outputWrapper);
        vm.writeJson(updated, manifestPath);
    }
}
