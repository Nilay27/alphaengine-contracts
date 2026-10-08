# Arbitrum Sepolia v2 deployment rehearsal — 8 October 2026

## Scope and actual deployment status

This is a **simulation without broadcast**, using the existing
`DeployAlphaEngineV2` entry point on a read-only Arbitrum Sepolia fork. Candidate
addresses are not deployed network addresses. No explorer verification or
Fhenix whitelisting is claimed. Legacy deployment evidence is preserved.

| Component | Rehearsal scope | Actual new public-network deployment |
|---|---|---|
| Qualification Registry implementation/proxy/ProxyAdmin | Included, initially paused | Not deployed |
| Competition Manager implementation/proxy/ProxyAdmin | Included, initially paused | Not deployed |
| Capital Manager implementation/proxy/ProxyAdmin | Included, paused without approved execution manager | Not deployed |
| Confidential Swap Controller implementation/proxy/ProxyAdmin | Included, initially paused | Not deployed |
| Confidential Swap Escrow implementation/proxy/ProxyAdmin | Included, initially paused | Not deployed |
| Confidential Asset Registry and Gateway | Included | Not deployed |
| V4 Swap Executor | Included, binds configured PoolManager and escrow | Not deployed |
| ERC20ConfidentialLib | Required linked library, automatically simulated by Foundry | Not deployed |
| Per-asset FHERC20 wrappers | Awaiting reviewed underlying-asset selection and minimums | Not deployed |
| FundVault | Omitted | Not deployed |
| USDC Vault Manager | Omitted | Not deployed |
| Vault Execution Manager | Omitted | Not deployed |
| Vault-bound decoders | Omitted | Not deployed |

The Swap Escrow is required for swaps and is distinct from the omitted pooled
FundVault. Capital approval/execution cannot operate without an authorized
execution manager and real FundVault. Do not unpause capital for this beta.

## Verified results — completed 9 October 2026, Asia/Kolkata

- Pinned Foundry **1.7.1** passed changed-file formatting, the complete
  **347-test / 28-suite** run (zero failures/skips), ABI/layout/hash-vector checks,
  runtime-size limits and `git diff --check`.
- All **15 ABI snapshots and five storage layouts** match their golden
  artifacts. Every checked repository-owned runtime is within 23,000 bytes.
- The final script simulation passed on **Arbitrum Sepolia, chain 421614**, at
  pinned fork block **317143721**. It recorded **14 simulated transactions and
  zero confirmed receipts**. No keystore unlocking, transaction broadcasting,
  explorer verification, role handover or product activation occurred.
- Gas estimate: **37,637,424 gas / 0.006789038578757424 Arbitrum Sepolia ETH**
  at that check. This is an estimate, not a fixed future gas cost.
- Public role addresses, PoolManager/address-book/TaskManager code, actual
  dependency revisions and generated metadata were validated. The final source
  fingerprint was independently recomputed and matched the candidate manifest;
  the legacy manifest SHA-256 remains unchanged.
- The first regression run exposed a fixture CREATE-nonce shift affecting 13
  saved invariant replays. Installing address-book runtime code without CREATE
  restores those handler addresses. All saved cases were retained and passed;
  no failure corpus was removed or invariant weakened.
- Official GitHub checksum verification preceded use of the isolated Foundry
  binaries. The user's installed Foundry remains unchanged. Existing lint and
  stale-cache warnings are retained in logs; this is not a clean-checkout
  release, coverage/security audit, live CoFHE test or mainnet-readiness claim.

Final evidence, retained locally and ignored by Git:

- [Preflight and validation report](../../deployments/v2/rehearsals/2026-10-09-001301/preflight.json)
- [Simulation-only candidate manifest](../../deployments/v2/rehearsals/2026-10-09-001301/arbitrum-sepolia.json)
- [Sanitized simulation output](../../deployments/v2/rehearsals/2026-10-09-001301/forge-simulation.log)

## Configuration and dependency details

- CoFHE is pinned to v1.0.0, commit
  `0f5ded4f2847ee227f9be0b07a392238f75b656c`. FHERC20 remains v0.4.0.
- CoFHE v1 resolves TaskManager ID 1 through the address book at
  `0xC0F4e00E531a2B086492Ae3DCC1515038307196b`. The local mock now installs
  real fixture bytecode at that address, so `vm.clearMockedCalls()` cannot
  erase its resolution. This fixture is never deployed publicly.
- No production ABI/input encoding change accompanies this dependency bump;
  retain `contractApiRevision: v2-cofhe-0.2` as the consumer-API revision. The
  manifest reports the installed library version separately. The schema accepts
  both 0.2.0 historical manifests and new 1.0.0 manifests.
- The user selects `alphaengine-deployer`, address
  `0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d`. All 17 v2 role-address
  settings use it for this test-only configuration. OWNER/LISTENER_OPERATOR are
  legacy aliases; BROADCASTER selects the rehearsal sender, not a private key.
- Require `EXPECTED_CHAIN_ID=421614` and explicit `TEST_ONLY_ROLE_COLLAPSE`.
  The Solidity script rejects collapsed roles outside chain 421614 or local
  chain 31337. Mainnet must use separate keys and governance as already recorded.
- The local environment's manifest path now points under `deployments/v2/rehearsals/`.
  The script checks the path before recording candidate transactions and before
  writing; legacy paths and directory traversal are rejected.
- Deployment status is pending receipt reconciliation. Simulation addresses,
  successful process exit and a candidate manifest never prove deployment or
  explorer verification.

## Reproduce the no-broadcast check

```bash
python3 script/rehearse-deployment.py
```

The helper reads dotenv as data, validates public addresses/chain flags, checks
target-network PoolManager/address-book/TaskManager code, computes actual
dependency/ABI/layout metadata, and invokes `forge script` with the public sender.
Each run pins and records one fork block and checks clean dependency worktrees.
It has no broadcast or wallet-unlocking option and never needs the keystore
password. It uses the public Sepolia RPC explicitly, without exposing saved
credential-bearing RPC URLs. `--forge` and `--cast` can select isolated binaries.
Canonical CI/release Foundry is v1.7.1; the report records the actual local version.

Each run creates a new timestamped directory under
`deployments/v2/rehearsals/`, using Asia/Kolkata time; existing run directories
cannot be overwritten. Generated, ignored evidence within each run:

- `preflight.json`: checked public configuration,
  dependency revisions, source-tree fingerprint and simulation result;
- `arbitrum-sepolia.json`: candidate manifest;
- `forge-simulation.log`: sanitized Foundry output.

Fingerprints use SHA-256. File bundles hash sorted POSIX paths followed by NUL,
file-content SHA-256 and LF. The dependency lock hashes compact sorted JSON of
submodule names/revisions. The source fingerprint excludes dotenv, logs, cached
bytecode and other transient artifacts; it includes source, scripts, tests,
foundry.toml and .gitmodules. The Git SHA plus source-tree fingerprint explicitly
describes an uncommitted rehearsal, not an immutable release candidate.

## Remaining public-deployment gates

- Reviewed underlying token addresses, wrapper minimums and asset configuration.
- Final source/release checks and immutable deployment source identification.
- A valid replacement explorer API key; this rehearsal only checks presence.
- Receipt-backed deployment blocks/transaction hashes and on-chain bytecode,
  proxy slots, paused state, roles and reciprocal links.
- Explorer source verification and any Fhenix admission/whitelisting step.
- Live CoFHE permission/input/decryption tests before product activation.
- Deferred SDK/frontend/listener migration before private beta submissions work.

The rehearsal does not perform those operations or change AWS/DNS configuration.
