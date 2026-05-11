// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";

contract UpgradeAlphaEngineIntentControllerScript is Script {
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run()
        external
        returns (AlphaEngineIntentController implementation, address proxyAdmin, address proxy)
    {
        proxy = vm.envAddress("PROXY_ADDRESS");
        address oldImplementation = _implementation(proxy);

        vm.startBroadcast();
        implementation = new AlphaEngineIntentController();
        proxyAdmin = _proxyAdmin(proxy);
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)), address(implementation), bytes("")
        );
        vm.stopBroadcast();

        address newImplementation = _implementation(proxy);

        console2.log("Proxy:", proxy);
        console2.log("Proxy admin:", proxyAdmin);
        console2.log("Implementation before:", oldImplementation);
        console2.log("New implementation:", newImplementation);
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _proxyAdmin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
    }
}

