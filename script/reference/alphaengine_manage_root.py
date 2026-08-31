#!/usr/bin/env python3
"""Dependency-free reference generator for the AlphaEngine V1 manage-root fixture."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from alphaengine_hash_vectors import address, bytes32, fixed_hash, hash_type, hex32, keccak256, word


TYPE_STRING = (
    "AlphaEngineManageLeafV1(uint256 chainId,address vaultExecutionManager,"
    "address fundVault,address decoder,bytes32 decoderCodeHash,address target,"
    "bytes32 targetCodeHash,bytes4 selector,uint256 maxNativeValue,"
    "bytes32 sanitizedArgumentsHash)"
)


def _hex(data: bytes) -> str:
    return "0x" + data.hex()


def _abi_bytes4(value: bytes) -> bytes:
    if len(value) != 4:
        raise ValueError("selector must be four bytes")
    return value + b"\x00" * 28


def _address_number(value: int) -> str:
    return f"0x{value:040x}"


def _hash_pair(left: bytes, right: bytes) -> bytes:
    return keccak256(left + right) if left < right else keccak256(right + left)


def _build_tree(sorted_leaves: list[bytes]) -> list[list[bytes]]:
    tree = [sorted_leaves]
    while len(tree[-1]) > 1:
        layer = tree[-1]
        next_layer = []
        for index in range(0, len(layer), 2):
            next_layer.append(
                layer[index]
                if index + 1 == len(layer)
                else _hash_pair(layer[index], layer[index + 1])
            )
        tree.append(next_layer)
    return tree


def _proof(tree: list[list[bytes]], leaf_index: int) -> list[bytes]:
    proof: list[bytes] = []
    node_index = leaf_index
    for layer in tree[:-1]:
        sibling_index = node_index ^ 1
        if sibling_index < len(layer):
            proof.append(layer[sibling_index])
        node_index //= 2
    return proof


def generate_artifact() -> dict[str, object]:
    chain_id = 421_614
    manager = "0x1111111111111111111111111111111111111111"
    vault = "0x2222222222222222222222222222222222222222"
    executor = "0x3333333333333333333333333333333333333333"
    typehash = hash_type(TYPE_STRING)

    definitions: list[dict[str, object]] = []
    for index in range(5):
        label = f"reference-action-{index}"
        decoder = _address_number(0x100 + index)
        target = _address_number(0x200 + index)
        sanitized_arguments = address(_address_number(0x300 + index))
        selector = keccak256(f"referenceAction{index}(address)".encode())[:4]
        decoder_code_hash = keccak256(f"reference-decoder-code-{index}".encode())
        target_code_hash = keccak256(f"reference-target-code-{index}".encode())
        sanitized_arguments_hash = keccak256(sanitized_arguments)
        leaf_hash = fixed_hash(
            typehash,
            word(chain_id),
            address(manager),
            address(vault),
            address(decoder),
            decoder_code_hash,
            address(target),
            target_code_hash,
            _abi_bytes4(selector),
            word(0),
            sanitized_arguments_hash,
        )
        definitions.append(
            {
                "label": label,
                "decoder": decoder,
                "decoderCodeHash": decoder_code_hash,
                "target": target,
                "targetCodeHash": target_code_hash,
                "selector": selector,
                "maxNativeValue": 0,
                "sanitizedArguments": sanitized_arguments,
                "sanitizedArgumentsHash": sanitized_arguments_hash,
                "leafHash": leaf_hash,
            }
        )

    definitions.sort(key=lambda item: bytes32(item["leafHash"]))
    leaf_hashes = [bytes32(item["leafHash"]) for item in definitions]
    tree = _build_tree(leaf_hashes)
    proofs = [_proof(tree, index) for index in range(len(leaf_hashes))]

    proof_offsets = [0]
    proof_nodes: list[bytes] = []
    for proof in proofs:
        proof_nodes.extend(proof)
        proof_offsets.append(len(proof_nodes))

    tree_offsets = [0]
    tree_nodes: list[bytes] = []
    for layer in tree:
        tree_nodes.extend(layer)
        tree_offsets.append(len(tree_nodes))

    return {
        "schemaVersion": 1,
        "referenceOnly": True,
        "chainId": chain_id,
        "vaultExecutionManager": manager,
        "fundVault": vault,
        "executor": executor,
        "policyVersion": 7,
        "manageLeafV1Typehash": hex32(typehash),
        "leafCount": len(definitions),
        "root": hex32(tree[-1][0]),
        "labels": [item["label"] for item in definitions],
        "decoders": [item["decoder"] for item in definitions],
        "decoderCodeHashes": [hex32(bytes32(item["decoderCodeHash"])) for item in definitions],
        "targets": [item["target"] for item in definitions],
        "targetCodeHashes": [hex32(bytes32(item["targetCodeHash"])) for item in definitions],
        "selectors": [_hex(item["selector"]) for item in definitions],
        "maxNativeValues": [item["maxNativeValue"] for item in definitions],
        "sanitizedArguments": [_hex(item["sanitizedArguments"]) for item in definitions],
        "sanitizedArgumentsHashes": [
            hex32(bytes32(item["sanitizedArgumentsHash"])) for item in definitions
        ],
        "leafHashes": [hex32(value) for value in leaf_hashes],
        "proofOffsets": proof_offsets,
        "proofNodes": [hex32(value) for value in proof_nodes],
        "treeLayerOffsets": tree_offsets,
        "treeNodes": [hex32(value) for value in tree_nodes],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", type=Path)
    parser.add_argument("--write", type=Path)
    args = parser.parse_args()
    artifact = generate_artifact()

    if args.check:
        actual = json.loads(args.check.read_text())
        if actual != artifact:
            print(f"manage-root artifact mismatch: {args.check}", file=sys.stderr)
            return 1

    if args.write:
        args.write.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")

    if not args.check and not args.write:
        print(json.dumps(artifact, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
