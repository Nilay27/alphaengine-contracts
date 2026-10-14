// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {
    ERC20ConfidentialLib
} from "fhenix-confidential-contracts/ERC20Confidential/ERC20ConfidentialLib.sol";
import {DeployAlphaEngineV2} from "script/DeployAlphaEngineV2.s.sol";

/// @notice Reuses the v2 wiring with a pinned, sender-independent CREATE2 factory.
/// @dev Requires FOUNDRY_PROFILE=create2. Existing addresses fail closed; use --resume
///      for interrupted broadcasts rather than silently accepting existing deployments.
contract DeployAlphaEngineCreate2 is DeployAlphaEngineV2 {
    address public constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant NAMESPACE = keccak256("alphaengine-v2-create2-v1");
    bytes public constant FACTORY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    string private initCodeHashes;

    error InvalidCreate2Factory(bytes32 actualCodeHash);
    error IncorrectLibraryLink(address linked, address predicted);
    error Create2AddressOccupied(string component, address predicted);
    error Create2DeploymentFailed(string component, bytes reason);
    error Create2AddressMismatch(string component, address predicted, bytes returned);

    function deploy(DeploymentConfig memory config)
        public
        override
        returns (Deployment memory deployment)
    {
        // Reject chain, role, artifact and link mistakes before recording any transaction.
        _validateConfig(config);
        _deployContract("confidentialTokenLibrary", _libraryCreationCode());
        deployment = super.deploy(config);
    }

    function predict(string memory component, bytes memory creationCode)
        public
        pure
        returns (address)
    {
        return Create2.computeAddress(componentSalt(component), keccak256(creationCode), FACTORY);
    }

    function componentSalt(string memory component) public pure returns (bytes32) {
        return keccak256(abi.encode(NAMESPACE, component));
    }

    function writeManifest(
        string memory manifestPath,
        DeploymentConfig memory config,
        Deployment memory deployment
    ) public override {
        super.writeManifest(manifestPath, config, deployment);
        string memory object = "alphaEngineCreate2";
        vm.serializeJson(object, vm.readFile(manifestPath));
        vm.serializeString(object, "deploymentMethod", "CREATE2");
        vm.serializeString(object, "buildProfile", "create2");
        vm.serializeString(object, "bytecodeHash", "none");
        vm.serializeAddress(object, "create2Factory", FACTORY);
        vm.serializeBytes32(object, "create2FactoryCodeHash", keccak256(FACTORY_RUNTIME));
        vm.serializeBytes32(object, "create2Namespace", NAMESPACE);
        string memory json = vm.serializeString(object, "create2InitCodeHashes", initCodeHashes);
        vm.writeJson(json, manifestPath);
        vm.writeJson(initCodeHashes, manifestPath, ".create2InitCodeHashes");
    }

    function _validateConfidentialTokenLibrary() internal view override {
        if (FACTORY.codehash != keccak256(FACTORY_RUNTIME)) {
            revert InvalidCreate2Factory(FACTORY.codehash);
        }
        address predicted = predict("confidentialTokenLibrary", _libraryCreationCode());
        if (address(ERC20ConfidentialLib) != predicted) {
            revert IncorrectLibraryLink(address(ERC20ConfidentialLib), predicted);
        }
    }

    function _deployContract(string memory component, bytes memory creationCode)
        internal
        override
        returns (address deployed)
    {
        address predicted = predict(component, creationCode);
        if (predicted.code.length != 0 || vm.getNonce(predicted) != 0) {
            revert Create2AddressOccupied(component, predicted);
        }
        (bool success, bytes memory returned) =
            FACTORY.call(abi.encodePacked(componentSalt(component), creationCode));
        if (!success) revert Create2DeploymentFailed(component, returned);
        if (
            returned.length != 20 || address(bytes20(returned)) != predicted
                || predicted.code.length == 0
        ) {
            revert Create2AddressMismatch(component, predicted, returned);
        }
        initCodeHashes = vm.serializeBytes32("create2InitCodes", component, keccak256(creationCode));
        return predicted;
    }

    function _libraryCreationCode() private view returns (bytes memory) {
        return vm.getCode("ERC20ConfidentialLib.sol:ERC20ConfidentialLib");
    }
}
