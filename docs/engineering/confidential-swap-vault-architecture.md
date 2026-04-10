# Confidential Swap + Vault Architecture

## Purpose

This document defines the next AlphaEngine contracts phase after the current TA / strategy-allocation controller: confidential token custody, swap-intent locking, and a later settlement path.

This is an architecture contract before implementation. Any production change must keep the repo's upgrade, coverage, fuzzing, invariant, and listener-compatibility rules intact.

## Locked Decisions

- Use Fhenix official FHERC20 / confidential token contracts for encrypted token behavior.
- Do not revive or fork the old hookathon `HybridFHERC20` design.
- Add an AlphaEngine-owned upgradeable vault layer for custody and accounting.
- Keep swap intent submission in `AlphaEngineIntentController`.
- Keep all confidential token and underlying ERC20 custody in `AlphaEngineConfidentialVault`.
- Scope vault-managed confidential wrappers per underlying ERC20, not per pool or market.
- Use atomic permit-based locking for swap intents.
- Do not implement batching in the first swap-intent phase.
- Do not add Uniswap hook logic in this repo phase.

## Contract Split

`AlphaEngineIntentController` owns:

- intent IDs, nonces, statuses, deadlines, and listener-facing events;
- current TA / strategy-allocation submit and cancel lifecycle;
- future `submitSwapIntent(...)` entrypoint;
- orchestration call into the vault to lock swap input.

`AlphaEngineIntentController` must not own:

- FHERC20 balances;
- underlying ERC20 reserves;
- pool swap execution state;
- wrapper deployment or token accounting.

`AlphaEngineConfidentialVault` owns:

- accepted underlying ERC20 registry;
- FHERC20 wrapper creation and lookup, one wrapper per underlying ERC20;
- deposit / shield flow from ERC20 into confidential balance;
- withdraw / unshield flow from confidential balance back to ERC20;
- swap-intent escrow locks keyed by `intentId`;
- cancellation unlocks and settlement consume/burn behavior;
- output confidential mint/credit after settlement.

Future swap executor integration owns:

- settlement routing after listener/operator decision;
- `PoolManager.unlock(...)` and `PoolManager.swap(...)` calls;
- output accounting handoff back into the vault.

The swap executor path must be introduced only after vault custody and locking invariants are covered.

## Atomic Permit Locking Flow

1. User deposits an ERC20 into `AlphaEngineConfidentialVault`.
2. Vault deploys or reuses the FHERC20 wrapper for that underlying asset.
3. Vault credits the user with confidential balance in that wrapper.
4. User calls `AlphaEngineIntentController.submitSwapIntent(...)` once.
5. The submit call includes encrypted input amount data and FHERC20 permit data required for delegated encrypted transfer.
6. Intent controller computes and stores `intentId`.
7. Intent controller calls `AlphaEngineConfidentialVault.lockForSwapIntent(...)`.
8. Vault calls official FHERC20 permit-based encrypted transfer from user to vault escrow.
9. Vault stores the FHERC20-returned actual transferred encrypted handle as canonical for the lock.
10. Intent controller emits the swap-intent event with the canonical locked handle, not just the requested encrypted amount.

The returned transferred handle is mandatory because FHERC20 can preserve privacy by returning an encrypted zero transfer instead of reverting when a requested confidential transfer exceeds balance. Any swap path that needs plaintext-dependent settlement must use a later decrypt / reveal phase and must not assume the requested amount was actually locked.

## Cancel And Settlement Semantics

Cancellation:

- only applies before a lock is consumed;
- changes intent status in `AlphaEngineIntentController`;
- calls the vault to unlock/refund the escrowed confidential input;
- must not burn the locked input.

Settlement:

- only applies to active locked intents;
- consumes the vault lock exactly once;
- burns or otherwise accounts for the locked input according to the official FHERC20 integration surface;
- uses underlying vault reserves for the real swap path;
- credits or mints output confidential balance to the user after the output asset is received.

Batching:

- is explicitly out of scope for the first swap version;
- may later operate over existing vault lock records without moving custody into the intent controller.

## Testing Requirements

Unit tests must cover:

- wrapper creation and stable lookup per underlying ERC20;
- deposit / shield and withdraw / unshield accounting;
- atomic submit + lock integration between controller and vault;
- canonical locked-handle event/state parity;
- cancellation unlock and settlement consume paths;
- every access-control and invalid-state revert path.

Fuzz tests must cover:

- lock, cancel, unlock, and consume state transitions;
- wrapper uniqueness per underlying asset;
- nonce and intent ID uniqueness;
- token accounting bounds;
- invalid or adversarial lock ordering.

Invariant tests must cover:

- locked intents never double-consume;
- consumed locks never unlock;
- cancelled locks never settle;
- wrapper mapping is stable per underlying ERC20;
- vault escrow records remain consistent with intent status;
- reserve and escrow accounting never go negative.

Fhenix mock policy:

- use the best current Foundry-compatible official mock path when it matches pinned production contracts;
- keep local harnesses narrow when upstream mock parity lags;
- document any remaining FHERC20 mock gap in `docs/development-log.md`;
- never downgrade production dependencies to make stale mocks pass.

## Deferred Work

- Full `submitSwapIntent(...)` ABI and event shape.
- Official FHERC20 package installation and exact import/interface verification.
- Vault deployment and upgrade scripts.
- PoolManager integration.
- Batch matching and operator settlement.
- AVS or EigenLayer middleware registration.
