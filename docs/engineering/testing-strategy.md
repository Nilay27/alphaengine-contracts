# Testing Strategy

## Canonical framework

Foundry is the only framework in v1.

## Required suites

- Unit: initialization, strategy submit/cancel/admin flows, swap submit/admin/execute flows, vault lock and settlement flows, revert paths, event/state parity.
- Unit tests must assert encrypted market-handle persistence, encrypted amount-handle persistence, and access grants in submit paths.
- Integration: twin-pool direct-vs-intent reference swaps using `PoolSwapTest` on one pool and `submitSwapIntent -> executeSwapIntent` on an identical second pool.
- Fuzz: nonce monotonicity, intent-id uniqueness, component-count bounds, unauthorized strategy-cancellation rejection, shared strategy/swap nonce progression, cross-family strategy-cancellation isolation, swap execution status transitions, and strategy-state isolation across swap execution.
- Invariant: cancelled strategy intents stay cancelled, shared strategy/swap nonce exactness, non-zero listener operator after valid initialization, configured-vault validity, configured swap-executor validity, controller/vault lock parity across submit and execute, cross-family handle isolation, vault wrapper stability, vault lock lifecycle, consumed-lock claim consistency, cross-wrapper reserve backing, exact output-mint accounting, dust-settle revert atomicity, executor zero-residual accounting, and vault reserve/accounting conservation.
- Confidential swap/vault tests cover vault custody, wrapper creation, deposit/unshield, auto-lock plus auto-unshield transitions, canonical FHERC20 returned-handle handling, and accounting parity before any broader custody path ships.
- The detailed invariant ledger is `docs/engineering/invariant-ledger.md`; update it before changing state machines, custody flows, or accounting rules.

## Coverage

- `forge coverage` is mandatory.
- Target is 100% coverage for repo-owned logic-bearing contracts and libraries.
- Exclusions: interfaces, mocks, scripts, vendored dependencies, proxy boilerplate.

## Fhenix policy

- Prefer current Fhenix mock contracts if they work cleanly in Foundry.
- Do not introduce a Hardhat test harness in v1.
- Current v1 implementation uses a repo-owned mock task manager and helper harness for the exact contract surface in use:
  - `verifyInput`
  - `allow`
  - `isAllowed`
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
- Failure-path tests must cover invalid token, missing wrapper, duplicate lock, unauthorized vault calls, expired deadline, and zero or invalid returned lock/unshield result where detectable.
- Fuzz tests must cover submit/execute ordering, wrapper uniqueness, nonce and intent ID uniqueness, token accounting bounds, and invalid ordering.
- Deterministic integration tests must prove that, for identical initial pool state and no AlphaEngine fee, the intent execution path returns exactly the same `tokenOut` as a direct `PoolSwapTest` exact-input swap.
- Invariant tests must assert submitted swap intents immediately enter `UnshieldRequested`, executed swap intents transition to `Consumed`, cross-family intent isolation holds, wrapper mappings remain stable, vault confidential escrow is zero after auto-unshield, each wrapper reserve stays backed by confidential supply plus pending unshield units, cross-wrapper settlement mints exact output units, dust-amount settlement attempts revert without partial consumption, and reserve/accounting never goes negative.
- PoolManager swap execution tests now live behind the dedicated executor boundary and must continue to avoid importing Uniswap into the controller or vault.

## External protocol fixture policy

- `@uniswap/v4-core` is allowed for Foundry-only executor fixtures, direct `PoolSwapTest` reference swaps, and the separately-approved executor boundary.
- Production `AlphaEngineIntentController` and `AlphaEngineConfidentialVault` tests must not require either contract to import Uniswap, Pendle, Morpho, Aave, or any other route-specific protocol ABI.
- If Uniswap v4 becomes the first concrete execution route, write the PoolManager behavior tests against a dedicated executor/harness, not by embedding PoolManager logic into the intent controller or vault.
- `@uniswap/v4-periphery` remains excluded unless a specific fixture setup blocker is documented; do not add it speculatively.
- The pinned `v4-core@v4.0.0` PoolManager implementation uses `pragma solidity 0.8.26`; this repo now pins `solc = 0.8.26` so future PoolManager fixture work must preserve that compiler profile unless explicitly approved and documented.
