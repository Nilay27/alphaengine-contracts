# Stage 10 first-pass integration validation

Date: 2026-08-27

Scope: Stages P0–9 of the StrategyManager and confidential-swap first pass. The USDC FundVault, USDC vault manager, Merkle execution manager, and Pendle policy remain outside this checkpoint.

This is a local implementation-validation checkpoint, not an external-audit freeze and not a public-network deployment.

## Results

| Gate | Result |
|---|---|
| Complete Foundry suite | 173 passed, 0 failed, 0 skipped |
| Release fuzz profile | 6 fuzz properties passed at 10,000 runs each |
| Release invariant profile | 5 stateful suites / 29 invariant properties passed at 256 runs × depth 128; expected-success handlers do not swallow reverts |
| PoolManager integration | 6 passed, including both directions, 6/18 decimals, returned dust, large price impact, and minimum-output rollback |
| Deployment rehearsal | 8 passed against Foundry's local ephemeral EVM; no RPC broadcast |
| Coverage | 90.59% lines, 91.35% statements, 68.98% branches, 99.39% functions |
| ABI/layout/listener parity | Passed for all active v2 artifacts |
| Runtime-size gate | Passed for every production contract; maximum 17,276 bytes |
| Formatting and diff hygiene | Passed |
| Historical manifest integrity | Passed against the pinned SHA-256 |

## Commands

```bash
forge test --offline
forge test --offline --match-test 'testFuzz*' --fuzz-runs 10000
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --offline --match-path 'test/invariant/*.sol' -q
forge coverage --offline --ir-minimum --report summary --skip DeployAlphaEngineV2
forge build --offline --sizes
bash script/ci/check-generated-artifacts.sh
bash script/ci/check-repository-hygiene.sh
forge fmt --check
git diff --check
```

`DeployAlphaEngineV2` and its dedicated deployment test are skipped only from coverage instrumentation. They compile under the normal production profile and have a separate eight-test suite. Instrumenting the large script under `--ir-minimum` triggers a solc Yul stack-depth failure before any test executes; all production `src/**` contracts remain instrumented.

## Environment notes

- CI is pinned to Foundry `v1.7.1` and remains the canonical stable-toolchain gate.
- This local run used the installed nightly Foundry binary and emitted a non-fatal warning because the sandbox cannot write the user-level signature cache.
- No Fhenix production-network permission/decryption test was run. Local tests use the documented CoFHE compatibility harness; production Fhenix validation remains a release requirement.
- No X-Ray, Solidity Auditor, Fizz, or independent external audit was run at this checkpoint. Per the owner-approved cadence, the consolidated security passes remain after first- and second-pass implementation.

## Residual implementation scope

- USDC-denominated public FundVault and share ledger.
- Deposit/withdrawal and daily NAV manager with positive-P&L vesting and immediate loss recognition.
- Merkle-verified vault execution manager, root generator, fail-closed decoders/sanitizers, risk caps, and Pendle PT integration.
- Production role/Safe addresses, pinned chain/protocol addresses, risk limits, and deployment approval.
