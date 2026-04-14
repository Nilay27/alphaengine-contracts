// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";

contract DeployAlphaEngineIntentController is Script {
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function run()
        external
        returns (
            AlphaEngineIntentController implementation,
            TransparentUpgradeableProxy proxy,
            address proxyAdmin
        )
    {
        address owner = vm.envAddress("OWNER");
        address listenerOperator = vm.envAddress("LISTENER_OPERATOR");

        vm.startBroadcast();

        implementation = new AlphaEngineIntentController();
        proxy = new TransparentUpgradeableProxy(
            address(implementation),
            owner,
            abi.encodeCall(AlphaEngineIntentController.initialize, (owner, listenerOperator))
        );

        vm.stopBroadcast();

        proxyAdmin = _proxyAdmin(address(proxy));

        console2.log("AlphaEngineIntentController implementation:", address(implementation));
        console2.log("AlphaEngineIntentController proxy:", address(proxy));
        console2.log("AlphaEngineIntentController proxy admin:", proxyAdmin);
    }

    function _proxyAdmin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
    }
}
