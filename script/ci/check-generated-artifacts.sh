#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

scratch_dir="$(mktemp -d)"
trap 'rm -rf "$scratch_dir"' EXIT

check_abi() {
    local artifact_path="$1"
    local checked_path="$2"
    local label="$3"

    jq -S '{abi: .abi}' "$artifact_path" >"$scratch_dir/$label.generated.json"
    jq -S . "$checked_path" >"$scratch_dir/$label.checked.json"
    diff -u "$scratch_dir/$label.checked.json" "$scratch_dir/$label.generated.json"
}

check_layout() {
    local artifact_path="$1"
    local checked_path="$2"
    local label="$3"

    # Solidity embeds compilation-order-dependent AST ids in otherwise stable storage-layout
    # type identifiers. Normalize only those ids; retain every field, slot, offset, byte width,
    # encoding, and semantic type label in the golden comparison.
    jq -S '.storageLayout | walk(if type == "object" then del(.astId) else . end)' \
        "$artifact_path" \
        | sed -E 's/\)[0-9]+_storage/)_storage/g; s/\)[0-9]+/)/g' \
            >"$scratch_dir/$label.generated.json"
    jq -S 'walk(if type == "object" then del(.astId) else . end)' "$checked_path" \
        | sed -E 's/\)[0-9]+_storage/)_storage/g; s/\)[0-9]+/)/g' \
            >"$scratch_dir/$label.checked.json"
    diff -u "$scratch_dir/$label.checked.json" "$scratch_dir/$label.generated.json"
}

check_runtime_size() {
    local artifact_path="$1"
    local label="$2"
    local maximum_bytes=23000
    local bytecode
    local runtime_bytes

    bytecode="$(jq -r '.deployedBytecode.object' "$artifact_path")"
    runtime_bytes=$(( (${#bytecode} - 2) / 2 ))
    if (( runtime_bytes > maximum_bytes )); then
        printf '%s runtime exceeds %s bytes: %s\n' \
            "$label" "$maximum_bytes" "$runtime_bytes" >&2
        exit 1
    fi
    printf '%s runtime size: %s bytes\n' "$label" "$runtime_bytes"
}

forge build --offline

python3 script/reference/alphaengine_hash_vectors.py \
    --check test/vectors/alphaengine-hash-v1.json

check_abi \
    out/AlphaEngineIntentController.sol/AlphaEngineIntentController.json \
    ABI/AlphaEngineIntentController.json \
    intent-controller
check_abi \
    out/AlphaEngineConfidentialVault.sol/AlphaEngineConfidentialVault.json \
    ABI/vault/AlphaEngineConfidentialVault.json \
    confidential-vault
check_abi \
    out/AlphaEngineFHERC20ERC20Wrapper.sol/AlphaEngineFHERC20ERC20Wrapper.json \
    ABI/fherc20/AlphaEngineFHERC20ERC20Wrapper.json \
    fherc20-wrapper
check_abi \
    out/AlphaEngineV4SwapExecutor.sol/AlphaEngineV4SwapExecutor.json \
    ABI/executors/AlphaEngineV4SwapExecutor.json \
    v4-swap-executor
check_abi \
    out/AlphaEngineTraderQualificationRegistry.sol/AlphaEngineTraderQualificationRegistry.json \
    ABI/v2/AlphaEngineTraderQualificationRegistry.json \
    trader-qualification-registry
check_abi \
    out/AlphaEngineCompetitionStrategyManager.sol/AlphaEngineCompetitionStrategyManager.json \
    ABI/v2/AlphaEngineCompetitionStrategyManager.json \
    competition-strategy-manager
check_abi \
    out/AlphaEngineCapitalStrategyManager.sol/AlphaEngineCapitalStrategyManager.json \
    ABI/v2/AlphaEngineCapitalStrategyManager.json \
    capital-strategy-manager

check_layout \
    out/AlphaEngineIntentController.sol/AlphaEngineIntentController.json \
    storage-layouts/legacy/AlphaEngineIntentController.49d96e8.json \
    intent-controller-layout
check_layout \
    out/AlphaEngineConfidentialVault.sol/AlphaEngineConfidentialVault.json \
    storage-layouts/legacy/AlphaEngineConfidentialVault.49d96e8.json \
    confidential-vault-layout
check_layout \
    out/AlphaEngineTraderQualificationRegistry.sol/AlphaEngineTraderQualificationRegistry.json \
    storage-layouts/v2/AlphaEngineTraderQualificationRegistry.json \
    trader-qualification-registry-layout
check_layout \
    out/AlphaEngineCompetitionStrategyManager.sol/AlphaEngineCompetitionStrategyManager.json \
    storage-layouts/v2/AlphaEngineCompetitionStrategyManager.json \
    competition-strategy-manager-layout
check_layout \
    out/AlphaEngineCapitalStrategyManager.sol/AlphaEngineCapitalStrategyManager.json \
    storage-layouts/v2/AlphaEngineCapitalStrategyManager.json \
    capital-strategy-manager-layout

check_runtime_size \
    out/AlphaEngineTraderQualificationRegistry.sol/AlphaEngineTraderQualificationRegistry.json \
    trader-qualification-registry
check_runtime_size \
    out/AlphaEngineCompetitionStrategyManager.sol/AlphaEngineCompetitionStrategyManager.json \
    competition-strategy-manager
check_runtime_size \
    out/AlphaEngineCapitalStrategyManager.sol/AlphaEngineCapitalStrategyManager.json \
    capital-strategy-manager
