// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {AlphaEngineManageLeafHashLib} from "../src/libraries/AlphaEngineManageLeafHashLib.sol";

/// @notice Deterministic generator for AlphaEngine Merkle policy roots and proofs.
/// @dev The built-in reference policy uses placeholder addresses and is never a deployment policy.
contract GenerateAlphaEngineManageRoot is Script {
    uint256 public constant MAX_POLICY_LEAVES = 256;
    uint256 public constant ARTIFACT_SCHEMA_VERSION = 1;

    error EmptyPolicy();
    error TooManyPolicyLeaves(uint256 supplied, uint256 maximum);
    error ZeroExecutor();
    error ZeroPolicyVersion();
    error EmptyLeafLabel(uint256 index);
    error DuplicatePolicyLeaf(bytes32 leaf);
    error EmptyOutputPath();

    struct PolicyMetadata {
        uint256 chainId;
        address vaultExecutionManager;
        address fundVault;
        address executor;
        uint64 policyVersion;
        bool referenceOnly;
    }

    struct LabeledManageLeafV1 {
        string label;
        address decoder;
        bytes32 decoderCodeHash;
        address target;
        bytes32 targetCodeHash;
        bytes4 selector;
        uint256 maxNativeValue;
        bytes sanitizedArguments;
    }

    struct GeneratedPolicy {
        PolicyMetadata metadata;
        LabeledManageLeafV1[] leaves;
        bytes32[] leafHashes;
        bytes32[][] tree;
        bytes32[][] proofs;
        bytes32 root;
    }

    function run() external returns (bytes32 root) {
        string memory outputPath = vm.envOr(
            "MANAGE_ROOT_OUTPUT_PATH", string("artifacts/alphaengine-manage-root-reference-v1.json")
        );
        (PolicyMetadata memory metadata, LabeledManageLeafV1[] memory definitions) =
            referencePolicy();
        root = writePolicyArtifact(outputPath, metadata, definitions);
    }

    function generatePolicy(
        PolicyMetadata memory metadata,
        LabeledManageLeafV1[] memory definitions
    ) public pure returns (GeneratedPolicy memory policy) {
        policy = _generatePolicy(metadata, definitions);
    }

    function renderPolicyArtifact(GeneratedPolicy memory policy)
        public
        returns (string memory json)
    {
        string memory object = "alphaengine-manage-policy-v1";
        vm.serializeUint(object, "schemaVersion", ARTIFACT_SCHEMA_VERSION);
        vm.serializeBool(object, "referenceOnly", policy.metadata.referenceOnly);
        vm.serializeUint(object, "chainId", policy.metadata.chainId);
        vm.serializeAddress(object, "vaultExecutionManager", policy.metadata.vaultExecutionManager);
        vm.serializeAddress(object, "fundVault", policy.metadata.fundVault);
        vm.serializeAddress(object, "executor", policy.metadata.executor);
        vm.serializeUint(object, "policyVersion", policy.metadata.policyVersion);
        vm.serializeBytes32(
            object, "manageLeafV1Typehash", AlphaEngineManageLeafHashLib.manageLeafV1Typehash()
        );
        vm.serializeUint(object, "leafCount", policy.leafHashes.length);
        vm.serializeBytes32(object, "root", policy.root);

        _serializeLeafColumns(object, policy);
        _serializeProofs(object, policy.proofs);
        json = _serializeTree(object, policy.tree);
    }

    function writePolicyArtifact(
        string memory outputPath,
        PolicyMetadata memory metadata,
        LabeledManageLeafV1[] memory definitions
    ) public returns (bytes32 root) {
        if (bytes(outputPath).length == 0) revert EmptyOutputPath();
        GeneratedPolicy memory policy = _generatePolicy(metadata, definitions);
        vm.writeJson(renderPolicyArtifact(policy), outputPath);
        root = policy.root;
    }

    function referencePolicy()
        public
        pure
        returns (PolicyMetadata memory metadata, LabeledManageLeafV1[] memory definitions)
    {
        metadata = PolicyMetadata({
            chainId: 421_614,
            vaultExecutionManager: 0x1111111111111111111111111111111111111111,
            fundVault: 0x2222222222222222222222222222222222222222,
            executor: 0x3333333333333333333333333333333333333333,
            policyVersion: 7,
            referenceOnly: true
        });

        address[5] memory decoders =
            [address(0x0100), address(0x0101), address(0x0102), address(0x0103), address(0x0104)];
        address[5] memory targets =
            [address(0x0200), address(0x0201), address(0x0202), address(0x0203), address(0x0204)];
        address[5] memory argumentAddresses =
            [address(0x0300), address(0x0301), address(0x0302), address(0x0303), address(0x0304)];
        definitions = new LabeledManageLeafV1[](5);
        for (uint256 i; i < definitions.length; ++i) {
            string memory index = Strings.toString(i);
            definitions[i] = LabeledManageLeafV1({
                label: string.concat("reference-action-", index),
                decoder: decoders[i],
                decoderCodeHash: keccak256(bytes(string.concat("reference-decoder-code-", index))),
                target: targets[i],
                targetCodeHash: keccak256(bytes(string.concat("reference-target-code-", index))),
                selector: bytes4(keccak256(bytes(string.concat("referenceAction", index, "(address)")))),
                maxNativeValue: 0,
                sanitizedArguments: abi.encode(argumentAddresses[i])
            });
        }
    }

    function _generatePolicy(
        PolicyMetadata memory metadata,
        LabeledManageLeafV1[] memory definitions
    ) private pure returns (GeneratedPolicy memory policy) {
        uint256 count = definitions.length;
        if (count == 0) revert EmptyPolicy();
        if (count > MAX_POLICY_LEAVES) {
            revert TooManyPolicyLeaves(count, MAX_POLICY_LEAVES);
        }
        if (metadata.executor == address(0)) revert ZeroExecutor();
        if (metadata.policyVersion == 0) revert ZeroPolicyVersion();

        bytes32[] memory hashes = new bytes32[](count);
        uint256[] memory sourceIndices = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            if (bytes(definitions[i].label).length == 0) revert EmptyLeafLabel(i);
            hashes[i] = _hashDefinition(metadata, definitions[i]);
            sourceIndices[i] = i;
        }
        _sort(hashes, sourceIndices);

        LabeledManageLeafV1[] memory sortedDefinitions = new LabeledManageLeafV1[](count);
        for (uint256 i; i < count; ++i) {
            if (i != 0 && hashes[i] == hashes[i - 1]) revert DuplicatePolicyLeaf(hashes[i]);
            sortedDefinitions[i] = definitions[sourceIndices[i]];
        }

        bytes32[][] memory tree = _buildTree(hashes);
        policy = GeneratedPolicy({
            metadata: metadata,
            leaves: sortedDefinitions,
            leafHashes: hashes,
            tree: tree,
            proofs: _buildProofs(tree),
            root: tree[tree.length - 1][0]
        });
    }

    function _hashDefinition(PolicyMetadata memory metadata, LabeledManageLeafV1 memory definition)
        private
        pure
        returns (bytes32)
    {
        return AlphaEngineManageLeafHashLib.hashManageLeaf(
            AlphaEngineManageLeafHashLib.ManageLeafV1({
                chainId: metadata.chainId,
                vaultExecutionManager: metadata.vaultExecutionManager,
                fundVault: metadata.fundVault,
                decoder: definition.decoder,
                decoderCodeHash: definition.decoderCodeHash,
                target: definition.target,
                targetCodeHash: definition.targetCodeHash,
                selector: definition.selector,
                maxNativeValue: definition.maxNativeValue,
                sanitizedArguments: definition.sanitizedArguments
            })
        );
    }

    function _sort(bytes32[] memory hashes, uint256[] memory sourceIndices) private pure {
        for (uint256 i = 1; i < hashes.length; ++i) {
            bytes32 hash = hashes[i];
            uint256 sourceIndex = sourceIndices[i];
            uint256 j = i;
            while (j != 0 && hash < hashes[j - 1]) {
                hashes[j] = hashes[j - 1];
                sourceIndices[j] = sourceIndices[j - 1];
                unchecked {
                    --j;
                }
            }
            hashes[j] = hash;
            sourceIndices[j] = sourceIndex;
        }
    }

    function _buildTree(bytes32[] memory sortedLeaves)
        private
        pure
        returns (bytes32[][] memory tree)
    {
        uint256 depth = 1;
        uint256 layerLength = sortedLeaves.length;
        while (layerLength > 1) {
            layerLength = (layerLength + 1) / 2;
            ++depth;
        }

        tree = new bytes32[][](depth);
        tree[0] = sortedLeaves;
        for (uint256 layerIndex = 1; layerIndex < depth; ++layerIndex) {
            bytes32[] memory previousLayer = tree[layerIndex - 1];
            bytes32[] memory nextLayer = new bytes32[]((previousLayer.length + 1) / 2);
            for (uint256 i; i < previousLayer.length; i += 2) {
                nextLayer[i / 2] = i + 1 == previousLayer.length
                    ? previousLayer[i]
                    : AlphaEngineManageLeafHashLib.hashPair(previousLayer[i], previousLayer[i + 1]);
            }
            tree[layerIndex] = nextLayer;
        }
    }

    function _buildProofs(bytes32[][] memory tree)
        private
        pure
        returns (bytes32[][] memory proofs)
    {
        proofs = new bytes32[][](tree[0].length);
        for (uint256 i; i < proofs.length; ++i) {
            proofs[i] = _proofFor(tree, i);
        }
    }

    function _proofFor(bytes32[][] memory tree, uint256 leafIndex)
        private
        pure
        returns (bytes32[] memory proof)
    {
        uint256 nodeIndex = leafIndex;
        uint256 proofLength;
        for (uint256 layerIndex; layerIndex + 1 < tree.length; ++layerIndex) {
            uint256 siblingIndex = nodeIndex ^ 1;
            if (siblingIndex < tree[layerIndex].length) ++proofLength;
            nodeIndex /= 2;
        }

        proof = new bytes32[](proofLength);
        nodeIndex = leafIndex;
        uint256 proofIndex;
        for (uint256 layerIndex; layerIndex + 1 < tree.length; ++layerIndex) {
            uint256 siblingIndex = nodeIndex ^ 1;
            if (siblingIndex < tree[layerIndex].length) {
                proof[proofIndex] = tree[layerIndex][siblingIndex];
                ++proofIndex;
            }
            nodeIndex /= 2;
        }
    }

    function _serializeLeafColumns(string memory object, GeneratedPolicy memory policy) private {
        uint256 count = policy.leaves.length;
        string[] memory labels = new string[](count);
        address[] memory decoders = new address[](count);
        bytes32[] memory decoderCodeHashes = new bytes32[](count);
        address[] memory targets = new address[](count);
        bytes32[] memory targetCodeHashes = new bytes32[](count);
        string[] memory selectors = new string[](count);
        uint256[] memory maxNativeValues = new uint256[](count);
        bytes[] memory sanitizedArguments = new bytes[](count);
        bytes32[] memory sanitizedArgumentsHashes = new bytes32[](count);

        for (uint256 i; i < count; ++i) {
            LabeledManageLeafV1 memory leaf = policy.leaves[i];
            labels[i] = leaf.label;
            decoders[i] = leaf.decoder;
            decoderCodeHashes[i] = leaf.decoderCodeHash;
            targets[i] = leaf.target;
            targetCodeHashes[i] = leaf.targetCodeHash;
            selectors[i] = Strings.toHexString(uint32(leaf.selector), 4);
            maxNativeValues[i] = leaf.maxNativeValue;
            sanitizedArguments[i] = leaf.sanitizedArguments;
            sanitizedArgumentsHashes[i] = keccak256(leaf.sanitizedArguments);
        }

        vm.serializeString(object, "labels", labels);
        vm.serializeAddress(object, "decoders", decoders);
        vm.serializeBytes32(object, "decoderCodeHashes", decoderCodeHashes);
        vm.serializeAddress(object, "targets", targets);
        vm.serializeBytes32(object, "targetCodeHashes", targetCodeHashes);
        vm.serializeString(object, "selectors", selectors);
        vm.serializeUint(object, "maxNativeValues", maxNativeValues);
        vm.serializeBytes(object, "sanitizedArguments", sanitizedArguments);
        vm.serializeBytes32(object, "sanitizedArgumentsHashes", sanitizedArgumentsHashes);
        vm.serializeBytes32(object, "leafHashes", policy.leafHashes);
    }

    function _serializeProofs(string memory object, bytes32[][] memory proofs) private {
        (uint256[] memory offsets, bytes32[] memory nodes) = _flatten(proofs);
        vm.serializeUint(object, "proofOffsets", offsets);
        vm.serializeBytes32(object, "proofNodes", nodes);
    }

    function _serializeTree(string memory object, bytes32[][] memory tree)
        private
        returns (string memory json)
    {
        (uint256[] memory offsets, bytes32[] memory nodes) = _flatten(tree);
        vm.serializeUint(object, "treeLayerOffsets", offsets);
        json = vm.serializeBytes32(object, "treeNodes", nodes);
    }

    function _flatten(bytes32[][] memory values)
        private
        pure
        returns (uint256[] memory offsets, bytes32[] memory flattened)
    {
        offsets = new uint256[](values.length + 1);
        uint256 total;
        for (uint256 i; i < values.length; ++i) {
            offsets[i] = total;
            total += values[i].length;
        }
        offsets[values.length] = total;

        flattened = new bytes32[](total);
        uint256 cursor;
        for (uint256 i; i < values.length; ++i) {
            for (uint256 j; j < values[i].length; ++j) {
                flattened[cursor] = values[i][j];
                ++cursor;
            }
        }
    }
}
