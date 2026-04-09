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
- V1 supports only TA / strategy-allocation submit + cancel.
- Do not sneak in execution, result posting, batching, or operator settlement paths under convenience rationale.

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

4. Foundry is canonical.
- All production development, tests, scripts, fuzzing, invariants, and coverage checks use Foundry.
- Hardhat is not part of this repo or CI in v1.

---

## 4. Architecture constraints

1. Production scope.
- One production contract only in v1: `AlphaEngineIntentController`.
- Transparent proxy pattern with `ProxyAdmin` is the only approved upgrade path in v1.

2. Intent-family boundary.
- V1 family is TA / strategy-allocation only.
- Listener-facing event and getter surfaces must not assume hookathon ABI or future UEI/execution families.

3. Fhenix boundary.
- Use current CoFHE/FHE Solidity patterns only.
- Do not rely on deprecated `cofhejs` assumptions.
- If Foundry-local Fhenix mocks are incomplete, isolate that as documented integration debt instead of downgrading the repo to Hardhat.

4. No AVS/middleware scope in v1.
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
