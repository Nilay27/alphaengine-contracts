# Strategy and Confidential-Swap Separation Plan

> **Superseded architecture:** The single
> `AlphaEngineStrategyIntentController` recommendation in this historical plan
> is superseded by
> `docs/engineering/strategy-manager-fund-vault-implementation-plan.md`,
> which defines separate competition and capital StrategyManagers, bound
> confidential swaps, and the second-pass treasury FundVault boundary.
> Its [16 October canonical-token decision](strategy-manager-fund-vault-implementation-plan.md#canonical-confidential-token-decision-2026-10-16)
> also supersedes this historical plan's AlphaEngine wrapper-creation direction:
> future swaps use Fhenix's canonical confidential assets and supported liquidity.

- Decision date: 2026-08-26
- Status: approved architecture plan; implementation not started
- Timebox: one focused engineering day for behavior-preserving separation
- Audit relationship: complete before freezing the Fhenix private-audit commit

## Decision

AlphaEngine strategy/fund-management flows and individual-user confidential swaps are different products with different custody and accounting models. They must not share controller storage, nonce state, pause state, permissions, or lifecycle invariants.

The existing code already has strong unit, fuzz, invariant, integration, and CoFHE compatibility harnesses. Reuse those harnesses to move existing behavior into explicit modules; do not redesign behavior during the split.

## Current implementation

`AlphaEngineIntentController` currently owns:

- strategy intent submission and cancellation;
- encrypted evaluation-score submission;
- confidential swap submission, execution, and refund;
- shared submitter nonces across both intent families;
- strategy and swap administration.

`AlphaEngineConfidentialVault` currently owns:

- wrapper registration and creation;
- user deposit/shield and unshield delegation;
- individual swap locking and immediate unshield request;
- swap settlement, output shielding, and refund;
- transient swap accounting and custody.

This contract is functionally a confidential-asset gateway plus swap escrow. It is not an LP fund vault.

## Target boundaries

### Strategy intent subsystem

Target controller: `AlphaEngineStrategyIntentController`.

Owns only:

- strategy intent submission;
- strategy cancellation;
- encrypted strategy component and market handles;
- official encrypted evaluation-score records;
- strategy listener/operator permissions;
- strategy-specific nonce, pause, event, getter, and storage semantics.

It never holds user tokens or LP assets.

### Individual confidential-swap subsystem

Target module directory: `src/swap/`.

`AlphaEngineConfidentialSwapController` owns:

- swap intent submission;
- swap execution and terminal refund lifecycle;
- swap-specific nonce, pause, listener/operator, event, getter, and storage semantics;
- configured swap escrow and executor references.

`AlphaEngineConfidentialSwapEscrow` owns:

- wrapper registration required by the swap flow;
- user shield/unshield gateway behavior used by confidential swaps;
- temporary per-intent locking;
- unshield claim, settlement, output shielding, and refund custody;
- swap-specific reserve and lifecycle accounting.

`AlphaEngineV4SwapExecutor` remains the Uniswap v4-specific execution adapter and must retain zero residual balances after execution.

### Future pooled fund subsystem

Reserved name: `AlphaEngineFundVault`.

It will eventually own:

- pooled LP deposits and withdrawals;
- share issuance and redemption;
- NAV and asset-accounting rules;
- strategy allocations and risk limits;
- fee and liquidity-management semantics;
- long-lived fund custody.

It is not part of this refactor. It must not reuse swap escrow locks, swap nonces, user swap lifecycle state, or transient settlement accounting. It may later reuse narrowly defined executor interfaces after a separate architecture and security review.

#### Second-pass Veda-style execution reference

The pooled-fund implementation pass should use the local YieldFi Veda POC at
`/Users/nilay/yieldfi/veda-poc` as a design reference, not as a first-pass
dependency or production-ready implementation. Relevant reference files are:

- `src/StrategyWithMerkleVerification.sol` for per-strategist manage roots,
  decoder/sanitizer dispatch, per-call Merkle verification, pause controls, and
  the verified handoff to `BoringVault.manage(...)`;
- `src/BoringVault.sol` for the custody and authorized `manage(...)` boundary;
- `src/DecodersAndSanitizers/**` for extracting security-sensitive address
  arguments from protocol calldata;
- `resources/BaseMerkleRootGenerator.sol` for canonical leaf construction,
  tree generation, and serialized policy artifacts;
- `test/StrategyWithMerkleVerification.t.sol` for permitted-call and
  disallowed-address proof cases.

The observed repository HEAD when this reference was recorded was
`f8faeb7f595afa1307bd7728dc1dcb7c36dbc7ea`. Its working tree also contained
uncommitted changes, so the second pass must select and pin an exact reviewed
source revision before copying, importing, or adapting any code.

AlphaEngine's implementation must additionally bind each Merkle-authorized call
batch to one approved, unexpired, and unconsumed capital-strategy execution
commitment. The Merkle policy constrains the permitted on-chain action surface;
it does not replace AlphaEngine's per-intent evaluation, sizing, risk, expiry,
or replay controls.

## Compatibility and deployment decision

The current deployment is testnet-only. The separated architecture should use new proxies and new deployment addresses.

Do not attempt to transform the combined controller into two controllers through an in-place upgrade that deletes, moves, or reinterprets existing storage. Preserve the legacy deployment and manifest as historical evidence.

Consumer impact must be explicit:

- listener-service subscribes to two controller addresses and family-specific events;
- ABI artifacts are regenerated for both controllers and the swap escrow;
- deployment manifests identify strategy and swap components separately;
- strategy and swap nonce domains become independent;
- any consumer assumption about a shared nonce is removed through an explicit compatibility change.

## One-day execution plan

### Gate 0 — freeze behavior and baseline

- Record the starting commit and current deployment manifest.
- Run the complete test suite and preserve baseline counts.
- Capture current ABIs and storage layouts.
- Confirm that no new feature or LP-vault implementation is included.

### Block 1 — split controllers

- Move strategy state, errors, events, getters, and functions into `AlphaEngineStrategyIntentController`.
- Move swap state, errors, events, getters, and functions into `AlphaEngineConfidentialSwapController`.
- Give each controller independent initializer, owner, pause state, listener/operator, nonce mapping, and storage gap.
- Avoid a shared upgradeable base contract; use small stateless libraries only where duplication would otherwise create inconsistent hashing or validation.

### Block 2 — rename and narrow swap custody

- Move/rename `AlphaEngineConfidentialVault` to `AlphaEngineConfidentialSwapEscrow` without adding behavior.
- Update authority names from generic intent controller to swap controller.
- Preserve canonical returned-handle, unshield, settlement, refund, reserve, and zero-residual semantics.
- Keep `AlphaEngineV4SwapExecutor` separate.

### Block 3 — reuse and partition tests

- Split controller unit and fuzz tests by intent family.
- Split shared-nonce invariants into family-specific exactness invariants.
- Preserve all strategy record, payload-hash, event/state, and authorization assertions.
- Preserve all swap controller/escrow parity, lock lifecycle, reserve conservation, cross-wrapper, dust atomicity, and executor residual assertions.
- Remove only cross-family invariants that are obsolete because the families no longer share storage; replace them with independence assertions at the deployment/integration boundary.

### Block 4 — deployment and consumer artifacts

- Add fresh deployment wiring for both controllers and the swap escrow.
- Add safe upgrade scripts for each upgradeable target or explicitly mark upgrades out of the first deployment scope.
- Enforce chain-id checks in deploy and upgrade scripts.
- Generate separate ABI files and a new deployment manifest without overwriting the legacy manifest.
- Document listener-service changes without editing consumer repositories in this task.

### Block 5 — audit freeze

- Run the complete validation gate.
- Complete the Fhenix audit-readiness document.
- Record one immutable commit SHA as audit-ready.
- Share that SHA and repository access with the designated reviewer.

## Validation gate

Required before the refactor is considered complete:

```bash
git submodule update --init --recursive
forge fmt --check
forge build --offline
forge test --offline
forge coverage --offline --ir-minimum --report summary
```

Also required:

- unit, fuzz, invariant, and integration suites remain green;
- coverage does not regress for repo-owned logic-bearing contracts;
- ABI changes match the documented family split;
- fresh storage layouts are captured for every new upgradeable contract;
- deployment and upgrade scripts reject the wrong chain;
- no contract intended for production holds residual funds outside its documented custody boundary;
- `git diff --check` passes;
- audit scope, limitations, dependency pins, and exact commit are recorded.

## Stop conditions

Stop the one-day refactor and request a new scope if any of the following becomes necessary:

- implementing LP share, NAV, fee, allocation, or withdrawal accounting;
- changing swap economics, routing, settlement, refund, or FHE permission behavior;
- migrating live mainnet state;
- weakening or deleting a safety invariant to make the split pass;
- adding a generic arbitrary-call executor;
- silently preserving shared nonce or storage coupling for convenience;
- extending the task beyond the behavior-preserving module split and audit package.
