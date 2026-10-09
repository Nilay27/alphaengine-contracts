# Development Log

## 2026-10-09 — Rolling competition submissions

- Allow 3 successes per wallet per rolling 5 minutes across encrypted markets;
  paused admin can configure the limits. Cancellation does not refund admission.
- Only the latest entry per trader/competition is ranked; replacement supersedes
  the previous entry atomically. ABI additions and two reserved slots are captured.
- All 28 suites, coverage (93.64% lines overall), ABI/storage, size and hygiene
  checks passed. Deployment and consumer preflight/history updates remain pending.

## 2026-10-09 — Local competition-v2 integration checkpoint

- The recorded Competition Manager proxy has an active competition and a
  receipt-confirmed encrypted submission. The operator decrypted the payload,
  simulated/evaluated it and recorded score `50.19000420422378` through the
  local app-bff; the database and leaderboard API returned the result.
- See the [deployment record](engineering/deployment-arbitrum-sepolia-2026-10-09.md)
  for competition/transaction identity and the preserved initial checkpoint.
  Scoring is off-chain; on-chain evaluation, finalization/public reveal and
  complete orphan rollback remain pending.
- A second attempt exposed the existing one-active-submission-per-trader
  competition restriction. Public markets, configurable cooldowns and repeated
  attempts remain a discussion only; no Solidity behavior was changed.
- Validation before publishing the deployment records: 347 Foundry tests across
  28 suites passed; changed-Solidity formatting, ABI/storage/hash-vector and
  runtime-size checks, dependency/repository hygiene and staged whitespace
  checks passed. The local evidence reconciles 14 successful creation receipts
  and all 19 recorded addresses; candidate/confirmed manifests and legacy
  evidence retain their original provenance.

## 2026-10-09 — User-broadcast Arbitrum Sepolia v2 deployment recorded

- Reconciled 14 successful creation receipts against the script candidate,
  recording all 19 addresses including five internally created ProxyAdmins.
  Correct L2 deployment range: 317150657–317150728; the original candidate's
  block is simulation context and remains preserved unchanged.
- Added the [final deployment record](engineering/deployment-arbitrum-sepolia-2026-10-09.md)
  and a separate receipt-reconciled manifest with transaction hashes and blocks.
  Preserved the legacy manifest and earlier explorer snapshot.
- User reports Foundry verified all eight submitted contracts. This does not
  claim separate explorer verification of every proxy/admin or live bytecode,
  role, pause-state or reciprocal-link reconciliation. No signing, broadcast,
  admin activation, SDK upgrade, AWS or DNS operation was performed here.
- At initial deployment capture, the dashboard/operator SDK pin was 0.5.1.
  Upstream 0.7 breaks permit/ACP naming and encryption packet shape and requires
  consuming-contract binding; 0.8 adds address-book TaskManager resolution.
  The dashboard also still calls the retired submitStrategyIntent interface;
  competition ABI/config/lifecycle and listener migration remain separate work.
  See the deployment record for evidence and the bounded remaining tasks.


## 2026-10-09 — Configured Alchemy RPC alias

- The user selects the existing `ARBITRUM_SEPOLIA_RPC_URL` in ignored `.env`
  for the deployment command. Add the Foundry `arbitrum_sepolia` RPC alias,
  which resolves that variable internally without putting the API key into
  command text or requiring dotenv to be sourced as shell code.
- Compiler settings and deployment scope are unchanged. The earlier public-RPC
  rehearsal remains historical evidence; validate the Alchemy alias and repeat
  the prepared command without broadcasting before handing it to the user.
  Signing remains through the `alphaengine-deployer` keystore.

## 2026-10-08 — No-broadcast v2 deployment preparation

- User instruction explicitly limits this step to script completion, environment
  validation and simulation; no public transactions may be broadcast.
- Pin CoFHE v1.0.0, install a durable local address-book fixture and preserve the
  existing consumer ABI revision. Update manifest library metadata while keeping
  the schema compatible with retained 0.2.0 manifests.
- Guard manifest paths before transaction recording/writing, reject directory
  traversal and preserve the immutable legacy manifest. The old local dotenv
  target pointed at legacy evidence and is now corrected to the ignored
  rehearsal directory.
- Limit test-only role collapse to Sepolia/local chain IDs. Report candidate,
  capital-paused, omitted-vault, pending-wrapper and unverified statuses instead
  of treating simulation output as confirmed deployment.
- Add a no-broadcast helper that validates actual role settings and RPC code,
  resolves the CoFHE TaskManager and derives real dependency/ABI/layout/source
  fingerprints without printing secrets or unlocking the keystore.
- Scope, evidence paths, fingerprint definitions and remaining public-deployment
  gates are in the [rehearsal log](engineering/deployment-rehearsal-2026-10-08.md).
  Completed October 9 on pinned Foundry 1.7.1: 347 tests pass, 15 ABI and five
  layout snapshots match, runtime-size and formatting/hygiene checks pass, and
  the final Arbitrum Sepolia fork simulation records 14 simulated transactions
  with zero confirmed receipts. The final source fingerprint and legacy
  manifest integrity were independently checked. The initial fixture nonce
  shift was corrected without removing saved invariant failures. No broadcast
  or explorer verification occurred; omitted products remain not deployed.

## 2026-10-08 — Selected deployment scope: strategies and confidential swaps

- The user supersedes the earlier competition-only deployment proposal: prepare
  fresh qualification, competition and capital managers plus the confidential
  swap controller, swap escrow, asset registry/gateway, swap executor and
  required confidential-token library. Deploy reviewed asset wrappers as needed
  for the selected assets and Fhenix admission scope; asset addresses, wrapper
  configuration and target-network PoolManager remain deployment inputs.
- The beta frontend remains focused on competition. Deployment and explorer
  verification of additional contracts do not activate their UI or runtime.
  The user wants the swap contracts included for subsequent mainnet admission;
  mainnet will have its own deployment addresses and whitelisting step.
- Omit the pooled `AlphaEngineFundVault`, `AlphaEngineUSDCVaultManager`,
  `AlphaEngineVaultExecutionManager` and vault-bound decoders for now. These are
  independent from competition and confidential swaps. Keep the Capital Manager
  paused, with no approved execution manager; capital approval/execution cannot
  operate without the real vault system.
- The confidential Swap Escrow is required and is not the omitted FundVault.
  Preserve its settlement/refund path and verify swap reciprocal links before
  activation. Deploy fresh proxies paused and preserve legacy deployment
  evidence.
- Reuse and adapt `DeployAlphaEngineV2`, which already deploys the selected core
  strategy/swap stack and omits FundVault. A new competition-only script is no
  longer needed. Remaining preparation includes the CoFHE 1.0.0 dependency/test
  migration, linked-library and asset setup, accurate manifest metadata/status,
  dry-run validation and explorer verification. The current manifest's
  `fundVaultStatus: not-implemented` is stale; the eventual deployment manifest
  must identify the implemented vault system as deliberately not deployed.
- This records scope and preparation, not a transaction broadcast, completed
  verification, whitelisting or a mainnet-readiness claim. Existing mainnet key,
  governance and release requirements remain in force.

## 2026-10-08 — Beta signer and mainnet key/ownership requirement

- User decision: reuse the existing encrypted Foundry keystore account
  `alphaengine-deployer` for the Arbitrum Sepolia beta. The user reports no key
  exposure; that is not an independently verified key-security assessment.
- The user identifies its address as
  `0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d` and authorizes using it for
  currently missing beta role addresses. The ignored local `.env` already had
  `OWNER`, `LISTENER_OPERATOR` and `BROADCASTER` set to that address; the 17
  explicit v2 role variables were filled with it, preserving existing values
  and unrelated credentials. `EXPECTED_CHAIN_ID=421614` and
  `TEST_ONLY_ROLE_COLLAPSE=true` mark this as Arbitrum Sepolia configuration.
  This collapse is test-only and must be recorded in the deployment manifest.
  The current script reads explicit v2 roles and uses the CLI keystore account
  for signing; the three legacy variable names alone do not configure it.
  Role defaults alone do not select products for deployment. The later scope
  decision above includes capital/swap deployments while keeping capital paused;
  non-role deployment metadata and script preparation remain pending.
- Mainnet must use a fresh, dedicated deployment key separate from beta/testnet,
  preferably held in a hardware wallet. Assign long-term contract ownership and
  upgrade permissions to a Safe multisig with independently secured signers.
  Hardware wallets can secure the Safe signers.
- Verify the ownership/role handover, then remove any deployment-wallet admin
  permissions that are no longer needed. Mainnet signer addresses, Safe
  threshold and the exact handover procedure remain deployment configuration
  work; they are not implemented or verified by this decision record.
- Only documentation and ignored local role configuration changed: no keys
  generated, Safe created, contracts changed, permissions transferred or
  transactions broadcast. This requirement does not authorize deployment. See the
  [beta redeployment handoff](../../aws-migration/BETA-REDEPLOYMENT-HANDOFF-2026-10-08.md#contract-signer-and-mainnet-ownership-decision--8-october-2026).

## 2026-09-25 — Fhenix review remediation

- CoFHE 0.2 / FHERC20 0.4 migration: external inputs with batch proofs, shared
  handles, distinct claim IDs, public score authorization and linked-library
  deployment metadata. [Migration/adapter ownership](engineering/cofhe-v020-migration.md).
- Completed minimums, swap/withdrawal budgets, verified-zero cooldowns, full-balance
  dust exits and once-per-rank score pacing. [Policy and validation](engineering/fhenix-decrypt-pressure-remediation.md).
  Custody, canonical handles, scoring and qualification are preserved.
- Checkpoints passed 315, 323, then 345 tests; final coverage is 93.42% lines.
  One new test's optimized timestamp assertion was corrected before the final
  passing run. ABI/layout/hash/size/hygiene checks passed; existing proxy fields
  and reserved end slots are preserved. Live CoFHE/consumer cutover remains pending.
- Review cleanup restores 23 whitespace-only files to main, retains every test,
  trims duplicate documentation and limits layout diffs to actual state changes.
  CI formats changed Solidity files to avoid unrelated baseline churn; all other
  validation gates remain in place. Cleanup revalidation passed all 345 tests,
  artifact/layout/size checks and hygiene; coverage evidence remains `90297de`.

## 2026-09-01 — Fhenix reviewer documentation

- Replaced the stale root README with a Stage 16 system map that distinguishes
  private strategy evaluation, the public USDC FundVault, and optional
  confidential swaps.
- Added `FHENIX_REVIEW.md` as the compact repository entry point for Fhenix's
  permissioned-mainnet admission review. It inventories AlphaEngine-owned and
  inherited FHERC20 operations, hard bounds, permissions, custody boundaries,
  pinned dependencies, known limitations, and reproduction commands.
- Added contract-family READMEs for strategy, confidential swap, and FundVault
  modules, including lifecycle/sequence diagrams and focused test links.
- Reconciled terminology with `docs.alphaengine.trade` while treating current
  repository source as authoritative where public pages still describe the
  retired combined controller or pre-implementation guarded-vault design.
- Updated Fhenix review readiness to include the implemented vault stack in the
  repository behavior review while making clear that it has no FHE operations.
  No contract, ABI, deployment, storage layout, or test behavior changed.

## 2026-09-01 — Stage 16 Merkle-verified vault execution

- Implemented the immutable `AlphaEngineVaultExecutionManager` between exact
  Capital Manager approval and the FundVault's Stage 15 `executeBatch` surface.
  The execution manager cannot hold custody, mint/burn shares, process user
  entry/exit, or update vault accounting.
- Added delayed policy-root proposals bound to each executor and its reviewed
  artifact hash. Permissionless activation follows a 48-hour delay; an
  emergency guardian may revoke one executor's root to zero and pause the
  manager without installing replacement authority.
- Bound execution to the approved chain, managers, FundVault, trader,
  qualification version, executor, authorization nonce, validity window,
  policy root/version, ordered calls, sorted asset limits, risk-policy version,
  strategy payload, and evaluation evidence. Manager-local commitment and
  nonce replay markers supplement the Capital Manager's one-time consumption.
- Added live decoder/target code-hash proofs, fail-closed sanitization, exact
  approve/use/reset sequencing, post-call zero-allowance checks, per-execution
  spend and minimum-receive checks, and exact rolling 24-hour trader/asset
  spend caps. The rolling ledger aggregates same-block spend and fails closed
  after 64 distinct records until its oldest record expires.
- Added in-memory cumulative approval accounting so multiple nonzero approvals
  for one input asset cannot collectively exceed the exact committed spend
  limit, even though each approval is individually below that limit.
- Added focused unit/fuzz, stateful invariant, and real Capital Manager
  integration coverage. The handler independently models successful asset
  deltas and explicitly validates expected replay, proof, slippage, and cap
  failures without unchecked catches.
- The stateful model now separates entry, arbitrary holding-time advances, and
  later exit transactions. It independently tracks FundVault/strategy balances
  and exact rolling spend for both USDC and position tokens without assuming
  that deployment and yield realization are atomic.
- Focused validation passes 27 unit/fuzz tests, including 10,000 exact-delta
  cases and 9,973 accepted calldata-mutation cases. Four stateful invariants
  pass at 256 runs x depth 128 (131,072 aggregate calls) with zero handler
  reverts. The real Qualification Registry/Capital Manager integration passes.
  Targeted production coverage reaches 93.63% lines, 91.47% statements, 62.32%
  branches, and 100% functions for the execution manager.
- Stage 16 completed its owner-review checkpoint and is ready for its bounded
  commit. A separate owner-authorized checkpoint will run X-Ray first and the
  Solidity Auditor second against this committed SHA before Stage 17's pinned
  Pendle fork integration; neither security skill was run as part of Stage 16.
- Generated ABI/listener parity and runtime-size gates pass. The execution
  manager runtime is 17,933 bytes, below the repository's 23,000-byte limit.

## 2026-08-31 — Stage 15 immutable FundVault execution boundary

- Implemented the reserved `executeBatch` FundVault surface with a permanently
  one-time-linked execution manager, a 16-call cap, exact array validation,
  preflight contract checks, ordered return data, typed downstream failures,
  and transaction-wide rollback.
- Preserved selector-disjoint authority: only the USDC manager can mint/burn or
  settle entry/exit, while only the execution manager can invoke external
  batches. Batches reject the FundVault and every accounting, execution,
  ownership, emergency, and recovery control-plane address as a target.
- Added one-time emergency authority and recovery-vault configuration. Recovery
  is pause-only, transfers an entire ERC20 balance with an exact receipt check,
  cannot move FundVault shares, and permanently prevents the old vault from
  being unpaused after the first successful migration.
- Added focused unit/fuzz coverage and a stateful execution handler that checks
  successful effects against an independent ghost total, deliberately fails a
  later batch call to prove earlier effects roll back, and explicitly validates
  the expected typed failures without unchecked catches.
- The focused suite passes 12 unit/fuzz tests, including 10,000 fuzz cases. Four
  stateful invariants pass at 256 runs x depth 128 (131,072 aggregate calls)
  with zero handler reverts. The 43 existing accounting unit/fuzz tests and 10
  accounting invariants also remain green. Combined focused coverage reaches
  92.59% of FundVault lines and 100% of its functions; additional maximum-batch
  and invalid-authority/recovery branches were exercised afterward.
- Stage 15 completed owner review and is ready for its bounded stage commit.
  Merkle proofs, roots, capital consumption, replay, and risk limits remain
  exclusively Stage 16.

## 2026-08-31 — Stage 14 standard and Pendle RouterV4 decoders

- Added a deterministic `sanitize(bytes)` interface and separate immutable
  decoders for finite ERC20 approval/reset, standard ERC4626 entry/exit, and
  direct Pendle RouterV4 PT entry/unwind.
- ERC4626 `deposit`, `mint`, `withdraw`, and `redeem` require the FundVault as
  receiver and, for exits, owner. This reusable decoder does not enable any
  target until a reviewed target/code-hash leaf is included in a policy root.
- Replaced the stale Veda-POC Pendle assumption with official current evidence:
  `pendle-core-v2-public` commit `0fcebf79...`, Arbitrum RouterV4, and the live PT
  action facet at fixed block `500310277`.
- Pendle RouterV4 can remap selectors without changing router bytecode. The
  decoder therefore snapshots and rechecks router/facet code hashes and both
  live selector mappings, in addition to rejecting aggregators, limit orders,
  scaling, arbitrary recipients, zero amounts/minimums, invalid approximation,
  oversized/noncanonical calldata, and unsupported selectors.
- The focused suite passes 18 unit/fuzz tests, including three properties at
  10,000 runs each (30,000 randomized cases). Focused production coverage is
  100% for the ERC20 and Pendle decoders and above 90% for every ERC4626
  metric. Generated ABI parity and runtime-size checks also pass; the decoder
  runtimes are 487, 969, and 4,812 bytes respectively.
- The opt-in fixed-block fork test
  verifies both official PT selectors, router/facet code hashes, selector
  dispatch, constructor pins, and local ABI parity. Actual market/PT/USDC
  execution remains Stage 17 and no external deployment occurred.
- Exact dependency hashes, action restrictions, and remaining market-selection
  input are recorded in
  `docs/engineering/pendle-v4-dependency-action-matrix.md`.

## 2026-08-31 — Stage 13 deterministic Merkle policy primitives

- Added `AlphaEngineManageLeafHashLib` with the canonical V1 `abi.encode` leaf
  domain, fail-closed identity/code-hash/selector/native-value validation,
  sorted-pair hashing, and OpenZeppelin-compatible proof verification.
- Added `GenerateAlphaEngineManageRoot`, which sorts definitions by leaf hash,
  rejects duplicates and malformed metadata, carries odd nodes unchanged,
  generates every proof, and emits a deterministic flat-column review artifact
  containing aligned human-readable labels, leaf fields, tree layers, and proof
  offsets/nodes.
- Added a five-leaf reference artifact and dependency-free Python generator.
  The focused Foundry suite reproduces the artifact byte-for-byte and checks it
  against the independent implementation.
- Stage 13 intentionally adds no decoder/sanitizer, root-governance state,
  capital-consumption path, or FundVault call authority. Those remain Stages 14
  through 16.
- Local stage validation is intentionally focused on the new Merkle suite;
  all 13 tests pass, including three fuzz properties at 10,000 runs each
  (30,000 randomized cases). Complete-repository fuzzing and coverage remain
  final integration gates.

## 2026-08-31 — Stage 12 accounting invariant hardening

### Accounting decisions

- Round the linearly remaining locked profit upward so a nonzero positive-P&L
  tranche cannot become fully redeemable or fee-settle before its exact unlock
  timestamp.
- Performance-fee entitlement vests with feeable profit. A loss cancels the fee
  attributable to unvested feeable profit first; if it consumes the final
  locked unit, the surviving fee attributable to already vested profit is
  crystallized in the loss transaction rather than waived.
- Fee crystallization converts virtual matured fee supply into actual shares
  without changing deposit or redemption preview pricing.

### Tests and evidence

- Added exact `unlock - 1`, `unlock`, and `unlock + 1` formula vectors; loss at,
  below, and above the remaining-profit boundary; automatic prior-fee
  crystallization; exact fee-share checks; and fee-settlement price-neutrality
  coverage.
- Replaced self-referential accounting confidence with an independent stateful
  shadow model covering managed assets, locked/recovery profit, pending fees,
  loss recovery, vesting timestamps, actual/effective supply, and exact
  deposit/redemption previews across randomized deposit, redemption, P&L,
  liquidity, donation, time, and settlement sequences.
- Focused accounting validation passes 43 unit/fuzz tests and 10 invariants. The
  deep campaign passes at 256 runs × depth 128 (327,680 aggregate calls) with
  zero handler reverts. The full repository passes 226 tests.
- Production coverage passes with `DeployAlphaEngineV2` excluded from
  instrumentation: 91.68% lines, 91.18% statements, 66.99% branches, and
  99.51% functions repository-wide. `AlphaEngineUSDCVaultManager` reaches
  97.30% lines, 94.91% statements, 75.00% branches, and 100% functions.

## 2026-08-27 — Pendle decoder provenance requirement

- Do not assume that public Veda/BoringVault repositories contain a decoder or
  sanitizer compatible with the Pendle deployment AlphaEngine will use.
- At the start of Stage 14, resolve the target from official Pendle
  documentation and verified source, then record the chain, target/proxy and
  implementation addresses, code hashes, source revision, ABI hash, supported
  selectors, nested parameter layouts, and exact permitted-action matrix.
- Stage 14 must then implement AlphaEngine-owned, fail-closed Pendle PT
  decoder/sanitizers against those freshly pinned official interfaces. Public
  Veda decoders are structural references only, not compatibility evidence.
- Pendle ABI or implementation drift invalidates the affected policy artifact
  until decoder tests, code hashes, and Merkle leaves are reviewed and
  regenerated.

## 2026-08-27 — Deferred final-audit swap hardening TODOs

- Compared the fresh confidential swap path with baseline commit
  `49d96e8a80d6903d1d30affc6f836bcc0ac13800`; no core shield, unshield,
  lock, execute, settle, dust-return, or refund capability was identified as
  missing from the replacement architecture.
- Owner-directed deferral: record three non-standard-token/amount-domain
  hardening items for the consolidated Stage 18 security pass rather than
  interrupting FundVault implementation:
  1. exact-receipt enforcement or direct-path restriction for inherited public
     wrapper `shield(...)`;
  2. zero-value claim compatibility for ERC20s that reject
     `transfer(..., 0)`;
  3. an explicit supported-decimal or amount bound for Uniswap v4's signed
     `int128` delta domain.
- These are unresolved TODOs, not permanent risk acceptances. Until resolved,
  deployment configuration must allowlist reviewed exact-transfer assets with
  supported decimals.
- Stage 18 must pass the TODOs as known hypotheses into X-Ray, Fizz, Solidity
  Auditor, and external-audit scope. Candidate freeze requires remediation and
  regression tests or explicit final owner acceptance with documented
  deployment restrictions.
- Canonical details and acceptance conditions are recorded in
  `docs/engineering/strategy-manager-fund-vault-implementation-plan.md` under
  “Deferred confidential-swap hardening TODOs.” No Solidity or test behavior
  changed in this documentation-only update.

## 2026-08-27 — Stage 8 bound confidential swap controller

### Added
- `AlphaEngineConfidentialSwapController` as a fresh, initially paused
  transparent proxy with independent admin, pauser, operator, nonce, lifecycle,
  ABI, event, and storage domains.
- Atomic escrow/executor configuration validates the escrow's reciprocal
  controller pointer and the executor's authorized escrow caller before new
  submissions can be enabled.
- Each submission now pins the escrow, executor, input/output wrappers, opaque
  route key, execution-data hash, salted minimum-output commitment, deadline,
  canonical returned lock handle, unshield-request handle, and deterministic
  payload hash.
- Execution reveals committed calldata, minimum output, and salt. Any mutation
  fails before custody interaction; output wrapper and executor are read only
  from stored state. Refund remains permissionless after expiry or while either
  the controller or recorded escrow is paused.
- Added the dependency-free swap-payload hash vector, checked-in v2 controller
  ABI/storage layout, and generated-artifact/runtime-size gates.

### Security and test evidence
- Controller state is marked terminal before the external escrow call; any
  escrow/executor failure atomically restores controller and escrow replay
  state.
- Added exact typed tests for calldata/minimum/salt substitution, unauthorized
  execution, expiry, replay, downstream failure, initialized encrypted-zero
  cleanup, and event/getter parity.
- Added a seven-action combined controller/escrow invariant handler with no
  unchecked catches. Five stateful properties prove nonce exactness,
  payload/identity immutability, lifecycle/live-count parity, zero
  controller/executor custody, and non-vacuous execution/refund/mutation/replay
  coverage.
- Rewrote the twin-PoolManager differential suite to use only the fresh
  registry/gateway/controller/escrow/V4 path. Both directions retain exact
  output equality with the direct reference pool; an above-quote minimum
  reverts atomically.
- Extended the differential fixture to a non-1:1 USDC/WETH pool with 6/18
  decimals in both directions. Output above the wrapper's six-decimal
  confidential precision is split exactly into shielded units and sub-unit
  underlying dust returned directly to the original trader; the escrow keeps
  no remainder.
- Added a shallow-liquidity large-trade case proving that material PoolManager
  price impact below the committed minimum reverts and restores the controller
  and escrow lifecycle atomically.

### Validation
- Focused controller unit/fuzz suite: 15 passed, including 256 fuzz cases.
- Fresh-path PoolManager integration contains 6 cases. The 3 newly added
  volatile-pair and material-slippage cases passed together with the focused
  higher-decimal dust unit test; the full suite was not rerun at owner request.
- Combined controller/escrow invariant suite: 5 properties passed at 64 runs
  and depth 32 with zero handler reverts. The deep campaign also passed all 5
  properties at 256 runs and depth 128, totaling 163,840 randomized calls with
  zero handler reverts or discards.
- Coverage: 90.99% lines, 91.68% statements, 71.12% branches, and 99.05%
  functions repository-wide. The fresh controller reports 90.98% lines,
  91.93% statements, 75.86% branches, and 100% functions.
- Full repository: 308 tests passed, 0 failed, 0 skipped.
- Generated ABI/storage parity and runtime-size gates passed. The fresh
  controller runtime is 12,754 bytes, below the 23,000-byte ceiling.
- No external network deployment occurred. Stage 9 deployment and listener
  migration remain pending.

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

## 2026-08-27 — Stage 9 fresh deployment and listener migration

### Added

- Added `DeployAlphaEngineV2` for fresh, paused, unfunded local deployment of
  the five independent proxy domains plus the non-upgradeable asset and V4
  execution components.
- Added independent ProxyAdmins, exact chain/config/role validation, explicit
  post-deployment governance actions, reproducibility metadata, code hashes,
  historical-manifest binding, and the v2 manifest schema.
- Added deployment tests for paused defaults, reciprocal dependencies,
  independent administration, wrong-chain and invalid-code rejection,
  production role separation, deterministic admin actions, and manifest
  evidence.
- Added a dependency-free generated listener surface covering canonical
  function selectors, typed-error selectors, and event topics, plus the v2
  listener cutover runbook.

### Decisions

- Deployment validation and rehearsal remain local Foundry operations. No
  public testnet transaction is part of Stages 9–11.
- Deployment and post-verification governance configuration are separate: the
  deployment signer receives no hidden production authority.
- Retired the superseded mixed controller/vault Solidity, scripts, and test
  harnesses from the active tree after complete strategy/swap replacement.
  Preserve their legacy manifest, ABI, layouts, addresses, and Git history as
  immutable evidence.

### Validation

- `forge test --offline --match-path test/deployment/DeployAlphaEngineV2.t.sol`
- `python3 script/reference/alphaengine_listener_surface.py --check`
- Full Stage 10 integration gates remain the next bounded checkpoint.

## 2026-08-27 — Stage 10 first-pass integration validation

### Added

- Added focused V4 executor boundary tests for constructor dependencies,
  ownership, authorized-caller rotation, unauthorized execution, and common
  invalid execution inputs.
- Added a persistent Stage 10 validation record at
  `docs/releases/stage-10-first-pass-integration-validation.md`.
- Made the CI coverage command exclude only the separately tested deployment
  script/test from `--ir-minimum` instrumentation; production `src/**` remains
  instrumented.

### Validation

- Full suite: 173 passed, 0 failed.
- Release fuzz: six properties × 10,000 runs.
- Release invariants: five suites / 29 properties at 256 runs × depth 128.
- Coverage: 90.59% lines, 91.35% statements, 68.98% branches, 99.39% functions.
- ABI, storage-layout, selector/topic, runtime-size, formatting, repository
  hygiene, legacy-manifest integrity, and local deployment-rehearsal gates all
  passed.
- No public-network deployment and no consolidated security-skill audit were
  performed at this checkpoint.

## 2026-08-27 — Stage 11 first-pass implementation checkpoint

### Decisions

- Recorded `365b3e668217b1f1ca4caede9e6b8fb60526d430` as the
  exact first-pass StrategyManager/confidential-swap implementation SHA.
- Treat the SHA as a traceability and future-delta base only. It is not an
  external-audit freeze, tag, public deployment, or production-readiness claim.
- The eventual frozen audit candidate follows the USDC FundVault/Merkle pass,
  consolidated X-Ray and Solidity Auditor review, remediation, Fizz/final
  audit, production Fhenix validation, and release rehearsal.

### Added

- Added `docs/releases/first-pass-implementation-checkpoint.md` with exact
  source/tooling scope, legacy evidence, known limitations, and mutation rules.
- Updated the Fhenix audit-readiness package with the implemented contract
  names, first-pass evidence status, and remaining freeze conditions.

## 2026-08-27 — Stage 12 USDC FundVault accounting implementation

### Owner decisions

- Superseded the earlier daily deposit/withdrawal checkpoint design. USDC
  deposits now mint shares immediately at the current recognized rate.
- Redemptions are asynchronous and floating-price: shares are escrowed on
  request, and assets are calculated only when enough idle USDC is available
  for atomic completion. No fixed claim or reserve is created at request time.
- Positive reported P&L vests over a configurable period initialized to 24
  hours. Confirmed loss is immediate, cancels unvested gain first, and creates a
  recovery balance when recognized value falls below the prior high-water mark.
- Added a configurable, prospective performance fee capped at 20%. It applies
  only to net-new profit after unrecovered loss; the contract computes and mints
  fee shares after the relevant profit tranche finishes vesting.
- No deposit, redemption, or AUM fee is included.

### Added

- Added the non-upgradeable `AlphaEngineFundVault` USDC custody/share core with
  one-time USDC-manager authority, exact deposit balance-delta enforcement,
  escrowed redemption shares, atomic completion, fee-share minting, and paused
  exit liveness.
- Added `AlphaEngineUSDCVaultManager` with immediate deposits, asynchronous
  redemption request/cancel/complete, sequential finalized-block P&L reports,
  linear profit vesting, immediate loss/recovery accounting, prospective fee
  configuration, and direct-donation isolation.
- Added a zero-value terminal redemption path after total loss when the caller's
  minimum is zero; a nonzero minimum preserves price protection.
- Added focused unit/fuzz coverage and a `fail_on_revert = true` stateful handler
  with independent deposit, redemption, donation, deployment, managed-asset,
  profit, and loss ghost ledgers.

### Validation at implementation checkpoint

- Focused unit/fuzz suite: 37 passed, including four 256-run fuzz properties.
- Stateful invariant suite: 9 passed at 64 runs and depth 32 (18,432 aggregate
  calls, zero handler reverts).
- Full repository suite: 219 passed, 0 failed, 0 skipped.
- Formatting, generated ABI parity, runtime-size, repository-hygiene, and
  `git diff --check` gates passed. Runtime sizes are 4,613 bytes for the
  FundVault and 8,555 bytes for the USDC manager.
