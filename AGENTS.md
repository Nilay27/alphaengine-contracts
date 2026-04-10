# AGENTS.md — Development Guidelines (`alphaengine-contracts`)

This repository is a high-assurance Solidity contract module for AlphaEngine’s on-chain intent entrypoints. It is upgradeable-contract infrastructure and must be treated as safety-sensitive code.

The goal is: deterministic, auditable, loud-failing, upgrade-safe contract evolution that AlphaEngine operator services can integrate without ABI, event, or storage-layout drift.

This file supplements the root `/Users/nilay/alphaEngine/AGENTS.md`. When rules overlap, follow the stricter rule.

---

## 1. Engineering goals

1. Upgrade-safe contract evolution.
- Storage layout discipline is mandatory.
- Any implementation change must preserve proxy compatibility unless an explicit breaking migration is approved and documented.

2. Typed failure semantics.
- Use custom errors only for repo-owned revert paths.
- No revert strings in production contract code except those inherited from trusted dependencies.

3. Deterministic listener-facing semantics.
- State, emitted events, and getter surfaces must remain deterministic and order-stable for the same transaction inputs.
- Listener-critical event fields are part of the compatibility contract.

4. Clean ownership boundaries.
- This repo owns Solidity contracts, deployment scripts, Solidity tests, and contract-facing docs.
- It does not own listener bootstrap logic, off-chain simulation logic, ranking logic, or SDK packing semantics.

5. Security-review readiness.
- V1 is intentionally light, but the repo must be structured so fuzzing, invariants, coverage gates, and future security-review workflows can be added without redesign.
- TODO: install and adopt `https://github.com/pashov/skills` when contract scope expands beyond the current single-family controller.

6. Custody-safe modularity.
- Intent lifecycle contracts must not silently become custody contracts.
- Any confidential token custody, wrapper lifecycle, reserve accounting, lock, unlock, burn, or settlement-credit behavior must live behind a dedicated vault boundary.

---

## 2. Non-negotiable runtime and contract rules

1. Upgradeable contract discipline.
- Use initializer-based setup only.
- Constructors on implementation contracts are prohibited except `_disableInitializers()`.
- Append-only storage evolution is mandatory.
- Storage gaps must be maintained deliberately.

2. Event/state parity.
- Every state-changing external function must have explicit event assertions in tests.
- Listener-critical events must reflect stored state exactly for the same transaction.

3. Hard fail on invalid intent inputs.
- Zero market, zero timeframe key, past deadline, invalid component count, zero operator, unauthorized cancellation, and invalid initialization must revert loudly.

4. No commented-out production logic.
- Dead AVS or middleware code must not be left commented in production contracts or scripts.
- Future AVS/EigenLayer work must be additive and documented, not scaffolded as dormant code.

5. Access-grant semantics are authoritative.
- Fhenix/CoFHE handle internalization and permission grants are part of the correctness contract.
- Changes to permission behavior require synchronized tests and docs updates.

6. No hidden lifecycle expansion.
- The currently implemented production controller supports only TA / strategy-allocation submit + cancel.
- Confidential swap and vault work is a separate next phase and must follow `docs/engineering/confidential-swap-vault-architecture.md`.
- Do not sneak in execution, result posting, batching, or operator settlement paths under convenience rationale.

7. Vault and token custody discipline.
- `AlphaEngineIntentController` must never hold FHERC20 balances or underlying ERC20 reserves.
- Swap-intent input must be locked in an AlphaEngine vault, not in the intent controller.
- Atomic FHERC20 authorization-based locking must store the actual returned transferred handle as canonical.
- Do not trust a requested encrypted amount as the amount actually locked.
- Official Fhenix FHERC20 contracts are the target token surface; do not reintroduce the hookathon `HybridFHERC20` as production code.
- For the pinned `fhenix-confidential-contracts@v0.3.1` package, the installed `confidentialTransferFrom(...)` / `setOperator(...)` surface is authoritative over untagged or docs-only permit terminology.

---

## 3. Solidity and Foundry standards

1. Solidity baseline.
- Single compiler version for the repo.
- Keep warnings clean.
- Favor explicit visibility and explicit data locations.

2. Type and storage usage.
- Keep storage packing deliberate, but do not sacrifice auditability for micro-optimization.
- Use named structs/enums for listener-facing state.
- Avoid inline assembly unless there is a documented and tested necessity.

3. Dependency discipline.
- Pin exact dependency refs.
- Do not duplicate OpenZeppelin or Fhenix interfaces locally when canonical package imports exist.
- If a temporary local compatibility shim is required, document owner and removal trigger in `docs/development-log.md`.
- External protocol dependencies such as Uniswap, Pendle, Morpho, or Aave must not be imported into `AlphaEngineIntentController` or `AlphaEngineConfidentialVault`.
- `@uniswap/v4-core` may be pinned for Foundry pool fixtures and a future separately approved executor, but it is not an intent-controller dependency.
- Do not add `@uniswap/v4-periphery` unless a concrete test-fixture blocker is documented; periphery is not a production dependency in this phase.

4. Foundry is canonical.
- All production development, tests, scripts, fuzzing, invariants, and coverage checks use Foundry.
- Hardhat is not part of this repo or CI in v1.

---

## 4. Architecture constraints

1. Production scope.
- Production code is limited to `AlphaEngineIntentController` and the approved `AlphaEngineConfidentialVault` / FHERC20 wrapper phase.
- Additional deposit, withdraw, lock, unlock, consume, settlement, batching, or executor paths require explicit docs and tests in the same change set.
- Transparent proxy pattern with `ProxyAdmin` is the only approved upgrade path for upgradeable production contracts in v1 and the confidential vault phase.

2. Intent-family boundary.
- Current implemented family is TA / strategy-allocation only.
- Future swap-intent work must remain family-specific and additive.
- Listener-facing event and getter surfaces must not assume hookathon ABI or future UEI/execution families.

3. Confidential swap boundary.
- Swap intent submission belongs in `AlphaEngineIntentController`.
- FHERC20 wrapper creation, deposit/shield, withdraw/unshield, lock, unlock, burn/consume, and output credit belong in `AlphaEngineConfidentialVault`.
- Wrappers are scoped per underlying ERC20 unless a documented and approved architecture change says otherwise.
- Batching is out of scope for the first swap-intent implementation.
- The intent controller and vault must remain protocol-agnostic. Do not import PoolManager, Pendle, Morpho, Aave, or route-specific protocol ABIs into either contract.
- Generic UEI execution and protocol-specific executors are separate future boundaries; add them only with explicit architecture docs, tests, and size review.

4. Fhenix boundary.
- Use current CoFHE/FHE Solidity patterns only.
- Do not rely on deprecated `cofhejs` assumptions.
- Use official Fhenix FHERC20/confidential token contracts for confidential token behavior once this phase is implemented.
- If exact FHERC20 Solidity interface names differ from docs, the installed pinned package is authoritative and docs/tests must be updated in the same change set.
- If Foundry-local Fhenix mocks are incomplete, isolate that as documented integration debt instead of downgrading the repo to Hardhat.

5. No AVS/middleware scope in v1.
- This repo is EigenCompute-operated only for now.
- No EigenLayer registration contracts, middleware plumbing, or operator registry logic in v1.

---

## 5. Testing requirements

1. Coverage gate.
- `forge coverage` is required.
- Target is 100% coverage for repo-owned logic-bearing contracts and libraries.
- Exclusions: interfaces, mocks, scripts, vendored dependencies, proxy boilerplate.

2. Required suites.
- Unit tests for every success and revert branch.
- Fuzz tests from day one for nonce, uniqueness, bounds, and authorization properties.
- Invariant scaffolding from day one, even if initial invariant set is small.

3. Listener-critical assertions.
- Submit/cancel/admin events must be asserted.
- Payload-hash determinism and nonce monotonicity must be asserted.
- State/getter/event parity must be asserted.

4. Fhenix-specific assertions.
- If current mocks work in Foundry, test encrypted input internalization and access grants directly.
- If not, document the missing parity explicitly and keep all contract-owned logic fully covered in Foundry anyway.

5. Confidential swap/vault assertions.
- Vault work must add unit, fuzz, and invariant coverage before any real asset-custody path is considered complete.
- Tests must assert lock/cancel/consume state transitions and vault accounting parity.
- Tests must assert the canonical lock handle comes from the FHERC20 transfer result, not the requested encrypted amount.

---

## 6. Git and change hygiene

1. Commit policy.
- Use Conventional Commit style.
- Keep commits focused and reviewable.

2. Change visibility.
- Update `docs/development-log.md` whenever behavior, storage, ABI, event semantics, or dependency boundaries change.
- Keep architecture/testing docs aligned with implementation.

3. Contract compatibility discipline.
- Any external ABI, event, storage, or permission-semantics change requires synchronized tests and docs updates.
- Any listener-facing event change must be treated as a compatibility event for `listener-service`.

4. No hidden drift.
- If scope decisions change, update docs in the same change set.

---

## 7. Cross-module boundary lessons

1. Producer-owned canonical semantics.
- This repo is authoritative for contract ABI, event shape, and storage semantics.
- Consumer repos must map to this contract explicitly, not infer hidden behavior.

2. Compatibility shims are temporary debt.
- Any temporary import shim, Fhenix compatibility layer, or test harness workaround must record:
  - owner,
  - removal trigger,
  - expected removal phase/date if known.

3. Linked dependency freshness is a verification gate.
- Rebuild or refresh pinned dependencies before trusting local integration results.
- Treat stale or mixed package refs as compatibility failure, not as flaky tooling.

---

## 8. Critical references

- `/Users/nilay/alphaEngine/AGENTS.md`
- `/Users/nilay/alphaEngine/knowledgebase/alphaengine-canonical-sequence-and-ownership.md`
- `/Users/nilay/alphaEngine/alphaengine-contracts/docs/engineering/architecture.md`
- `/Users/nilay/alphaEngine/alphaengine-contracts/docs/engineering/testing-strategy.md`
- `/Users/nilay/alphaEngine/alphaengine-contracts/docs/development-log.md`

---

## 9. Formula/spec precedence and deviation protocol

1. Root formula/spec precedence from `/Users/nilay/alphaEngine/AGENTS.md` applies unchanged here.

2. For this repo specifically, explicit contract and event specs in:
- `docs/**`
- `src/**`
- root knowledgebase ownership docs

are implementation-authoritative over chat memory or inferred convenience behavior.

3. If ABI/event/storage semantics or permission rules are ambiguous or conflicting:
- stop implementation,
- cite the conflicting file paths,
- request owner decision before coding.

4. Silent approximations are prohibited.
- Do not weaken initializer validation, lifecycle rules, permission grants, or storage semantics without explicit approval and durable documentation.
