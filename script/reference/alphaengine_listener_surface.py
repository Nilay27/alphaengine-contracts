#!/usr/bin/env python3
"""Generate the canonical AlphaEngine v2 listener selector/topic surface."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from alphaengine_hash_vectors import keccak256


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
OUTPUT = REPOSITORY_ROOT / "ABI/v2/listener-surface.json"
CONTRACTS = {
    "AlphaEngineTraderQualificationRegistry": "ABI/v2/AlphaEngineTraderQualificationRegistry.json",
    "AlphaEngineCompetitionStrategyManager": "ABI/v2/AlphaEngineCompetitionStrategyManager.json",
    "AlphaEngineCapitalStrategyManager": "ABI/v2/AlphaEngineCapitalStrategyManager.json",
    "AlphaEngineConfidentialAssetRegistry": "ABI/v2/AlphaEngineConfidentialAssetRegistry.json",
    "AlphaEngineConfidentialAssetGateway": "ABI/v2/AlphaEngineConfidentialAssetGateway.json",
    "AlphaEngineConfidentialSwapEscrow": "ABI/v2/AlphaEngineConfidentialSwapEscrow.json",
    "AlphaEngineConfidentialSwapController": "ABI/v2/AlphaEngineConfidentialSwapController.json",
    "AlphaEngineFHERC20ERC20Wrapper": "ABI/fherc20/AlphaEngineFHERC20ERC20Wrapper.json",
    "AlphaEngineV4SwapExecutor": "ABI/executors/AlphaEngineV4SwapExecutor.json",
}


def canonical_type(parameter: dict) -> str:
    parameter_type = parameter["type"]
    if not parameter_type.startswith("tuple"):
        return parameter_type
    suffix = parameter_type[len("tuple") :]
    components = ",".join(canonical_type(component) for component in parameter["components"])
    return f"({components}){suffix}"


def signature(item: dict) -> str:
    inputs = ",".join(canonical_type(parameter) for parameter in item.get("inputs", []))
    return f'{item["name"]}({inputs})'


def selector(item_signature: str, length: int) -> str:
    return "0x" + keccak256(item_signature.encode()).hex()[: length * 2]


def build_surface() -> dict:
    contracts = {}
    for contract_name, relative_path in CONTRACTS.items():
        document = json.loads((REPOSITORY_ROOT / relative_path).read_text())
        abi = document["abi"]
        surface = {"functions": [], "errors": [], "events": []}
        for item in abi:
            item_type = item.get("type")
            if item_type not in ("function", "error", "event"):
                continue
            item_signature = signature(item)
            if item_type == "event":
                surface["events"].append(
                    {"signature": item_signature, "topic0": selector(item_signature, 32)}
                )
            else:
                surface[f"{item_type}s"].append(
                    {"signature": item_signature, "selector": selector(item_signature, 4)}
                )
        for entries in surface.values():
            entries.sort(key=lambda entry: entry["signature"])
        contracts[contract_name] = surface
    return {
        "schemaVersion": 1,
        "description": "Canonical AlphaEngine v2 listener selectors, errors, and event topics.",
        "contracts": contracts,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    rendered = json.dumps(build_surface(), indent=2, sort_keys=True) + "\n"
    if arguments.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != rendered:
            raise SystemExit(f"listener surface is stale: run {Path(__file__).relative_to(REPOSITORY_ROOT)}")
    else:
        OUTPUT.write_text(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
