# Development Log

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
- `AlphaEngineConfidentialVault.unlockSwapIntent(...)` for controller-only refund to the original locked account.
- `AlphaEngineConfidentialVault.consumeSwapIntentLock(...)` for controller-only logical consume / non-refundable settlement marker.
- `AlphaEngineConfidentialVault.getSwapIntentLock(...)` for deterministic lock-state inspection.
- Swap lock events:
  - `SwapIntentLocked`
  - `SwapIntentUnlocked`
  - `SwapIntentLockConsumed`
- Unit tests for lock, unlock, consume, unauthorized callers, zero IDs, zero account, unregistered wrapper, duplicate locks, inactive lock states, invalid returned handles, and paused behavior.

### Decisions
- Lock storage was added append-only as a new mapping and the vault storage gap was reduced by one slot.
- The vault accepts a verified `euint64` requested amount handle, not an `InEuint64` user input.
- The future intent controller must verify the user's `InEuint64` while `msg.sender` is still the user, grant the vault access to the resulting handle, and then call the vault.
- The vault stores the FHERC20-returned actual transfer handle as canonical.
- Unlock refunds only the original locked account and remains available while paused.
- Consume currently marks the escrow lock as `Consumed`; it does not burn, unshield, route through PoolManager, or mint output confidential tokens yet.

### Next Steps
- Wire `submitSwapIntent(...)` in `AlphaEngineIntentController` to verify user encrypted amount input and call the vault lock path atomically.
- Add controller/vault integration tests for swap-intent submission, cancellation unlock, and status parity.
- Add fuzz and invariant coverage for vault lock state transitions before adding PoolManager settlement.
