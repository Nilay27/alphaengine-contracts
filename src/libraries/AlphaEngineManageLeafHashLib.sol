// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice Canonical hashing and proof verification for AlphaEngine FundVault policy leaves.
/// @dev Leaves use ABI encoding and bind deployed code hashes. Tree nodes use commutative
///      sorted-pair hashing so proofs do not require direction bits.
library AlphaEngineManageLeafHashLib {
    bytes32 internal constant MANAGE_LEAF_V1_TYPEHASH = keccak256(
        "AlphaEngineManageLeafV1(uint256 chainId,address vaultExecutionManager,address fundVault,address decoder,bytes32 decoderCodeHash,address target,bytes32 targetCodeHash,bytes4 selector,uint256 maxNativeValue,bytes32 sanitizedArgumentsHash)"
    );

    error ZeroChainId();
    error ZeroVaultExecutionManager();
    error ZeroFundVault();
    error ZeroDecoder();
    error ZeroDecoderCodeHash();
    error ZeroTarget();
    error ZeroTargetCodeHash();
    error ZeroSelector();
    error NativeValueNotSupported(uint256 value);

    struct ManageLeafV1 {
        uint256 chainId;
        address vaultExecutionManager;
        address fundVault;
        address decoder;
        bytes32 decoderCodeHash;
        address target;
        bytes32 targetCodeHash;
        bytes4 selector;
        uint256 maxNativeValue;
        bytes sanitizedArguments;
    }

    function manageLeafV1Typehash() internal pure returns (bytes32) {
        return MANAGE_LEAF_V1_TYPEHASH;
    }

    function hashManageLeaf(ManageLeafV1 memory leaf) internal pure returns (bytes32) {
        if (leaf.chainId == 0) revert ZeroChainId();
        if (leaf.vaultExecutionManager == address(0)) revert ZeroVaultExecutionManager();
        if (leaf.fundVault == address(0)) revert ZeroFundVault();
        if (leaf.decoder == address(0)) revert ZeroDecoder();
        if (leaf.decoderCodeHash == bytes32(0)) revert ZeroDecoderCodeHash();
        if (leaf.target == address(0)) revert ZeroTarget();
        if (leaf.targetCodeHash == bytes32(0)) revert ZeroTargetCodeHash();
        if (leaf.selector == bytes4(0)) revert ZeroSelector();
        if (leaf.maxNativeValue != 0) revert NativeValueNotSupported(leaf.maxNativeValue);

        return keccak256(
            abi.encode(
                MANAGE_LEAF_V1_TYPEHASH,
                leaf.chainId,
                leaf.vaultExecutionManager,
                leaf.fundVault,
                leaf.decoder,
                leaf.decoderCodeHash,
                leaf.target,
                leaf.targetCodeHash,
                leaf.selector,
                leaf.maxNativeValue,
                keccak256(leaf.sanitizedArguments)
            )
        );
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }

    function verifyProof(bytes32[] memory proof, bytes32 root, bytes32 leaf)
        internal
        pure
        returns (bool)
    {
        return MerkleProof.verify(proof, root, leaf);
    }

    function verifyProofCalldata(bytes32[] calldata proof, bytes32 root, bytes32 leaf)
        internal
        pure
        returns (bool)
    {
        return MerkleProof.verifyCalldata(proof, root, leaf);
    }
}
