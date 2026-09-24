# CoFHE v0.2 migration validation

Date: 2026-09-25. Base reviewed by Fhenix: `0595ef4`.

Scope: dependency/API migration for finding 1. See the
[migration contract](../engineering/cofhe-v020-migration.md) for exact pins,
consumer changes, claim-ID adapter ownership and fresh-wrapper cutover.

## Environment and commands

Foundry v1.7.1 (CI pin), solc 0.8.26, Cancun, via IR, optimizer 200 runs.

```bash
forge fmt --check
forge test --offline
forge coverage --offline --ir-minimum --report summary --skip DeployAlphaEngineV2
forge build --offline --sizes
bash script/ci/check-generated-artifacts.sh
bash script/ci/check-repository-hygiene.sh
git diff --check
```

The pre-migration baseline passed 306 tests.

## Results

| Gate | Result |
|---|---|
| Complete unit, fuzz, invariant and integration suite | 315 passed, 0 failed, 0 skipped across 27 suites |
| Coverage test execution | 306 passed, 0 failed, 0 skipped; nine deployment tests excluded from instrumentation |
| Coverage of repository source | 92.98% lines, 92.64% statements, 72.53% branches, 99.23% functions |
| Production build and runtime sizes | Passed; all checked runtimes below 23,000 bytes |
| ABI, storage layout, listener and hash-vector checks | Passed |
| Dependency pins, submodule hygiene and historical manifest integrity | Passed |
| Formatting and Git whitespace checks | Passed |

## Compatibility checks

- Strategy, qualification and controller storage layouts are unchanged after
  normalizing compiler AST IDs. The escrow's mapped lock struct appends
  `unshieldClaimId` at relative slot 5; previous members, top-level fields,
  mapping slot and gap are unchanged.
- Current ABI and listener snapshots include external encrypted inputs,
  batch proofs and claim IDs in gateway/escrow request events and getters.
  Strategy hash/reference vectors remain unchanged. Historical legacy
  manifest integrity is checked independently.
- Maximum production runtime: 17,918 bytes (`AlphaEngineVaultExecutionManager`),
  below the repository's 23,000-byte limit. The linked
  `ERC20ConfidentialLib` is 10,563 bytes and is now included in that gate.
- Nine deployment tests check fresh paused domains, administration, chain ID,
  required metadata, library linkage/code presence and manifest fields.

## Limits of this evidence

- Local FHE tests exercise production Solidity against a plaintext CoFHE
  harness. Its input signatures bind sender, chain, consumer, input type and
  order; its shares use transient storage and authenticate the sharer.
  It does not prove threshold-network liveness, production ciphertext metadata
  or real decryption-signature validity.
- Coverage uses the existing minimal-IR workaround. The deployment script and
  its nine tests are excluded from coverage instrumentation only, and pass in
  the normal suite. Minimal-IR source maps can be imprecise; coverage is not
  100% and does not establish production readiness.
- The opt-in Pendle RPC fork test retains its default early return; no live
  Pendle fork or Fhenix testnet transaction was run. No broadcast or external
  audit was performed for this commit.
- Fhenix's swap/unshield/reveal decrypt-pressure findings remain open. Backend
  and SDK callers still require the documented ABI/proof migration before
  deployment; this commit changes only the contracts repository.
