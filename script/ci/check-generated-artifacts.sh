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
python3 script/reference/alphaengine_manage_root.py \
    --check test/vectors/alphaengine-manage-root-v1.json
python3 script/reference/alphaengine_listener_surface.py --check

# The legacy manifest, ABI, and storage layouts are immutable historical evidence. Their
# former implementations are intentionally absent from the active source tree and therefore
# must not be regenerated using current dependencies or compiler settings.
expected_legacy_manifest_sha="e35253ff1c1aaa16e67cf6543942332031ac1691392bb578a07ca6fa2c5aa7e2"
actual_legacy_manifest_sha="$(shasum -a 256 deployments/arbitrum-sepolia-latest.json | awk '{print $1}')"
test "$actual_legacy_manifest_sha" = "$expected_legacy_manifest_sha"
test -f ABI/legacy/AlphaEngineIntentController.checked-in-49d96e8.json
test -f storage-layouts/legacy/AlphaEngineIntentController.49d96e8.json
test -f storage-layouts/legacy/AlphaEngineConfidentialVault.49d96e8.json

check_abi \
    out/AlphaEngineFHERC20ERC20Wrapper.sol/AlphaEngineFHERC20ERC20Wrapper.json \
    ABI/fherc20/AlphaEngineFHERC20ERC20Wrapper.json \
    fherc20-wrapper
check_abi \
    out/AlphaEngineV4SwapExecutor.sol/AlphaEngineV4SwapExecutor.json \
    ABI/executors/AlphaEngineV4SwapExecutor.json \
    v4-swap-executor
check_abi \
    out/AlphaEngineConfidentialAssetRegistry.sol/AlphaEngineConfidentialAssetRegistry.json \
    ABI/v2/AlphaEngineConfidentialAssetRegistry.json \
    confidential-asset-registry
check_abi \
    out/AlphaEngineConfidentialAssetGateway.sol/AlphaEngineConfidentialAssetGateway.json \
    ABI/v2/AlphaEngineConfidentialAssetGateway.json \
    confidential-asset-gateway
check_abi \
    out/AlphaEngineConfidentialSwapEscrow.sol/AlphaEngineConfidentialSwapEscrow.json \
    ABI/v2/AlphaEngineConfidentialSwapEscrow.json \
    confidential-swap-escrow
check_abi \
    out/AlphaEngineConfidentialSwapController.sol/AlphaEngineConfidentialSwapController.json \
    ABI/v2/AlphaEngineConfidentialSwapController.json \
    confidential-swap-controller
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
check_abi \
    out/AlphaEngineFundVault.sol/AlphaEngineFundVault.json \
    ABI/v2/AlphaEngineFundVault.json \
    fund-vault
check_abi \
    out/AlphaEngineUSDCVaultManager.sol/AlphaEngineUSDCVaultManager.json \
    ABI/v2/AlphaEngineUSDCVaultManager.json \
    usdc-vault-manager
check_abi \
    out/AlphaEngineVaultExecutionManager.sol/AlphaEngineVaultExecutionManager.json \
    ABI/v2/AlphaEngineVaultExecutionManager.json \
    vault-execution-manager
check_abi \
    out/AlphaEngineERC20DecoderAndSanitizer.sol/AlphaEngineERC20DecoderAndSanitizer.json \
    ABI/v2/AlphaEngineERC20DecoderAndSanitizer.json \
    erc20-decoder-and-sanitizer
check_abi \
    out/AlphaEngineERC4626DecoderAndSanitizer.sol/AlphaEngineERC4626DecoderAndSanitizer.json \
    ABI/v2/AlphaEngineERC4626DecoderAndSanitizer.json \
    erc4626-decoder-and-sanitizer
check_abi \
    out/AlphaEnginePendleV4PtDecoderAndSanitizer.sol/AlphaEnginePendleV4PtDecoderAndSanitizer.json \
    ABI/v2/AlphaEnginePendleV4PtDecoderAndSanitizer.json \
    pendle-v4-pt-decoder-and-sanitizer

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
check_layout \
    out/AlphaEngineConfidentialSwapEscrow.sol/AlphaEngineConfidentialSwapEscrow.json \
    storage-layouts/v2/AlphaEngineConfidentialSwapEscrow.json \
    confidential-swap-escrow-layout
check_layout \
    out/AlphaEngineConfidentialSwapController.sol/AlphaEngineConfidentialSwapController.json \
    storage-layouts/v2/AlphaEngineConfidentialSwapController.json \
    confidential-swap-controller-layout

check_runtime_size \
    out/AlphaEngineTraderQualificationRegistry.sol/AlphaEngineTraderQualificationRegistry.json \
    trader-qualification-registry
check_runtime_size \
    out/AlphaEngineCompetitionStrategyManager.sol/AlphaEngineCompetitionStrategyManager.json \
    competition-strategy-manager
check_runtime_size \
    out/AlphaEngineCapitalStrategyManager.sol/AlphaEngineCapitalStrategyManager.json \
    capital-strategy-manager
check_runtime_size \
    out/AlphaEngineConfidentialAssetRegistry.sol/AlphaEngineConfidentialAssetRegistry.json \
    confidential-asset-registry
check_runtime_size \
    out/AlphaEngineConfidentialAssetGateway.sol/AlphaEngineConfidentialAssetGateway.json \
    confidential-asset-gateway
check_runtime_size \
    out/AlphaEngineConfidentialSwapEscrow.sol/AlphaEngineConfidentialSwapEscrow.json \
    confidential-swap-escrow
check_runtime_size \
    out/AlphaEngineConfidentialSwapController.sol/AlphaEngineConfidentialSwapController.json \
    confidential-swap-controller
check_runtime_size \
    out/AlphaEngineFHERC20ERC20Wrapper.sol/AlphaEngineFHERC20ERC20Wrapper.json \
    fherc20-wrapper
check_runtime_size \
    out/AlphaEngineV4SwapExecutor.sol/AlphaEngineV4SwapExecutor.json \
    v4-swap-executor
check_runtime_size \
    out/AlphaEngineFundVault.sol/AlphaEngineFundVault.json \
    fund-vault
check_runtime_size \
    out/AlphaEngineUSDCVaultManager.sol/AlphaEngineUSDCVaultManager.json \
    usdc-vault-manager
check_runtime_size \
    out/AlphaEngineVaultExecutionManager.sol/AlphaEngineVaultExecutionManager.json \
    vault-execution-manager
check_runtime_size \
    out/AlphaEngineERC20DecoderAndSanitizer.sol/AlphaEngineERC20DecoderAndSanitizer.json \
    erc20-decoder-and-sanitizer
check_runtime_size \
    out/AlphaEngineERC4626DecoderAndSanitizer.sol/AlphaEngineERC4626DecoderAndSanitizer.json \
    erc4626-decoder-and-sanitizer
check_runtime_size \
    out/AlphaEnginePendleV4PtDecoderAndSanitizer.sol/AlphaEnginePendleV4PtDecoderAndSanitizer.json \
    pendle-v4-pt-decoder-and-sanitizer
