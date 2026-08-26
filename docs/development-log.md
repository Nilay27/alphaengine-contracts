# Development Log

## 2026-08-27 — Stage 7 encrypted-zero and preclaim liveness hardening

### Fixed
- A privacy-preserving FHERC20 overdraw returns an initialized encrypted zero
  rather than reverting. The escrow now lets the controller prove and refund
  that zero result, terminates the live lock, and skips a meaningless
  zero-value re-shield. Zero still cannot enter swap execution.
- Wrapper claims are permissionless and send underlying to their stored fixed
  recipient. Settlement and refund now inspect the exact claim state and safely
  reconcile already-claimed underlying held by escrow instead of attempting a
  second claim that would strand the lock.

### Test hardening
- Added deterministic above-balance, uninitialized-account, preclaimed-settle,
  and preclaimed-refund unit coverage.
- Removed every unchecked catch from the Stage 7 invariant handler.
  Expected-success actions now propagate failures; the deliberate
  under-minimum action validates the exact dependency error and coupled-state
  rollback.
- Added explicit overdraw and permissionless-preclaim invariant actions,
  meaningful-action counters, a non-1:1 output quote, and independent input and
  output ghost ledgers. Wrapper pending reserves now exclude claims already
  paid to escrow, while escrow residual custody must equal live preclaimed
  underlying exactly.

### Security-gate reminder
- Fizz remains a single guided consolidated-repository pass after all contract
  stages and Foundry gates are complete. Its remediations are validated before
  the final full Solidity Auditor run against the frozen candidate; neither
  skill runs during this Stage 7 hardening pass.

### Validation
- Focused Stage 7 unit/fuzz file: 30 tests passed, including the registry,
  gateway, and 17-test escrow suite.
- Deep escrow fuzz: 10,001 cases passed.
- Escrow invariants: all 8 properties passed at 256 runs and depth 128, totaling
  262,144 randomized calls with zero handler reverts.
- Full repository: 287 tests passed, 0 failed, 0 skipped.
- Coverage: 90.95% lines, 91.61% statements, 70.65% branches, and 98.96%
  functions repository-wide. The new escrow currently reports 82.74% lines,
  83.65% statements, 34.21% branches, and 100% functions; remaining branch
  tightening stays in the pre-release coverage pass rather than blocking this
  liveness correction.
- Generated ABI/storage parity and runtime-size gates passed. The hardened
  escrow runtime is 11,727 bytes, below the 23,000-byte ceiling.

## 2026-08-27 — Ordered internal security-skill workflow

### Decision
- Consolidated internal security gates now use the durable order:
  `Foundry validation -> X-Ray -> Fizz -> refreshed X-Ray when material changes
  occur -> Solidity Auditor -> remediation/regression tests -> targeted
  remediation audit -> frozen candidate -> independent external audit`.
- X-Ray is the pre-audit reconnaissance and readiness layer. Fizz consumes its
  protocol/entry-point context to generate an independent Echidna/Medusa
  stateful fuzz suite. Solidity Auditor runs only after those artifacts and
  campaigns are current.
- Fizz is guided on first use so its selected entry points, setup, handlers,
  expected errors, and plain-English properties receive owner/engineering
  review. Generated handlers remain subject to the repository prohibition on
  unchecked catches and happy-path-only bounds.
- Critical Fhenix/FHERC20 dependency implementations must be explicitly added
  to auditor scope when their behavior affects AlphaEngine safety; default
  vendored-library exclusion is not sufficient evidence.

### Scope and timing
- Heavyweight security skills remain consolidated end-of-implementation gates,
  not per-stage gates. The current incomplete Stage 7/8 swap boundary does not
  trigger X-Ray, Fizz, or Solidity Auditor yet.
- Fizz is not installed by this documentation decision. Installation,
  toolchain/provenance verification, and the first guided campaign occur only
  when the approved consolidated gate is reached or the owner explicitly
  advances that gate.

## 2026-08-26 — Contract liveness and invariant-handler policy hardening

### Learned
- Stage 7 review identified that the escrow invariant handler bounded every
  confidential lock request to the known available balance. That excluded the
  privacy-preserving FHERC20 insufficient-balance behavior, which returns an
  initialized encrypted zero rather than an ordinary ERC20-style revert.
- The same handler used unchecked `catch {}` blocks around actions expected to
  succeed. Those catches can convert unexpected production reverts into
  handler no-ops and allow invariant campaigns to pass without exercising the
  intended transition.
- Cross-asset conservation cannot add confidential units from different
  assets. Input consumed and output credited require independent ghost ledgers;
  PoolManager pricing parity belongs in a differential integration suite.

### Decisions
- Added mandatory boundary, liveness, and invariant-handler rules to
  `docs/agent-policies/testing-audit-and-release.md`, which is loaded for every
  Solidity behavior change and Fhenix/custody task through `AGENTS.md`.
- Require deterministic zero/below/equal/above-balance unit tests before fuzz
  and invariant evidence is accepted.
- Prohibit unchecked catches in invariant handlers. Expected-success actions
  propagate reverts; expected-failure actions assert exact selectors and
  rollback; newly observed errors require manual review.
- Require both safety and liveness properties, meaningful action counters, and
  adversarial ordering of public claims, callbacks, pause, expiry, settlement,
  and cleanup.
- Adopt the methodology in [Finding Denial of Service Bugs At Scale With
  Invariant Tests](https://allthingsfuzzy.substack.com/p/finding-denial-of-service-bugs-at)
  as a durable testing reference, while retaining repository-specific Foundry,
  FHE, and cross-asset requirements.

### Stage 7 consequence
- Existing Stage 7 invariant results are provisional. They are not acceptance
  evidence until the overconstrained amount generation, unchecked catches,
  encrypted-zero cleanup, permissionless-preclaim ordering, and per-asset
  accounting model are corrected and the campaign is rerun.

## 2026-08-26 — Stage 7 confidential asset and swap escrow separation

### Added
- `AlphaEngineConfidentialAssetRegistry` as a non-upgradeable, append-only
  underlying/FHERC20 wrapper registry and wrapper factory.
- `AlphaEngineConfidentialAssetGateway` as the pinned-registry convenience
  surface for ordinary deposit/shield and request/claim-unshield flows, with no
  retained underlying or business configuration.
- `AlphaEngineConfidentialSwapEscrow` as a fresh, initially paused transparent
  proxy domain for temporary locks, encrypted unshield requests, exact
  settlement, and pause-safe refunds.
- V2 interfaces, checked-in ABIs, an escrow storage-layout snapshot, generated
  artifact gates, unit/fuzz coverage, and a seven-property stateful invariant
  suite.

### Security boundaries
- Registry mappings are bijective and append-only. Registry, gateway, and
  escrow cannot substitute for one another's responsibilities.
- Controller and registry rotation require the escrow to be paused and have
  zero live locks. The pauser cannot unpause or reconfigure dependencies.
- The escrow stores the actual FHERC20 transfer-return handle, immediately
  requests encrypted unshield, and removes the dead legacy `Unlocked` state.
- Settlement marks replay state before external execution, independently
  enforces minimum output and exact balance deltas, resets approvals, and
  verifies the wrapper received the full underlying amount before accepting a
  confidential mint. This closes fee-on-transfer undercollateralization on the
  new gateway and settlement/refund paths.
- Refund remains callable through the exact controller while paused so an
  emergency pause cannot strand already-live user funds.

### Validation
- Focused Stage 7 unit/fuzz suite: 26 passed, including 257 fuzz runs.
- Stateful escrow suite: 7 properties passed at 64 runs and depth 32 (2,048
  calls per property). This result is provisional because later review found
  overconstrained inputs and unchecked handler catches that excluded or
  swallowed adversarial paths.
- Runtime sizes before final documentation sync: registry 16,409 bytes,
  gateway 2,991 bytes, and escrow 10,952 bytes; all remain below the 23,000-byte
  ceiling and exceed the required 1,500-byte margin.
- ABI/storage artifact parity passed. Full repository and coverage validation
  remain the final actions at this Stage 7 review checkpoint.

## 2026-08-26 — Finalized competition score reveal

### Added
- A dedicated `SCORE_REVEALER_ROLE` and rank-paginated
  `requestCompetitionScoreReveal` flow on
  `AlphaEngineCompetitionStrategyManager`.
- Each finalized submission requests asynchronous CoFHE decryption of its
  real-sister, perturbation-P25, and stress-P25 score handles together. Calls
  are capped at 32 submissions and reuse the manager's existing handle
  permission; no aggregate score or duplicate plaintext storage was added.
- `getPublicEvaluationScores` rejects access before finalization and otherwise
  returns the three published plaintext values with independent readiness
  flags, allowing the frontend/backend to tolerate partial asynchronous
  completion.

### Security and compatibility
- Score requests remain impossible before competition finalization and require
  a separate operational role. Rank pagination uses the finalized on-chain
  rank mapping rather than caller-provided submission identifiers.
- Added `CompetitionScoreRevealRequested` for listener discovery. The event
  signals a request, not completion; consumers must check readiness through the
  getter or CoFHE result events.
- Extended the repository CoFHE mock with caller-permission enforcement and
  decrypt-request tracking for parity with the pinned task-manager interface.

### Validation
- Focused Competition Manager unit/fuzz suite: 20 passed, including 257 fuzz
  runs.
- Competition Manager stateful invariant suite: 6 passed at 64 runs and depth
  32, including finalized-only reveal and three-component request parity, with
  zero handler reverts.
- Full repository suite: 249 passed, 0 failed, 0 skipped.
- Formatting, ABI/storage artifact parity, runtime-size gates, and
  `git diff --check` passed. The Competition Manager runtime is 17,276 bytes,
  below the 23,000-byte repository ceiling; its storage layout is unchanged.
- Focused whole-contract coverage reports 86.81% lines, 88.21% statements,
  50.00% branches, and 97.06% functions. The new reveal success, partial-ready,
  finalized-only, role, pagination, batch-bound, and cancelled-submission paths
  are exercised; the remaining figures reflect pre-existing Stage 5 coverage
  gaps and remain release-gate debt.

## 2026-08-26 — Stage 6 capital strategy manager

### Added
- `AlphaEngineCapitalStrategyManager` as a fresh, independently pausable
  upgradeable domain for qualified-trader capital intents.
- Fresh encrypted intent submission with canonical FHE handle internalization,
  per-trader nonces, qualification-version binding, and independent encrypted
  evaluation scores.
- Terminal rejection/cancellation/revocation/expiry states and immutable exact
  execution approval binding chain, manager, vault, executor, authorization
  nonce/window, policy root/version, call bundle, risk envelope, submission
  payload, and evaluation evidence.
- One-time execution consumption restricted to an allowlisted execution-manager
  contract, with commitment and authorization-nonce replay markers written
  before downstream execution. A mock execution manager proves downstream
  failure atomically restores all consumption state.
- Versioned ABI and storage-layout artifacts plus generated-artifact and
  23,000-byte runtime gates.

### Security boundaries
- Qualification applies to the trader; every capital intent remains a fresh
  encrypted submission and receives an independent evaluation.
- Revocation or expiry of the exact qualification version blocks approval and
  consumption, including after a later requalification.
- The Capital Manager has no token, native-asset, arbitrary-call, Merkle-root,
  or vault-custody authority. The production execution manager remains disabled
  until the second-pass vault scope is implemented and allowlisted.

### Validation
- Focused unit/fuzz suite: 30 passed, including 256 fuzz runs.
- Stateful invariant suite: 7 passed at 64 runs and depth 32 (2,048 calls per
  invariant, zero handler reverts).
- Nightly-strength Stage 6 stress: 10,000 fuzz runs passed; all seven invariants
  passed at 256 runs and depth 128 (32,768 calls per invariant, zero handler
  reverts).
- Full repository suite: 245 passed, 0 failed, 0 skipped.
- Targeted coverage: 100% branches and functions; 97.56% lines. The six lines
  reported uncovered are constructor/initializer and inherited pause-wrapper
  calls executed by passing tests but not attributed by Foundry's
  `--ir-minimum` source maps.
- ABI/storage parity passed. Runtime size is 17,186 bytes, leaving 5,814 bytes
  below the repository's 23,000-byte ceiling.

## 2026-08-26 — Finalized public USDC FundVault architecture

### Owner decision
- Replaced the earlier treasury-funded, shareless FundVault assumption with a
  public, USDC-only, share-based fund design.
- Locked three separate authority domains:
  - `AlphaEngineFundVault` holds USDC and positions and owns the share ledger;
  - `AlphaEngineUSDCVaultManager` handles deposits, withdrawals, daily NAV,
    checkpoint share pricing, 24-hour positive-P&L vesting, and immediate loss
    recognition;
  - `AlphaEngineVaultExecutionManager` handles capital authorization, Merkle
    proofs, decoders, risk caps, replay, and calls FundVault `manage`.
- The initial release does not deploy a general multi-asset Teller/Accountant
  stack or a deposit-conversion oracle. USDC is both the accepted asset and the
  accounting unit.
- NAV is the USDC net liquidation value of on-chain positions at a declared
  finalized block, net of realized and expected exit costs and liabilities.
- Deposits and withdrawals settle at daily checkpoints; reserved withdrawal
  USDC cannot be redeployed.

### Documentation
- Updated the canonical implementation plan, fund-vault policy, and architecture
  target. No FundVault Solidity was changed in this documentation stage.

## 2026-08-26 — Consolidated audit cadence and canonical plan path

### Owner decision
- Removed per-stage targeted audits from the implementation sequence.
- Continue through ordinary bounded stages using tests, fuzzing, invariants,
  ABI/layout parity, runtime-size, deployment, and documentation gates.
- After first-pass and second-pass implementation are both complete, run one
  consolidated full-repository internal audit, remediate its findings, run
  targeted re-audits only for those fixes, and then run the frozen-candidate
  full audit.
- Stopped the in-progress hashing-library targeted audit before any review pass
  completed or report was produced.

### Documentation consolidation
- Kept
  `docs/engineering/strategy-manager-fund-vault-implementation-plan.md` as the
  single canonical plan.
- Removed the identical root-level `audit-cleanup-plan.md` duplicate and
  redirected `AGENTS.md` to the canonical engineering plan.

## 2026-08-26 — V2 interfaces and replay-critical hashing primitives

### Added
- `AlphaEngineStrategyHashLib` for domain-separated competition, competition
  submission, capital-intent, and swap-intent identifiers plus ordered encrypted
  strategy payload hashes.
- `AlphaEngineExecutionHashLib` for ordered call bundles, strictly sorted asset
  risk envelopes, exact execution commitments, and salted swap minimum-output
  commitments.
- Shared qualification, capital-consumption, vault-execution-manager, and
  FundVault interfaces without introducing a storage-bearing base manager.
- A dependency-free Python Keccak-256 and ABI reference generator plus a
  checked-in V1 vector artifact.

### Security decisions
- V1 call bundles are nonempty, capped at 16, require nonzero decoder/target
  addresses, and reject native value.
- V1 risk envelopes are capped at 16 assets and require nonzero, strictly
  ascending asset addresses, eliminating duplicate/order ambiguity.
- Execution commitments bind chain, all manager/vault/executor identities,
  intent and qualification versions, authorization nonce/window, policy and
  risk versions, ordered calls, submission payload, and evaluation evidence.
- Hashes use `abi.encode`; dynamic arrays/calldata are reduced to explicit
  ordered hashes before commitment.

### Validation
- Dependency-free reference regeneration: passed.
- Focused hash suite: 10 passed, 0 failed.
- Every strategy payload and execution-commitment field has a mutation test.

## 2026-08-26 — Release-hygiene and reproducibility baseline

### Changed
- Applied the repository formatter as an isolated, non-behavioral cleanup and
  preserved the resulting script/test-only diff.
- Pinned CI to stable Foundry `v1.7.1` using the commit-pinned
  `foundry-rs/foundry-toolchain` action.
- Added least-privilege PR, nightly stress, and manually triggered release
  workflows with commit-pinned GitHub Actions.
- Added clean-submodule, sensitive-path, immutable legacy-manifest, ABI parity,
  storage-layout parity, formatting, test, coverage, and clean-tree gates.
- Enabled deterministic storage-layout emission in `foundry.toml`.

### Artifact evidence
- Archived the stale baseline controller ABI at
  `ABI/legacy/AlphaEngineIntentController.checked-in-49d96e8.json` before
  regenerating `ABI/AlphaEngineIntentController.json` from source.
- Captured genuine baseline layouts at
  `storage-layouts/legacy/AlphaEngineIntentController.49d96e8.json` and
  `storage-layouts/legacy/AlphaEngineConfidentialVault.49d96e8.json`.
- The legacy vault remains an explicit historical size exception; every fresh
  production contract must meet the plan's 23,000-byte release ceiling.

### Validation
- `forge fmt --check`: passed.
- `forge test --offline`: 152 passed, 0 failed, 0 skipped.
- `script/ci/check-repository-hygiene.sh`: passed.
- `script/ci/check-generated-artifacts.sh`: passed.
- `git diff --check`: passed.

## 2026-08-26 — Baseline internal Solidity audit

### Evidence
- Ran all eight Solidity-auditor review lenses against repository-owned
  production and deployment Solidity at baseline `49d96e8a80d6903d1d30affc6f836bcc0ac13800`.
- Persisted the consolidated report at
  `assets/findings/alphaengine-contracts-pashov-ai-audit-report-20260826-170601.md`.
- Recorded toolchain, tests, storage, runtime size, ABI/manifests hashes,
  dependency pins, severity dispositions, and residual risks in
  `docs/audits/internal/baseline-49d96e8-evidence.md`.

### Gate decision
- The audit confirmed two High fund-safety findings: permissionless pre-claim
  lock stranding and fee-on-transfer wrapper undercollateralization.
- The legacy combined deployment is historical and drain-down-only; it will not
  be rehabilitated or upgraded into the new product contracts.
- The High findings become mandatory regression cases for the fresh wrapper,
  swap escrow, and controller and must be closed in the consolidated
  end-of-implementation audit before release.
- The audit also confirmed planned architectural debt around encrypted-zero
  locks, bound swap execution, output precision, operator rotation, deadlines,
  and upgrade-manifest validation.

## 2026-08-26 — StrategyManager, confidential-swap, and FundVault implementation plan

### Approved direction
- Adopted the security-first staged implementation plan for independent
  competition, capital, confidential-swap, and treasury FundVault domains.
- Locked fresh proxy/address deployment for the first-pass upgradeable
  components and preserved the legacy combined deployment and manifest as
  historical evidence.
- Required the Solidity-auditor baseline, consolidated end-of-implementation,
  remediation, and frozen-candidate gates before production-readiness claims.

### Canonical plan
- `docs/engineering/strategy-manager-fund-vault-implementation-plan.md`
- This is the single mandatory implementation reference routed by `AGENTS.md`.

## 2026-08-26 — Contract instruction router

### Changed
- Replaced the monolithic repository `AGENTS.md` with a concise task router.
- Moved detailed Solidity, upgradeability, architecture, Fhenix/custody,
  compatibility, testing/audit, and FundVault/Merkle rules into focused files
  under `docs/agent-policies/`.
- Made routes cumulative and retained critical custody, storage, FHE permission,
  ABI/event, Foundry, and audit-freeze invariants in the always-loaded router.

### Decision
- Contract planning and implementation must load only the complete policy set
  matching the task, while high-impact invariants remain visible in the router.
- The instruction refactor changes no Solidity behavior, ABI, storage, or audit
  scope.

## 2026-08-26 — Strategy/swap separation and Fhenix audit plan

### Approved direction
- Separate TA / strategy-allocation intents from individual-user confidential swaps before freezing the Fhenix private-audit commit.
- Treat the current `AlphaEngineConfidentialVault` as swap escrow/custody infrastructure, not as an LP fund-management vault.
- Reserve `AlphaEngineFundVault` for a separate future design covering pooled deposits, shares, NAV, withdrawals, allocation limits, fees, and long-lived custody.
- Preserve the existing strategy and swap behavior during the split; deploy new proxies rather than deleting or reordering legacy combined-controller storage through an in-place upgrade.

### Execution boundary
- Timebox the behavior-preserving separation to one focused engineering day using the existing unit, fuzz, invariant, integration, and CoFHE compatibility harnesses.
- If the split requires new product behavior, LP accounting, migration logic, or weakened tests, stop and rescope rather than extending the refactor silently.
- Freeze and identify one immutable audit commit only after the full validation and audit-handoff gates pass.

### References
- `docs/engineering/strategy-swap-separation-plan.md`
- `docs/audits/fhenix-private-audit-readiness.md`

### Second-pass fund-vault reference
- Recorded `/Users/nilay/yieldfi/veda-poc` as a design reference for the future
  `AlphaEngineFundVault` Merkle-verified execution layer.
- Kept the Veda-style vault implementation outside the current Fhenix audit and
  strategy/swap separation pass.
- Required the later implementation to pin an exact reviewed source revision
  and bind Merkle-authorized call batches to AlphaEngine's approved capital
  execution commitments.

## 2026-05-11 — Strategy official score submission on-chain

### Added
- `AlphaEngineIntentController.submitStrategyEvaluationScores` for operator-only posting of encrypted final official-score components.
  - Stores encrypted `realSister`, `perturbationP25`, and `stressP25` as `uint32` FHE handles.
  - Prevents re-submission per intent.
  - Emits `StrategyEvaluationScoresSubmitted`.
- `AlphaEngineIntentController.getEvaluationScores` read view for off-chain decode and persistence.
- New internal helper `createInEuint32` in `MockCoFheTest` for deterministic encrypted `uint32` test vectors.
- `EvaluationScoreRecord` storage mapping and a reduced storage gap (`uint256[42]`).

### Validation
- Added unit coverage for:
  - successful encrypted score submission and access grants,
  - unauthorized caller rejection,
  - duplicate submission rejection,
  - non-active intent rejection,
  - default getter behavior for unknown intents.

### Compatibility impact
- New event/ABI surface for strategy-off-chain official scoring is now contract-owned and requires synced consumer updates.
- Storage layout changed in `AlphaEngineIntentController`; upgradeability review required before deployment.

## 2026-05-05 — Arbitrum Sepolia full-stack deployment script

### Added
- `DeployAlphaEngineArbitrumSepolia` Foundry script for deploying:
  - `AlphaEngineIntentController` implementation + transparent proxy,
  - `AlphaEngineConfidentialVault` implementation + transparent proxy,
  - optional `AlphaEngineV4SwapExecutor`,
  - optional input/output FHERC20 wrapper creation or registration.
- Deployment manifest writing to `deployments/arbitrum-sepolia-latest.json` by default.

### Decisions
- Keep the existing controller-only deployment script unchanged.
- Use standard deployment for this script instead of `CREATE2`; deterministic addresses can be added later with explicit salt/deployer governance.
- Owner-only setup is performed by default, so the broadcast account must be `OWNER` unless `PERFORM_OWNER_SETUP=false`.
- The script uses `vm.startBroadcast()` instead of reading `PRIVATE_KEY` from `.env`, allowing deployment through a Foundry keystore account or a CLI-provided private key.

## 2026-04-09 — Initial scaffold

### Added
- Foundry-only repo scaffold for AlphaEngine contracts.
- Strict Solidity-specific `AGENTS.md` with upgradeability, coverage, fuzz, and invariant guardrails.
- V1 contract boundary locked to one upgradeable TA-family intent controller.

### Decisions
- Transparent proxy + `ProxyAdmin` for upgrades.
- EigenCompute-only in v1; no AVS registration or middleware.
- State + event are canonical.
- Foundry is the only framework in v1.
- Current pinned `cofhe-contracts@v0.1.3` uses `bytes32` encrypted handles, not the older `uint256` handle shape.
- Current pinned OpenZeppelin `TransparentUpgradeableProxy` deploys its own `ProxyAdmin`; deployment scripts derive and report the admin address instead of deploying it separately.

### Temporary Debt
- Upstream `cofhe-mock-contracts` parity with current `cofhe-contracts` remains unresolved on the Foundry path.
  - Owner: AlphaEngine contracts repo
  - Removal trigger: verified upstream version matrix or maintained Foundry mock package that matches the pinned production `cofhe-contracts`

## 2026-04-09 — Foundry compatibility harness

### Added
- Repo-owned Foundry CoFHE compatibility harness for the exact v1 contract surface:
  - encrypted input verification via `verifyInput`
  - handle access grants via `allow`
  - deterministic mock-value assertions for stored `bytes32` handles
- Unit, fuzz, and invariant suites now run cleanly against the current production `cofhe-contracts` package without depending on the stale upstream Foundry wrapper.

### Decisions
- Keep production contracts pinned to current `cofhe-contracts` semantics (`bytes32` handles).
- Do not downgrade production dependencies to match older mock-contract packages.
- Keep Foundry canonical and isolate upstream mock-package lag as external compatibility debt.
- Do not track the stale upstream `cofhe-mock-contracts` package as an active repo dependency in v1.
- Explicitly exclude the transparent-proxy admin address from unauthorized-caller fuzz checks because proxy-admin reverts happen before implementation-level authorization logic.

### Next Steps
- Confirm the current package/version matrix directly with Fhenix.
- Keep local compatibility harness until an upstream Foundry-compatible replacement is verified.

## 2026-04-09 — Encrypted market envelope

### Changed
- `AlphaEngineIntentController` no longer accepts or emits a plaintext market address in the TA-family submission path.
- V1 submit surface now internalizes an encrypted `marketId` input and stores/emits its `bytes32` handle alongside the encrypted strategy component handles.
- `payloadHash` now commits to `marketIdHandle` instead of a plaintext market address.

### Decisions
- Market identity belongs to the intent envelope, not the strategy component codec.
- The contract stores encrypted `marketId` handles only; plaintext `marketId -> market` resolution stays off-chain.
- The temporary canonical market registry is currently authored in `simulation-service` and consumed by `listener-service` after decrypting the envelope.

### Compatibility Impact
- `listener-service` must consume `StrategyIntentSubmitted` with `marketIdHandle` and decrypt/resolve market identity off-chain.
- Plaintext market-address assumptions from earlier scaffolding are no longer valid.

## 2026-04-10 — Confidential swap/vault architecture planning

### Added
- Architecture plan for the next confidential swap and vault phase in `docs/engineering/confidential-swap-vault-architecture.md`.
- Guardrails for keeping intent lifecycle separate from token custody.
- Testing requirements for vault custody, FHERC20 wrapper lifecycle, atomic locking, and future swap settlement.

### Decisions
- Use official Fhenix FHERC20 / confidential token contracts for encrypted token behavior.
- Do not reintroduce the hookathon `HybridFHERC20` token as production code.
- Add a future upgradeable `AlphaEngineConfidentialVault` boundary for deposit/shield, withdraw/unshield, wrapper creation, locks, unlocks, consume/burn behavior, and output credit.
- Keep swap intent submission in `AlphaEngineIntentController`.
- Use atomic FHERC20 authorization-based locking and treat the returned actual transferred encrypted handle as canonical.
- Scope confidential wrappers per underlying ERC20.
- Keep batching, AVS registration, hook logic, and PoolManager swap execution out of the first vault/locking implementation.

### Next Steps
- Install and verify the current official Fhenix confidential-token package and exact FHERC20 Solidity interfaces.
- Design `AlphaEngineConfidentialVault` storage layout and upgrade scripts before adding production code.
- Add vault unit, fuzz, and invariant scaffolding before implementing real custody paths.

## 2026-04-10 — Confidential vault scaffold

### Added
- Pinned `FhenixProtocol/fhenix-confidential-contracts@v0.3.1` as a Foundry dependency.
- Minimal official FHERC20 ERC20 wrapper contract for AlphaEngine-managed wrappers.
- Upgradeable `AlphaEngineConfidentialVault` scaffold with initializer, intent-controller pointer, and wrapper registry.
- Unit tests for vault initialization, intent-controller update, wrapper creation, wrapper registration, duplicate rejection, and pause/unpause.

### Decisions
- Target the latest verified `fhenix-confidential-contracts@v0.3.1` tag for scaffold imports.
- Use official FHERC20 `euint64` token amount semantics for confidential asset balances.
- Treat the public docs' `encTransferFrom` / permit-style API as unverified until a tagged package exposes it.
- Keep deposit, withdraw, lock, unlock, consume, settlement, and PoolManager integration out of this scaffold commit.

## 2026-04-10 — Vault deposit and unshield wrappers

### Added
- `AlphaEngineConfidentialVault.depositAndShield(...)` for registered underlying ERC20 assets.
- `AlphaEngineConfidentialVault.requestUnshield(...)` and `claimUnshielded(...)` delegation for registered FHERC20 wrappers.
- Vault events for deposit/shield, unshield request, and unshield claim flows.
- Explicit tests for successful deposit/shield, unshield request/claim, unsupported asset rejection, precision bounds, non-multiple amount rejection, and fee-on-transfer balance-drift rejection.
- CoFHE mock-task support for deterministic FHERC20 wrapper operations used by tests: trivial encryption, add/sub, comparisons, select, and decrypt-result verification.

### Decisions
- The vault is the AlphaEngine custody/orchestration boundary, while official FHERC20 wrapper contracts physically hold underlying ERC20 reserves after `shield(...)`.
- Deposit amounts must be exact multiples of the wrapper `rate()`; the vault must not silently rely on wrapper rounding.
- Fee-on-transfer or other balance-drift behavior is rejected in deposit/shield instead of allowing undercollateralized wrapper mints.
- Swap-intent locking, cancellation unlock, consume/settlement, and PoolManager execution remain out of scope for this step.

## 2026-04-10 — Vault swap-intent lock state

### Added
- `AlphaEngineConfidentialVault.lockForSwapIntent(...)` for controller-only FHERC20 escrow locking.
- At this stage the vault used a temporary controller-only consume marker for swap locks. This was later replaced by the real `settleSwapIntent(...)` and `refundSwapIntent(...)` lifecycle.
- `AlphaEngineConfidentialVault.getSwapIntentLock(...)` for deterministic lock-state inspection.
- Swap lock events:
  - `SwapIntentLocked`
  - `SwapIntentLockConsumed`
- Unit tests for lock, consume, unauthorized callers, zero IDs, zero account, unregistered wrapper, duplicate locks, inactive lock states, invalid returned handles, and paused behavior.

### Decisions
- Lock storage was added append-only as a new mapping and the vault storage gap was reduced by one slot.
- The vault accepts a verified `euint64` requested amount handle, not an `InEuint64` user input.
- The future intent controller must verify the user's `InEuint64` while `msg.sender` is still the user, grant the vault access to the resulting handle, and then call the vault.
- The vault stores the FHERC20-returned actual transfer handle as canonical.
- Consume currently marks the escrow lock as `Consumed`; it does not burn, unshield, route through PoolManager, or mint output confidential tokens yet.

### Next Steps
- Wire `submitSwapIntent(...)` in `AlphaEngineIntentController` to verify user encrypted amount input and call the vault lock path atomically.
- Add controller/vault integration tests for swap-intent submission and status parity.
- Add fuzz and invariant coverage for vault lock state transitions before adding PoolManager settlement.

## 2026-04-10 — Controller swap-intent submission

### Added
- `AlphaEngineIntentController.setConfidentialVault(...)` for owner-controlled vault selection.
- `AlphaEngineIntentController.submitSwapIntent(...)` for atomic controller-side verification and vault locking.
- `AlphaEngineIntentController.getSwapIntent(...)` for deterministic swap-intent record inspection.
- Swap intent events:
  - `SwapIntentSubmitted`
  - `ConfidentialVaultUpdated`
- Controller/vault unit tests using the real `AlphaEngineConfidentialVault` and FHERC20 wrapper path.

### Decisions
- The controller initializer remains unchanged for proxy compatibility; the confidential vault is configured after initialization.
- `setConfidentialVault(...)` rejects non-contracts, contracts without the vault surface, and vaults whose `intentController()` does not point back to the controller.
- `submitSwapIntent(...)` verifies the user's `InEuint64`, grants vault access to the resulting handle, then calls the vault lock path.
- Swap records store the vault used at submission time, so vault rotation affects future submissions only.
- Swap storage was added append-only after the existing controller storage and the controller storage gap was reduced by two slots.
- `payloadHash` for swap intents commits to `confidentialVault`, `inputWrapper`, `routeKey`, `deadline`, the vault-returned `lockedAmountHandle`, and the vault-returned `unshieldRequestHandle`.
- `routeKey` is intentionally opaque for now and must not be treated as finalized PoolManager execution-template semantics.
- Swap submission is now final because the vault auto-requests unshield during `lockForSwapIntent(...)`; there is no user-cancel path for swap intents.

### Next Steps
- Add swap-specific fuzz and invariant coverage before introducing PoolManager settlement.
- Finalize route-key / execution-template semantics before adding swap execution.
- Add vault and controller deployment script coverage for the new vault pointer.

## 2026-04-10 — Invariant ledger

### Added
- `docs/engineering/invariant-ledger.md` as the durable ledger for current and planned controller/vault invariants.
- Explicit invariant classes for controller state, cross-family isolation, vault registry stability, deposit/unshield accounting, swap lock lifecycle, controller/vault parity, access permissions, admin/pause behavior, and future settlement.
- Mathematical expressions for payload-hash determinism, shared nonce exactness, wrapper registry bijection, mock `ctHash` accounting, escrow conservation, and reserve conservation.

### Decisions
- Treat `mockStorage(uint256(handle))` as the invariant-test value oracle for current Foundry FHERC20/CoFHE accounting checks.
- Keep current strategy-only invariants documented as already implemented, and mark mixed strategy/swap plus vault accounting invariants as the next test step.
- Do not add route or PoolManager settlement invariants until `routeKey` is replaced by finalized execution-template semantics.

## 2026-04-10 — Swap/vault fuzz and invariant coverage

### Added
- Superseded later by execute/refund fuzz coverage: at this stage controller fuzz coverage focused on shared strategy/swap nonce progression and cross-family cancellation isolation.
- Superseded later by execute/refund coverage: at this stage the mixed controller invariant handler focused on strategy submit/cancel, early swap submit-state coverage, listener-operator rotation, and configured-vault rotation.
- Controller invariant checks for strategy record consistency, swap record/vault lock parity, shared nonce exactness, family-scoped intent ids, non-zero listener operator, and valid configured vault pointer.
- Superseded later by the two-wrapper settlement harness: at this stage the vault invariant handler covered deposit/shield, early swap lock state, unshield request, and unshield claim flows.
- Vault invariant checks for wrapper registry stability, lock lifecycle and field immutability, vault escrow conservation, per-user confidential balance conservation, confidential supply conservation, wrapper reserve conservation, claim snapshot consistency, and stable vault owner/intent-controller authority.

### Decisions
- Keep vault `setIntentController(...)` out of the random invariant action set while locks exist; the eventual safe design is either an on-chain active-lock counter gate or an explicit per-lock controller-binding model.
- Execute `FHE.asEuint64(...)` in the vault invariant handler through an external self-call under the simulated user sender. This matches the production controller pattern: user input is verified while `msg.sender` is the user, then the authorized controller calls the vault.
- Use isolated invariant failure-persist directories during focused invariant runs to avoid stale Foundry failure-cache replays affecting diagnosis.

### Validation
- `forge test --offline --match-contract AlphaEngineIntentControllerFuzzTest`
- `FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR=/tmp/alphaengine-controller-invariant-failures forge test --offline --match-contract AlphaEngineIntentControllerInvariantTest --fail-fast -vv`
- `FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR=/tmp/alphaengine-vault-invariant-failures forge test --offline --match-contract AlphaEngineConfidentialVaultInvariantTest --fail-fast -vv`
- `forge test --offline`
- `forge fmt --check`
- `git diff --check`
- `forge coverage --offline --ir-minimum --report summary`

### Coverage Note
- Plain `forge coverage --offline --report summary` fails with a compiler stack-too-deep error because Foundry disables the repo's normal `viaIR` setting for coverage.
- `forge coverage --offline --ir-minimum --report summary` runs successfully and reports 100% branches and 100% functions for repo-owned contracts, with 97.16% lines and 97.17% statements.
- The uncovered line map is limited to no-anchor internal calls for `_disableInitializers()`, `__Pausable_init()`, `_pause()`, and `_unpause()` while their enclosing constructors/functions are executed by tests.

## 2026-04-10 — External protocol dependency boundary

### Added
- Pinned `Uniswap/v4-core@v4.0.0` as a future Foundry fixture / separately-approved executor dependency.
- Explicit docs and agent guardrails that `AlphaEngineIntentController` and `AlphaEngineConfidentialVault` must remain protocol-agnostic and must not import Uniswap, Pendle, Morpho, Aave, or other route-specific protocol ABIs.

### Decisions
- Do not add `@uniswap/v4-periphery` speculatively.
- Treat PoolManager execution as a separate executor boundary, not intent-controller or vault logic.
- Keep generic UEI execution as a valid future path for arbitrary approved targets instead of installing every target protocol in the core intent contracts.
- `routeKey` remains opaque and must not be treated as a Uniswap-specific field.

### Temporary Debt
- Resolved 2026-04-10: repo-owned contracts and Foundry config now pin `solc = 0.8.26` to match the pinned `v4-core@v4.0.0` PoolManager fixture dependency.

## 2026-04-10 — Temporary encrypted unshield extension

### Added
- Upgraded repo-owned Solidity sources and Foundry config from `0.8.25` to `0.8.26` after verifying Fhenix package constraints accept `0.8.26`.
- Added temporary `AlphaEngineFHERC20ERC20Wrapper.unshield(address from, address to, euint64 amount)` overload for encrypted-amount unshield requests.
- Added vault-side automatic swap-intent unshielding during `lockForSwapIntent(...)` so submit-time locking and unshield request happen atomically in one transaction.
- Added controller/vault unit and invariant coverage for the returned actual unshield request handle.

### Decisions
- Remove the custom direct `releaseUnderlyingForSettlement(...)` direction. It skipped the official-style proof over the actual burned handle and would create a higher-risk custody shortcut.
- Keep the temporary encrypted-unshield overload as an integration bridge only. Once Fhenix publishes official encrypted-amount unshield support, replace the AlphaEngine extension with the official wrapper surface.
- Keep underlying release, swap execution, and output shielding as a later finalize path. This step makes swap submit final by creating the unshield request immediately and eliminating the old cancellable swap-lock assumption.

### Validation
- `forge test --offline --match-contract AlphaEngineConfidentialVaultUnitTest`
- `forge test --offline --match-contract AlphaEngineConfidentialVaultInvariantTest --fail-fast`
- `forge test --offline`

## 2026-04-13 — Swap execution boundary and first concrete Uniswap v4 settlement

### Added
- Added `swapExecutor` configuration plus `executeSwapIntent(...)` on `AlphaEngineIntentController`.
- Added `AlphaEngineConfidentialVault.settleSwapIntent(...)` to claim the actual unshield handle, transfer exact underlying input into an executor boundary, and shield output confidential balance back to the submitter.
- Added `AlphaEngineV4SwapExecutor` as the first concrete executor boundary that imports canonical `v4-core` and performs exact-input swaps through `PoolManager.unlock(...)`.
- Added deterministic unit coverage for:
  - controller execute success and failure paths;
  - vault settlement success and failure paths;
  - real `PoolManager` initialization, liquidity seeding, and swap execution behind the executor boundary.

### Decisions
- Keep `AlphaEngineIntentController` and `AlphaEngineConfidentialVault` protocol-agnostic even after enabling swap execution. Uniswap-specific code lives only in the separate executor contract.
- Keep `routeKey` metadata-only. The concrete route is passed through executor-specific calldata and is not decoded by the controller or vault.
- Enforce exact input consumption at the executor boundary. If a route does not consume the full claimed input, the execution reverts instead of leaving partial input stranded.
- Use 6-decimal assets for the first end-to-end settlement fixture so output shielding remains exact; higher-decimal wrapper rounding and dust policy remain a separate follow-up concern.

### Remaining Gaps
- Superseded by the later 2026-04-13 parity/invariant entry: execute-time invariants are now implemented for the mock-executor path, while deterministic twin-pool tests cover concrete PoolManager output parity.
- Current concrete executor coverage is Uniswap v4 exact-input only; no batching, exact-output, UEI, leverage-loop, or result-posting path exists yet.

### Validation
- `forge test --offline --match-path test/unit/AlphaEngineIntentController.t.sol`
- `forge test --offline --match-path test/unit/AlphaEngineConfidentialVault.t.sol`
- `forge test --offline`

## 2026-04-13 — Twin-pool reference parity and execute-time invariant coverage

### Added
- `test/integration/AlphaEngineSwapExecutionReference.t.sol` with twin-pool exact-input parity checks:
  - one direct `PoolSwapTest` reference swap,
  - one `submitSwapIntent -> executeSwapIntent` path on an identical second pool,
  - exact `tokenOut` equality assertions in both directions,
  - minimum-output rejection when `minOutput` exceeds the direct reference quote.
- Reusable `test/mocks/MockSwapExecutor.sol` for execution-aware fuzz and invariant paths.
- Controller fuzz coverage for:
  - successful swap execution status/lock consumption,
  - strategy-state isolation across swap execution.
- Controller invariant handler execute selectors for both listener operators.
- Vault invariant handler settlement selector using same-wrapper settlement through the mock executor.
- Additional vault invariant checks for consumed-lock claim parity and zero executor residual underlying.

### Decisions
- Use `PoolSwapTest` as the non-circular deterministic reference path for exact-output parity. This avoids validating `AlphaEngineV4SwapExecutor` with itself.
- Keep stateful invariant settlement on a same-wrapper path. It exercises claim + consume + re-shield while preserving tight accounting equalities without tracking multi-wrapper output state in the handler.
- Treat real PoolManager output parity as deterministic integration coverage, not as a random invariant property.

### Validation
- `forge test --offline --match-path test/integration/AlphaEngineSwapExecutionReference.t.sol`
- `forge test --offline --match-path test/fuzz/AlphaEngineIntentController.fuzz.t.sol`
- `forge test --offline --match-path test/invariant/AlphaEngineIntentController.invariant.t.sol`
- `forge test --offline --match-path test/invariant/AlphaEngineConfidentialVault.invariant.t.sol`
- `forge test --offline`

## 2026-04-14 — Cross-wrapper settlement invariants and dust atomicity

### Added
- Replaced the vault invariant harness's same-wrapper settlement shortcut with a two-wrapper model:
  - input wrapper backed by a 6-decimal underlying,
  - output wrapper backed by an 18-decimal underlying with a non-trivial `rate()`.
- Added `test/mocks/MockMintingSwapExecutor.sol` so invariant settlement:
  - consumes the claimed input immediately,
  - mints output directly to the vault for shielding,
  - leaves no residual balances on the executor.
- Added vault invariants for:
  - per-wrapper reserve backing,
  - cross-wrapper user-unit conservation,
  - consumed-lock exact output accounting,
  - output confidential-balance parity with tracked settlement credits,
  - dust-settle revert atomicity.

### Decisions
- Stateful vault invariants should no longer rely on same-wrapper settlement, because that hides the exact class of bugs that can appear when `inputWrapper != outputWrapper` and `rate(input) != rate(output)`.
- Rate/dust safety is now treated as a stateful invariant property, not only as a unit-test concern.
- The invariant executor is intentionally mock-only and mint-based. Deterministic price/output parity remains the job of the real PoolManager integration suite.

### Validation
- `forge test --offline --match-path test/invariant/AlphaEngineConfidentialVault.invariant.t.sol`

## 2026-04-14 — Live-lock controller rotation guard

### Added
- On-chain `liveSwapLockCount` tracking inside `AlphaEngineConfidentialVault`.
- `setIntentController(...)` now rejects rotation while any swap lock is still live.
- Unit, fuzz, and invariant coverage proving:
  - lock creation increments the live-lock counter,
  - successful settlement decrements it,
  - controller rotation is blocked while the counter is non-zero.

### Decisions
- For the current MVP, forbidding controller rotation while live locks exist is safer and simpler than introducing per-lock controller binding.
- This keeps the vault under a single controller authority model and avoids split historical settlement authority.

### Validation
- `forge test --offline --match-path test/unit/AlphaEngineConfidentialVault.t.sol`
- `forge test --offline --match-path test/fuzz/AlphaEngineIntentController.fuzz.t.sol`
- `forge test --offline --match-path test/invariant/AlphaEngineConfidentialVault.invariant.t.sol`

## 2026-04-14 — Expiry/pause refund path for live swap locks

### Added
- `refundSwapIntent(...)` on `AlphaEngineIntentController` as the terminal rescue path for live swap intents.
- `refundSwapIntent(...)` on `AlphaEngineConfidentialVault` to:
  - claim the stored `unshieldRequestHandle`,
  - verify the claimed underlying matches the decrypted amount and wrapper rate,
  - re-shield the recovered underlying back into the original input wrapper for the original submitter.
- New terminal statuses:
  - `IntentStatus.Refunded`
  - `SwapIntentLockStatus.Refunded`
- Unit, fuzz, and invariant coverage for expiry-driven refunds, pause-driven refunds, controller/vault parity after refund, and reserve conservation after re-shield.

### Decisions
- Swap intents remain non-cancellable after submit. Refund is not a soft cancel path; it is a rescue path for expired or paused live swaps.
- Refund intentionally bypasses controller/vault `whenNotPaused` gates because pause must not strand already-live user funds.
- Route execution remains operator-directed for the current MVP:
  - `routeKey` is metadata only,
  - concrete `outputWrapper`, `minOutputAmount`, and executor calldata remain listener/operator supplied at execution time.
- Settlement outcomes remain event-indexed rather than state-backed for the current MVP. Off-chain indexing is the canonical reconstruction path for executed swap results.

### Validation
- `forge test --offline --match-path test/unit/AlphaEngineIntentController.t.sol`
- `forge test --offline --match-path test/unit/AlphaEngineConfidentialVault.t.sol`
- `forge test --offline --match-path test/fuzz/AlphaEngineIntentController.fuzz.t.sol`
- `forge test --offline --match-path test/invariant/AlphaEngineIntentController.invariant.t.sol`
- `forge test --offline --match-path test/invariant/AlphaEngineConfidentialVault.invariant.t.sol`
