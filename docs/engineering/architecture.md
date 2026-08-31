# Architecture

## Purpose

`alphaengine-contracts` owns AlphaEngine’s Solidity entrypoint contracts and their upgrade, event, and storage semantics.

## Current shape

- The active source tree contains independent competition, capital, confidential
  swap, asset registry/gateway, escrow, and protocol-specific executor domains.
- The superseded `AlphaEngineIntentController` and
  `AlphaEngineConfidentialVault` implementations and tests have been retired
  from the active tree. Their immutable manifest, ABI, layouts, addresses, and
  Git history remain historical/drain-down evidence; they are never an upgrade
  or storage base for v2.
- `AlphaEngineV4SwapExecutor` is the current separately bounded Uniswap v4 execution adapter.
- Stages 7 and 8 implement the replacement `AlphaEngineConfidentialAssetRegistry`,
  `AlphaEngineConfidentialAssetGateway`, and
  `AlphaEngineConfidentialSwapEscrow`, plus the bound
  `AlphaEngineConfidentialSwapController`; they are locally tested but not
  externally deployed.
- Stage 9 adds fresh paused deployment, independent ProxyAdmin, v2 manifest,
  delayed-governance action, ABI/topic snapshot, and listener-cutover tooling.
- Transparent proxies are canonical for the five stateful first-pass domains;
  registry, gateway, wrapper, and swap executor remain non-upgradeable.
- Competition, capital, and confidential swap use independent lifecycles,
  nonces, roles, operators, events, ABIs, and pause domains.
- Swap lifecycle is submit -> execute or refund.
- Market selection is privacy-preserving in v1: the contract accepts and emits an encrypted `marketId` handle rather than a plaintext market address.

No Stage 9 repository command broadcasts to a public chain. Deployment tests
and rehearsals use Foundry's ephemeral local EVM.

## Approved target architecture

The canonical target is defined by
`docs/engineering/strategy-manager-fund-vault-implementation-plan.md`:

- `AlphaEngineCompetitionStrategyManager` owns competition scheduling,
  encrypted submissions, evaluations, rankings, and eligibility publication.
- `AlphaEngineTraderQualificationRegistry` owns versioned, expiring,
  trader-level qualification and revocation.
- `AlphaEngineCapitalStrategyManager` accepts fresh encrypted intents from
  qualified traders and owns exact, one-time capital authorizations.
- `AlphaEngineConfidentialSwapController` and
  `AlphaEngineConfidentialSwapEscrow` are an independently deployable product.
- `AlphaEngineFundVault`, `AlphaEngineUSDCVaultManager`, and
  `AlphaEngineVaultExecutionManager` form the separate second-pass fund system:
  the FundVault holds assets and shares, the USDC manager handles public
  deposit/asynchronous-redemption and P&L accounting, and the execution manager
  owns Merkle-verified deployment policy.
- Competition and capital share interfaces and stateless hashing libraries,
  never a storage-bearing base manager.

Implemented shared boundary:

- `AlphaEngineStrategyHashLib` defines independent identifier domains and
  encrypted strategy-payload commitments.
- `AlphaEngineExecutionHashLib` defines ordered calls, sorted risk limits,
  execution commitments, and bound swap minimum-output commitments.
- The qualification, capital-consumption, vault-manager, and FundVault
  interfaces define call direction without granting authority by themselves.

Implemented replacement contracts through Stage 8:

- `AlphaEngineTraderQualificationRegistry` is the canonical versioned,
  expiring, revocable trader-qualification source.
- `AlphaEngineCompetitionStrategyManager` owns independent competition
  scheduling, confidential submissions, evaluation/ranking, finalization, and
  qualification publication. After finalization, a dedicated score-revealer
  role can request asynchronous CoFHE decryption of all three evaluation-score
  handles in bounded rank-order batches. The manager stores no duplicate
  plaintext score state; its public getter reads verified results from the
  CoFHE task manager and returns an independent readiness flag for each score.
- `AlphaEngineCapitalStrategyManager` accepts a fresh confidential intent only
  at an active qualification version, records one independent encrypted
  evaluation, and may approve only one exact execution commitment.
- Only a governance-allowlisted execution-manager contract may consume an
  approval. Consumption is one-time and atomic with downstream execution; the
  Capital Manager cannot hold assets or call strategy targets.
- These are fresh proxy domains. They do not reinterpret or migrate the legacy
  combined controller's storage.
- `AlphaEngineConfidentialAssetRegistry` is an append-only, non-upgradeable
  wrapper/underlying registry. It may create or validate a wrapper, but cannot
  hold user balances or participate in settlement.
- `AlphaEngineConfidentialAssetGateway` pins one registry and exposes ordinary
  deposit/shield and request/claim-unshield convenience calls. Exact balance
  deltas reject fee-on-transfer behavior, approvals reset to zero, and the
  gateway retains no underlying token after a successful call.
- `AlphaEngineConfidentialSwapEscrow` is a fresh, initially paused transparent
  proxy domain. It owns only temporary FHERC20 locks, immediate encrypted
  unshield requests, exact settlement/refund accounting, and controller/registry
  configuration guarded by a zero-live-lock requirement.
- The new escrow removes the dead legacy `Unlocked` state, stores the actual
  FHERC20 returned transfer handle as canonical, permits refunds while paused,
  and independently enforces output balance, minimum output, wrapper-rate
  divisibility, wrapper reserve deltas, and zeroed wrapper approvals.
- Privacy-preserving insufficient-balance transfers can return initialized
  encrypted zero. The escrow therefore permits a verified zero-value refund to
  terminate the record without executing or re-shielding zero.
- Wrapper claims are permissionless but pay the claim's fixed recipient. If a
  claim is executed before the controller's settlement/refund transaction, the
  escrow verifies the exact claim and consumes the already-received underlying
  rather than attempting a second claim and stranding the lock.
- `AlphaEngineConfidentialSwapController` is a fresh, initially paused
  transparent proxy domain with independent admin, pauser, operator, nonce,
  status, event, and ABI state. It atomically configures an escrow/executor pair
  whose reciprocal caller surfaces match.
- Each fresh swap submission pins its escrow, executor, input/output wrappers,
  opaque route key, execution-data hash, salted minimum-output commitment,
  deadline, canonical locked handle, and unshield-request handle. The operator
  reveals but cannot substitute execution calldata, output wrapper, executor,
  or minimum output.
- Controller state is marked terminal before escrow interaction and rolls back
  atomically if settlement fails. Refund remains permissionless after expiry or
  while either the controller or recorded escrow is paused. The controller
  never receives confidential or underlying token custody.

## External protocol boundary

The new swap controller/escrow boundaries must remain protocol-agnostic.

They must not import or directly depend on Uniswap, Pendle, Morpho, Aave, or other route-specific protocol ABIs. Swap intents are custody and lifecycle records at this layer, not a commitment to a concrete execution protocol.

Execution-specific contracts are separate boundaries:
- arbitrary calls are prohibited outside the Merkle-verified FundVault manager
  boundary;
- the implemented `AlphaEngineV4SwapExecutor` imports canonical `v4-core` interfaces and implements the PoolManager unlock callback;
- the first FundVault policy is limited to pinned Pendle PT actions through
  fail-closed decoders/sanitizers; generic routers, borrowing, leverage, flash
  loans, and bridges remain excluded.

`@uniswap/v4-core` is pinned for Foundry pool behavior tests and the separately bounded V4 executor. It is not an intent-controller or custody-contract dependency. `@uniswap/v4-periphery` remains out of scope unless a specific test-fixture blocker is documented.

## Superseded pre-audit separation

The earlier refactor is retained in
`docs/engineering/strategy-swap-separation-plan.md` for history. Its single
strategy-controller recommendation is superseded by the current implementation
plan.

Locked target boundaries:
- strategy submission, cancellation, and evaluation-score state belong to a strategy-intent controller
- individual-user swap submission, execution, and refund state belong to a confidential-swap controller
- confidential swap locking, unshielding, settlement, and refund custody belong to a transient swap escrow
- official Fhenix FHERC20 / confidential token contracts are the token behavior target
- wrappers are scoped per underlying ERC20
- swap-module wrapper contracts may physically hold underlying ERC20 reserves because official `FHERC20ERC20Wrapper.shield(...)` transfers underlying into the wrapper contract
- atomic FHERC20 authorization-based locking is the submit-time custody path
- neither intent controller may hold FHERC20 balances or underlying ERC20 reserves
- `AlphaEngineFundVault` exclusively owns long-lived fund custody and the share ledger
- `AlphaEngineUSDCVaultManager` owns immediate USDC-only public deposits,
  floating-price asynchronous redemptions, daily P&L/share-price accounting,
  configurable positive-yield vesting, immediate loss recognition/recovery,
  and a bounded prospective performance fee; nonzero profit remains locked
  until the exact unlock timestamp, and a loss that ends a vest crystallizes
  only the fee entitlement already earned by vested feeable profit
- the future `AlphaEngineVaultExecutionManager` owns Merkle roots, exact execution authorization, risk caps, and protocol-call orchestration
- the USDC manager and execution manager receive disjoint FundVault selector authority and cannot substitute for one another
- the FundVault accounting path never reuses the swap escrow's accounting or lifecycle state
- batching, AVS registration, hook logic, LP accounting, and new swap behavior remain out of scope for the separation

## Boundaries

This repo owns:
- contract ABI
- events
- storage layout
- deployment and upgrade scripts
- Solidity tests, fuzzing, and invariants
- confidential swap escrow semantics
- future pooled LP vault semantics only after a separate approved design

This repo does not own:
- listener bootstrap or polling
- off-chain decrypt logic
- strategy codec packing
- simulation or ranking
- AVS/middleware registration in v1
- client SDK encryption UX

## Listener contract

`listener-service` must consume this repo’s emitted event and getter contract, not hookathon ABI. Event compatibility is a release gate.

For the replacement capital family, the backend must index the versioned
`ABI/v2/AlphaEngineCapitalStrategyManager.json` surface. It can retain the same
basic decrypt-then-simulate workflow, but it must read the fresh contract
address and new capital event family rather than treating a competition
qualification as an execution approval. `CapitalIntentSubmitted` and
`CapitalIntentComponents` provide the encrypted market/component handles and
stable payload metadata. The evaluator then records encrypted scores and
either rejection evidence or the exact execution commitment. Consumption is a
separate terminal event.

For competition leaderboards, the backend must treat
`CompetitionScoreRevealRequested` as a decryption-request signal, not as proof
that plaintext is already available. It should poll
`getPublicEvaluationScores(submissionId)` or consume the CoFHE result events and
check each readiness flag. The getter rejects access until the competition is
finalized. No aggregate-score field is added; the public scoring formula may
derive the leaderboard total from the three revealed components.

For the current TA family, the listener-facing event shape is:
- `intentId`
- `submitter`
- `marketIdHandle`
- `timeframeKey`
- `componentHandles`
- `deadline`
- `payloadHash`
- `submitterNonce`

`listener-service` must decrypt `marketIdHandle` into plaintext `marketId` and resolve that identifier through the shared AlphaEngine market registry. The contract must not attempt to own or expose a plaintext `marketId -> market address` mapping in v1.

For the legacy swap lock family, the listener-facing event shape is:
- `intentId`
- `submitter`
- `inputWrapper`
- `confidentialVault`
- `routeKey`
- `lockedAmountHandle`
- `unshieldRequestHandle`
- `deadline`
- `payloadHash`
- `submitterNonce`

`routeKey` is intentionally opaque in this step. It is the current placeholder for off-chain route semantics and must not be treated as a complete PoolManager execution template.

For the fresh v2 swap family, `ConfidentialSwapSubmitted` exposes the stored
identity and custody fields, while `ConfidentialSwapExecutionCommitted`
exposes `executionDataHash` and `minimumOutputCommitment`. The listener can keep
the same event/getter workflow, but must use the fresh controller address and
ABI. Execution accepts only a reveal whose calldata hash and salted minimum
commitment match the stored values.

The minimum is enforced against total measured output before wrapper precision
conversion. When an output wrapper caps an 18-decimal underlying at six
confidential decimals, the escrow shields `output - (output % rate)` and sends
`output % rate` directly to the original trader. `SwapSettlementDustReturned`
exposes that exact reconciliation, and the escrow retains no output dust.

## Fhenix handling

V1 stores internalized encrypted handles only:
- one `bytes32` handle for `marketId`
- `bytes32[]` for strategy components
- one `bytes32` FHERC20 locked amount handle for swap-intent locks

The listener/operator receives access via contract-granted permissions and consumes emitted handles plus plaintext metadata (`timeframeKey`, deadline, nonce, payload hash).

For Foundry testing, this repo uses a local compatibility harness around the task-manager surface it actually relies on. That keeps production contracts pinned to current `cofhe-contracts` semantics while isolating upstream mock-wrapper lag as external integration debt rather than leaking it into production contract design.

## FHERC20 custody handling

The old hookathon `HybridFHERC20` pattern is a reference only, not production direction.

The confidential swap phase uses official Fhenix FHERC20 / confidential token
contracts. In the replacement path, the registry owns append-only wrapper
associations, the gateway owns ordinary user shield/unshield orchestration, and
the escrow owns temporary swap locks and settlement/refund records. Official
wrapper contracts physically hold the underlying ERC20 reserves after
`shield(...)`. FHERC20 encrypted transfers can return an actual transferred
encrypted value that differs from the requested encrypted value, so escrow lock
state and future swap-controller events use the actual returned handle as
canonical.

Until Fhenix publishes official encrypted-amount unshield support, `AlphaEngineFHERC20ERC20Wrapper` carries a temporary `unshield(address from, address to, euint64 amount)` overload. This is an integration bridge for swap settlement only: it burns/requests unshield against the actual vault-held locked eUSDC handle and stores a claim for the returned actual unshield handle. Do not replace this with a direct release of underlying ERC20 based only on the pre-burn locked handle.

Fresh controller/escrow semantics are intentionally narrow:
- the controller atomically configures a reciprocal escrow/executor pair while
  paused, and every intent stores the pair used at submission;
- `submitSwapIntent(...)` verifies the user's `InEuint64` while `msg.sender` is
  still the user, grants the recorded escrow access, and immediately locks and
  requests unshield through that escrow;
- the record additionally binds the output wrapper, exact execution-data hash,
  and salted minimum-output commitment;
- `executeSwapIntent(...)` is swap-operator-only and reveals, rather than
  chooses, the committed data and minimum output; and
- `refundSwapIntent(...)` is permissionless only after expiry or while the
  controller/recorded escrow is paused.

The following older pointer names describe only the legacy drain-down path:
- `setConfidentialVault(...)` validates that the configured vault is a contract and that its `intentController()` points back to this controller.
- `submitSwapIntent(...)` verifies the user's `InEuint64` amount while `msg.sender` is still the user, grants the vault access, and then locks through the vault.
- `lockForSwapIntent(...)` is callable only by the configured intent controller.
- The caller must pass a controller-verified `euint64` amount handle that has already been allowed to the vault.
- `lockForSwapIntent(...)` now performs the FHERC20 transfer and then immediately calls the temporary encrypted-amount unshield overload in the same transaction.
- After a successful swap submit, the vault lock is already in `UnshieldRequested` state and records both the actual returned locked handle and the actual returned unshield request handle.
- Swap intent submission is therefore final in the current architecture; there is no user-cancel path for swap intents.
- Expired or pause-blocked live swaps may still take the terminal `refundSwapIntent(...)` rescue path, which claims the pending unshield handle and re-shields the recovered underlying back into the original input wrapper for the original submitter.
- `executeSwapIntent(...)` is listener-operator-only and routes through the recorded vault plus a separately configured executor boundary.
- `settleSwapIntent(...)` on the vault claims the actual unshield handle, transfers exact underlying input into the executor, receives output underlying back to vault custody, and shields output confidential balance to the original submitter.
- `AlphaEngineV4SwapExecutor` is the first concrete executor boundary and is the only contract that imports `v4-core` in the current swap path.
- Vault rotation affects future legacy swap submissions only because each legacy `SwapIntentRecord` stores the vault used for that intent.
