#!/usr/bin/env python3
"""Validate local configuration and simulate DeployAlphaEngineV2 on Arbitrum Sepolia; never broadcast."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
RPC = "https://sepolia-rollup.arbitrum.io/rpc"
BOOK = "0xC0F4e00E531a2B086492Ae3DCC1515038307196b"
ROLES = "DEFAULT_ADMIN PROXY_ADMIN_OWNER PAUSER QUALIFICATION_REVOKER COMPETITION_FHE_OPERATOR COMPETITION_CREATOR COMPETITION_CANCELLER COMPETITION_EVALUATOR COMPETITION_FINALIZER COMPETITION_QUALIFIER SCORE_REVEALER CAPITAL_FHE_OPERATOR CAPITAL_EVALUATOR CAPITAL_REVOCER SWAP_OPERATOR ASSET_REGISTRY_OWNER SWAP_EXECUTOR_OWNER".split()


def run(argv, env=None):
    return subprocess.check_output(argv, cwd=ROOT, env=env, text=True).strip()


def bundle(paths):
    # Stable SHA-256: sorted POSIX path + NUL + file SHA-256 + LF; no transient metadata.
    records = [(p.relative_to(ROOT).as_posix(), hashlib.sha256(p.read_bytes()).hexdigest())
               for p in sorted(paths)]
    return "0x" + hashlib.sha256("".join(f"{p}\0{h}\n" for p, h in records).encode()).hexdigest()


def rpc(method, params):
    payload = json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params))
    p = subprocess.run(["curl", "--fail", "--silent", "--show-error", "--max-time", "30",
                        "-H", "Content-Type: application/json", "--data-binary", "@-", RPC],
                       input=payload, capture_output=True, text=True, check=True)
    response = json.loads(p.stdout)
    if "error" in response or "result" not in response:
        raise ValueError("RPC check failed: " + method)
    return response["result"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--forge", default="forge")
    parser.add_argument("--cast", default="cast")
    parser.add_argument("--create2", action="store_true", help="Use the isolated CREATE2 build and deployment script")
    parser.add_argument("--run-id", default=datetime.now(ZoneInfo("Asia/Kolkata")).strftime("%Y-%m-%d-%H%M%S"))
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}", args.run_id):
        raise ValueError("Invalid rehearsal run ID")
    env, seen = os.environ.copy(), set()
    for line in (ROOT / ".env").read_text().splitlines():
        tokens = shlex.split(line, comments=True)
        if not tokens:
            continue
        if tokens[0] == "export":
            tokens = tokens[1:]
        if len(tokens) != 1 or "=" not in tokens[0]:
            raise ValueError("Unsupported dotenv syntax; no shell execution performed")
        name, value = tokens[0].split("=", 1)
        if name in seen:
            raise ValueError("Duplicate dotenv variable: " + name)
        seen.add(name)
        env[name] = value
    if args.create2:
        env["FOUNDRY_PROFILE"] = "create2"
    for name in ROLES + ["OWNER", "LISTENER_OPERATOR", "BROADCASTER", "POOL_MANAGER"]:
        value = env.get(name, "")
        if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value, 16) == 0:
            raise ValueError("Invalid/missing public address: " + name)
    if env.get("EXPECTED_CHAIN_ID") != "421614" or int(rpc("eth_chainId", []), 16) != 421614:
        raise ValueError("Arbitrum Sepolia chain guard mismatch")
    if env.get("TEST_ONLY_ROLE_COLLAPSE") not in ("true", "false"):
        raise ValueError("Explicit TEST_ONLY_ROLE_COLLAPSE required")
    fork_block = int(rpc("eth_blockNumber", []), 16)
    tm = run([args.cast, "call", BOOK, "getTm(uint256)(address)", "1", "--rpc-url", RPC,
              "--block", str(fork_block)], env)
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", tm) or int(tm, 16) == 0:
        raise ValueError("Invalid TaskManager resolution")
    for label, address in [("PoolManager", env["POOL_MANAGER"]), ("address book", BOOK), ("TaskManager", tm)]:
        if rpc("eth_getCode", [address, hex(fork_block)]) == "0x":
            raise ValueError("Missing code: " + label)
    dependencies = {p.name: run(["git", "-C", str(p), "rev-parse", "HEAD"])
                    for p in sorted((ROOT / "lib").iterdir()) if (p / ".git").exists()}
    for name in dependencies:
        if run(["git", "-C", str(ROOT / "lib" / name), "status", "--porcelain"]):
            raise ValueError("Dirty dependency: " + name)
    if dependencies["cofhe-contracts"] != "0f5ded4f2847ee227f9be0b07a392238f75b656c":
        raise ValueError("CoFHE v1.0.0 pin mismatch")
    env["DEPLOYMENT_GIT_SHA"] = run(["git", "rev-parse", "HEAD"])
    env["FOUNDRY_VERSION"] = run([args.forge, "--version"], env).splitlines()[0]
    env["FHENIX_PACKAGE_REVISION"] = dependencies["fhenix-confidential-contracts"]
    env["DEPENDENCY_LOCK_HASH"] = "0x" + hashlib.sha256(json.dumps(dependencies, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    env["ABI_BUNDLE_HASH"] = bundle(list((ROOT / "ABI/v2").glob("*.json")))
    env["STORAGE_LAYOUT_BUNDLE_HASH"] = bundle(list((ROOT / "storage-layouts/v2").glob("*.json")))
    sources = [ROOT / "foundry.toml", ROOT / ".gitmodules"]
    for folder in ["src", "script", "test"]:
        sources.extend(p for p in (ROOT / folder).rglob("*") if p.is_file() and "__pycache__" not in p.parts)
    source_hash = bundle(sources)
    output = ROOT / "deployments/v2/rehearsals" / args.run_id
    output.mkdir(parents=True, exist_ok=False)
    candidate = output / "arbitrum-sepolia.json"
    env["DEPLOYMENT_MANIFEST"] = candidate.relative_to(ROOT).as_posix()
    legacy = ROOT / "deployments/arbitrum-sepolia-latest.json"
    legacy_hash = hashlib.sha256(legacy.read_bytes()).hexdigest()
    if legacy_hash != "e35253ff1c1aaa16e67cf6543942332031ac1691392bb578a07ca6fa2c5aa7e2":
        raise ValueError("Legacy manifest integrity failure")
    report = dict(mode="fork-simulation-no-broadcast", runId=args.run_id,
                  chainId=421614, forkBlockNumber=fork_block,
                  sourceTreeHash=source_hash,
                  roles={name: env[name] for name in ROLES}, sender=env["BROADCASTER"],
                  poolManager=env["POOL_MANAGER"], cofheAddressBook=BOOK, taskManager=tm,
                  dependencies=dependencies, foundryVersion=env["FOUNDRY_VERSION"],
                  legacyManifestSha256=legacy_hash, simulationPassed=False,
                  verificationCredentialPresent=bool(env.get("ETHERSCAN_API_KEY")),
                  verificationCredentialValidity="not-checked")
    report["buildProfile"] = "create2" if args.create2 else "default"
    (output / "preflight.json").write_text(json.dumps(report, indent=2) + "\n")
    entrypoint = "script/DeployAlphaEngineCreate2.s.sol:DeployAlphaEngineCreate2" if args.create2 else "script/DeployAlphaEngineV2.s.sol:DeployAlphaEngineV2"
    argv = [args.forge, "script", entrypoint,
            "--rpc-url", RPC, "--fork-block-number", str(fork_block),
            "--sender", env["BROADCASTER"], "--non-interactive"]
    # This helper deliberately has no broadcast/account/private-key/verification option.
    process = subprocess.run(argv, cwd=ROOT, env=env, text=True, capture_output=True)
    log = process.stdout + process.stderr
    for name, value in env.items():
        if len(value) > 5 and any(word in name for word in ["SECRET", "PASSWORD", "PRIVATE_KEY", "API_KEY"]):
            log = log.replace(value, "[redacted]")
    (output / "forge-simulation.log").write_text(log)
    if hashlib.sha256(legacy.read_bytes()).hexdigest() != legacy_hash:
        raise ValueError("Legacy manifest changed during rehearsal")
    if process.returncode:
        raise SystemExit("Simulation failed; inspect sanitized forge-simulation.log")
    manifest = json.loads(candidate.read_text())
    if manifest["chainId"] != 421614 or manifest["cofheContractsVersion"] != "1.0.0":
        raise ValueError("Candidate manifest does not match preflight")
    if manifest["deploymentTransactionHashesRecorded"] is not False:
        raise ValueError("Simulation cannot claim confirmed transactions")
    manifest.update(executionStatus="simulation-only-not-deployed", sourceTreeHash=source_hash,
                    sourceTreeStatus="uncommitted-rehearsal", explorerVerificationStatus="not-verified")
    candidate.write_text(json.dumps(manifest, indent=2) + "\n")
    report["simulationPassed"] = True
    (output / "preflight.json").write_text(json.dumps(report, indent=2) + "\n")
    if args.create2:
        # Public values only: reuse the exact rehearsed inputs without exporting secrets.
        names = ROLES + ["EXPECTED_CHAIN_ID", "TEST_ONLY_ROLE_COLLAPSE", "POOL_MANAGER", "DEPLOYMENT_GIT_SHA", "FOUNDRY_VERSION", "FHENIX_PACKAGE_REVISION", "DEPENDENCY_LOCK_HASH", "ABI_BUNDLE_HASH", "STORAGE_LAYOUT_BUNDLE_HASH"]
        lines = ["# Public rehearsal inputs. Finalize shared initial roles before mainnet-compatible deployment.", "export FOUNDRY_PROFILE=create2"]
        lines.extend("export " + name + "=" + shlex.quote(env[name]) for name in names)
        lines.append("export DEPLOYMENT_MANIFEST=" + shlex.quote((output / "broadcast-candidate.json").relative_to(ROOT).as_posix()))
        (output / "deployment.env").write_text("\n".join(lines) + "\n")
        print("Public deployment environment: " + str(output / "deployment.env"))
    print("Configuration/preflight and full script simulation passed; zero transactions broadcast.")
    print("Candidate manifest: " + str(candidate))


if __name__ == "__main__":
    main()
