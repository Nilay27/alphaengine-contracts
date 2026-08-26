# Testing Strategy

## Canonical framework

Foundry is the only framework in v1.

CI is pinned to Foundry `v1.7.1`. The PR workflow runs the complete suite at
the default fuzz/invariant profile; nightly and release-candidate workflows use
at least 10,000 fuzz runs and 256 invariant runs at depth 128. GitHub Actions
and the Foundry setup action are pinned by full commit SHA.

## Required suites

- Hash vectors: `AlphaEngineHashLibrariesTest` compares Solidity against the
  dependency-free Python reference in
  `script/reference/alphaengine_hash_vectors.py`, mutates every strategy and
  execution-commitment field, and exercises fail-closed call/risk bounds.

- Unit: initialization, strategy submit/cancel/admin flows, swap submit/admin/execute/refund flows, vault lock and settlement/refund flows, revert paths, event/state parity.
- Unit tests must assert encrypted market-handle persistence, encrypted amount-handle persistence, and access grants in submit paths.
- Integration: twin-pool direct-vs-intent reference swaps using `PoolSwapTest` on one pool and `submitSwapIntent -> executeSwapIntent` on an identical second pool.
- Fuzz (legacy baseline): nonce monotonicity, intent-id uniqueness, component-count bounds, unauthorized strategy-cancellation rejection, shared strategy/swap nonce progression, cross-family strategy-cancellation isolation, swap execution/refund status transitions, and strategy-state isolation across swap execution/refund. The fresh contracts replace the shared-nonce cases with independent competition, capital, and swap nonce-domain tests.
- Invariant: cancelled strategy intents stay cancelled, shared strategy/swap nonce exactness, non-zero listener operator after valid initialization, configured-vault validity, configured swap-executor validity, controller/vault lock parity across submit and execute, cross-family handle isolation, vault wrapper stability, vault lock lifecycle, consumed-lock claim consistency, cross-wrapper reserve backing, exact output-mint accounting, dust-settle revert atomicity, executor zero-residual accounting, and vault reserve/accounting conservation.
- Confidential swap/vault tests cover vault custody, wrapper creation, deposit/unshield, auto-lock plus auto-unshield transitions, canonical FHERC20 returned-handle handling, and accounting parity before any broader custody path ships.
- The detailed invariant ledger is `docs/engineering/invariant-ledger.md`; update it before changing state machines, custody flows, or accounting rules.

### Implemented replacement-manager suites

- Qualification Registry tests cover grant, extension, expiry, revocation,
  requalification, version monotonicity, role separation, and paused rescue
  behavior.
- Competition Manager tests cover schedules, bounded confidential submissions,
  encrypted evaluation permissions, unique bounded ranks, complete
  finalization, deterministic eligibility, trader-level qualification
  publication, role-gated rank pagination, asynchronous score readiness, and
  post-finalization public retrieval of all three score components.
- Capital Manager tests cover active-version submission, exact execution-field
  mutation, immutable approval, rejection/cancellation/revocation/expiry,
  allowlisted consumption, replay markers, downstream rollback, explicit
  event/getter parity, and zero custody.
- `AlphaEngineCapitalStrategyManager.invariant.t.sol` runs ten randomized
  actions with zero handler reverts and asserts seven stateful properties:
  submission-nonce exactness, payload/component consistency, terminal-state
  monotonicity, approval/authorization-nonce immutability, replay-state parity,
  stale-qualification rejection, and zero native custody.

### Implemented Stage 7 confidential-asset suites

- Registry tests cover owner initialization, wrapper creation, precision
  capping, append-only underlying/wrapper bijection, external-wrapper surface
  validation, duplicate rejection, and zero/non-contract inputs.
- Gateway tests cover exact shielding, zero residual custody/allowance,
  registered-wrapper enforcement, ordinary asynchronous unshield claims,
  decimal-rate bounds, and fee-on-transfer rejection at both transfer
  boundaries.
- Escrow unit/fuzz tests cover fresh paused initialization, separated admin and
  pauser authority, controller/registry rotation only while paused with no live
  locks, canonical FHERC20 returned handles, immediate encrypted unshield,
  above-balance encrypted-zero cleanup, uninitialized-account dependency
  behavior, permissionless preclaim reconciliation, exact settlement,
  pause-safe refund, independent minimum-output enforcement, fee-on-transfer
  output rejection, and exact higher-decimal output decomposition into shielded
  units plus trader-returned dust.
- `AlphaEngineConfidentialSwapEscrow.invariant.t.sol` runs seven randomized
  action families through ten selectors and asserts eight properties:
  immutable registry/configuration, lock/live-count parity, exact permitted
  residual custody for preclaims, independent input/output conservation,
  wrapper reserve backing, confidential-supply holder parity,
  claimed-input/failed-settlement lifecycle consistency, and non-vacuous action
  coverage. Expected-success actions propagate reverts; the sole intentional
  failure action checks the exact error selector and full rollback.

### Implemented Stage 8 bound-swap suites

- Controller unit/fuzz tests cover fresh paused initialization, separated
  admin/pauser/operator authority, atomic reciprocal escrow/executor
  configuration, registered input/output wrappers, deterministic identifiers,
  nonce exactness, canonical lock-handle persistence, and event/getter parity.
- Reveal tests mutate execution calldata, minimum output, and salt independently
  and require exact typed failures with controller/escrow rollback. Successful
  settlement proves terminal replay rejection, executor/escrow zero residuals,
  permissionless expiry/pause refunds, initialized encrypted-zero cleanup, and
  downstream-failure atomicity.
- `AlphaEngineConfidentialSwapController.invariant.t.sol` randomizes seven
  action families with no swallowed failures and proves five combined
  properties: nonce exactness, payload/identity immutability, controller/escrow
  lifecycle parity, zero controller/executor custody, and non-vacuous execution,
  refund, mutation, and replay coverage.
- The twin-PoolManager integration suite now runs exclusively through the fresh
  controller, fresh escrow, registry/gateway, and V4 executor. Both swap
  directions match the independent direct reference output exactly. It also
  covers a non-1:1 USDC/WETH pool with 6/18 decimals in both directions,
  encryptable-output/dust conservation, and a shallow-liquidity large trade
  whose price impact breaches the committed minimum and rolls all controller
  and escrow state back.

### Planned USDC FundVault suites

- Formula-lock tests must independently verify net-liquidation NAV,
  external-flow-neutral P&L, 18-decimal share conversion against `1e6` virtual
  USDC units and `1e18` virtual share units, rounding direction, 24-hour
  positive-P&L vesting, and immediate loss offset.
- Stateful invariants must cover share-supply conservation, pending-deposit and
  withdrawal-reserve segregation, no pre-checkpoint yield capture, zero manager
  custody, and disjoint FundVault selector authority.
- Execution invariants must prove that no unproved call or replay succeeds and
  that strategy execution cannot spend pending deposits or reserved withdrawal
  USDC.
- Integration tests must cover USDC deposit through checkpoint settlement,
  gain/loss reporting, withdrawal price/reserve/settlement, and an exact capital
  approval through Merkle verification into a pinned Pendle PT action.

## Coverage

- `forge coverage` is mandatory.
- Target is 100% coverage for repo-owned logic-bearing contracts and libraries.
- Exclusions: interfaces, mocks, scripts, vendored dependencies, proxy boilerplate.
- Checked-in ABIs and upgradeable storage layouts must reproduce byte-for-byte
  after canonical JSON normalization via
  `script/ci/check-generated-artifacts.sh`.
- Coverage uses `--skip DeployAlphaEngineV2` because the large Foundry script
  and its dedicated deployment test are outside production coverage scope and
  trigger a solc Yul stack-depth defect under `--ir-minimum`. The script remains
  compiled normally and is tested separately; production `src/**` remains fully
  instrumented.

## Fhenix policy

- Prefer current Fhenix mock contracts if they work cleanly in Foundry.
- Do not introduce a Hardhat test harness in v1.
- Current v1 implementation uses a repo-owned mock task manager and helper harness for the exact contract surface in use:
  - `verifyInput`
  - `allow`
  - `isAllowed`
  - `createDecryptTask` with caller-permission enforcement and request tracking
  - deterministic `trivialEncrypt`, arithmetic, comparison, and `select` operations needed by official FHERC20 wrapper tests
  - decrypt-result publication and reverting verification semantics for wrapper claim tests
  - deterministic mock-value lookup for stored handles
- The submit-path assertions cover both encrypted `marketId` handle semantics and encrypted strategy component handle semantics.
- If upstream mock parity is incomplete, keep Foundry canonical and document the missing integration gap explicitly.
- Assert handle-access grants against the current `bytes32` handle semantics from the pinned CoFHE Solidity package.

## Confidential swap/vault policy

- Use official Fhenix FHERC20 / confidential token behavior as the target surface; do not test against a revived hookathon `HybridFHERC20`.
- Unit tests must cover one wrapper per underlying ERC20, deposit/shield, withdraw/unshield request/claim, atomic swap lock plus immediate encrypted-amount unshield request, actual swap settlement, and output confidential credit/mint.
- Deposit/shield tests must assert exact `rate()` multiples and reject fee-on-transfer or other balance-drift behavior.
- Controller/vault integration tests must assert the intent controller never receives token custody, validates configured vault identity, and stores the canonical FHERC20 returned transfer handle.
- Controller swap-intent tests must verify the user's `InEuint64`, grant the vault handle access, and then lock through `lockForSwapIntent(...)` with the verified `euint64`.
- `routeKey` tests remain limited to event/state parity; the concrete route execution is passed in executor-specific calldata rather than decoded from `routeKey`.
- Failure-path tests must cover invalid token, missing wrapper, duplicate lock, unauthorized vault calls, expired deadline, refund-unavailable before expiry, and zero or invalid returned lock/unshield result where detectable.
- Insufficient confidential balance must be tested as an initialized encrypted
  zero result, not modeled as an ERC20-style revert. Its verified zero refund
  must terminate the live record. A truly uninitialized account retains the
  dependency's typed zero-balance failure.
- Stateful handlers must exercise a permissionless wrapper claim before both
  terminal paths. Escrow residual underlying is permitted only when it equals
  the exact underlying attributable to live preclaimed locks.
- Fuzz tests must cover submit/execute ordering, wrapper uniqueness, nonce and intent ID uniqueness, token accounting bounds, and invalid ordering.
- Deterministic integration tests must prove that, for identical initial pool state and no AlphaEngine fee, the intent execution path returns exactly the same `tokenOut` as a direct `PoolSwapTest` exact-input swap.
- Invariant tests must assert submitted swap intents immediately enter
  `UnshieldRequested`, executed swap intents transition to `Consumed`, refunded
  swap intents transition to `Refunded`, cross-family intent isolation holds,
  wrapper mappings remain stable, escrow underlying is zero except for exact
  live preclaims, each wrapper reserve stays backed by confidential supply plus
  unclaimed pending units, terminal refund/settlement removes the attributable
  escrow custody, higher-decimal output equals shielded units times the wrapper
  rate plus dust returned to the trader, and reserve/accounting never goes
  negative.
- Cross-asset escrow invariants keep input consumption and output credit in
  separate ghost ledgers. They do not assume equal token units or derive AMM
  prices; the implemented Stage 8 differential PoolManager tests own
  execution-price parity.
- PoolManager swap execution tests now live behind the dedicated executor boundary and must continue to avoid importing Uniswap into the controller or vault.

## External protocol fixture policy

- `@uniswap/v4-core` is allowed for Foundry-only executor fixtures, direct `PoolSwapTest` reference swaps, and the separately-approved executor boundary.
- Production strategy-manager, swap-controller, and swap-escrow tests must not
  require those contracts to import Uniswap, Pendle, Morpho, Aave, or any
  other route-specific protocol ABI.
- If Uniswap v4 becomes the first concrete execution route, write the PoolManager behavior tests against a dedicated executor/harness, not by embedding PoolManager logic into the intent controller or vault.
- `@uniswap/v4-periphery` remains excluded unless a specific fixture setup blocker is documented; do not add it speculatively.
- The pinned `v4-core@v4.0.0` PoolManager implementation uses `pragma solidity 0.8.26`; this repo now pins `solc = 0.8.26` so future PoolManager fixture work must preserve that compiler profile unless explicitly approved and documented.
