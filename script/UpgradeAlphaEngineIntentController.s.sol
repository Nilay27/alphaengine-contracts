// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";

contract UpgradeAlphaEngineIntentController is Script {
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function run()
        external
        returns (AlphaEngineIntentController implementation, address proxyAdmin)
    {
        address proxy = vm.envAddress("PROXY_ADDRESS");

        vm.startBroadcast();

        implementation = new AlphaEngineIntentController();
        proxyAdmin = _proxyAdmin(proxy);
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)), address(implementation), bytes("")
        );

        vm.stopBroadcast();

        console2.log("Upgraded proxy:", proxy);
        console2.log("New implementation:", address(implementation));
        console2.log("Proxy admin:", proxyAdmin);
    }

    function _proxyAdmin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
    }
}
