# AGENTS.md — `alphaengine-contracts` instruction router

This repository contains safety-sensitive, upgradeable Solidity infrastructure.
This file routes contract work to focused policies; it supplements
`/Users/nilay/alphaEngine/AGENTS.md`.

## Loading contract

1. Read the root router and every root policy matching the task.
2. Before substantive design, Solidity edits, deployment changes, or audit
   claims, read every matching local policy below completely. Routes accumulate.
3. Contract code, ABI, events, storage, permissions, and installed dependency
   behavior outrank chat recollection.
4. Apply the strictest compatible instruction. Stop and cite conflicts in ABI,
   storage, permission, lifecycle, formula, or custody semantics.

## Always-on contract invariants

- Use custom errors for repository-owned reverts; production revert strings are
  allowed only when inherited from trusted dependencies.
- Implementation contracts use initializers. Constructors are prohibited except
  `_disableInitializers()`.
- Upgradeable storage is append-only and storage gaps are deliberate.
- Listener-facing state, getters, and events remain deterministic and maintain
  exact state/event parity.
- Intent lifecycle contracts never silently become custody contracts.
- Controllers never hold FHERC20 balances or underlying ERC20 reserves.
- FHE handle internalization and permission grants are correctness properties.
- Foundry is canonical. Hardhat is not part of production validation.
- Do not add arbitrary execution, batching, leverage, LP accounting, settlement,
  or other lifecycle behavior under a refactor rationale.
- Preserve existing behavior unless an explicit approved architecture decision
  changes it.

## Route by contract task

| Task signal | Mandatory local files |
|---|---|
| Any Solidity implementation or storage change | `docs/agent-policies/solidity-and-upgradeability.md`; `docs/agent-policies/compatibility-and-dependencies.md`; `docs/agent-policies/testing-audit-and-release.md` |
| Controller, strategy manager, intent lifecycle, naming, module split, or architecture plan | `docs/agent-policies/architecture-and-scope.md`; `docs/agent-policies/compatibility-and-dependencies.md` |
| FHE, CoFHE, FHERC20, wrapper, confidential token, swap escrow, or custody | `docs/agent-policies/fhenix-and-custody.md`; `docs/agent-policies/testing-audit-and-release.md` |
| ABI, event, getter, error, storage layout, listener, manifest, or consumer change | `docs/agent-policies/compatibility-and-dependencies.md`; `docs/agent-policies/testing-audit-and-release.md` |
| FundVault, pooled capital, trader execution, Veda, BoringVault, Merkle proof, decoder, or sanitizer | `docs/agent-policies/fund-vault-and-execution.md`; `docs/agent-policies/architecture-and-scope.md`; `docs/agent-policies/testing-audit-and-release.md` |
| Deployment, proxy, audit, audit freeze, release, or production-readiness claim | `docs/agent-policies/solidity-and-upgradeability.md`; `docs/agent-policies/testing-audit-and-release.md`; `docs/audits/fhenix-private-audit-readiness.md` when Fhenix scope is involved |
| Formula, accounting, allocation, limits, or risk logic | `/Users/nilay/alphaEngine/agent-rules/formulas-and-reproducibility.md` |

## Canonical scope anchors

- `docs/engineering/architecture.md`: current implemented architecture.
- `docs/engineering/strategy-swap-separation-plan.md`: approved separation and
  future pooled-fund boundary.
- `docs/engineering/testing-strategy.md`: repository validation strategy.
- `docs/audits/fhenix-private-audit-readiness.md`: Fhenix audit workflow.
- `docs/development-log.md`: durable behavior and boundary decisions.
- `/Users/nilay/alphaEngine/knowledgebase/alphaengine-canonical-sequence-and-ownership.md`:
  cross-module ownership.

Read the relevant anchor fully when its subject matches the task. Plans describe
scope; they do not authorize unrelated implementation.

## Immediate stop conditions

Stop before coding if the requested work would reorder/delete legacy proxy
storage, mix swap escrow with pooled-fund custody, place protocol-specific logic
inside a controller or custody vault, weaken FHE permissions, change a frozen
audit commit, or require an undocumented breaking ABI/event change.
