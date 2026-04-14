# Confidential Swap + Vault Architecture

## Purpose

This document defines the next AlphaEngine contracts phase after the current TA / strategy-allocation controller: confidential token custody, swap-intent locking, and a later settlement path.

This is an architecture contract for implementation. Any production change must keep the repo's upgrade, coverage, fuzzing, invariant, and listener-compatibility rules intact.

## Locked Decisions

- Use Fhenix official FHERC20 / confidential token contracts for encrypted token behavior.
- Do not revive or fork the old hookathon `HybridFHERC20` design.
- Add an AlphaEngine-owned upgradeable vault layer for custody and accounting.
- Keep swap intent submission in `AlphaEngineIntentController`.
- Keep confidential token custody orchestration in `AlphaEngineConfidentialVault` and its registered wrapper contracts.
- Scope vault-managed confidential wrappers per underlying ERC20, not per pool or market.
- Use atomic authorization-based locking for swap intents.
- Do not implement batching in the first swap-intent phase.
- Do not add Uniswap hook logic in this repo phase.
- Keep the intent controller and vault protocol-agnostic; neither contract may import Uniswap, Pendle, Morpho, Aave, or route-specific protocol ABIs.
- Treat `@uniswap/v4-core` as a future Foundry pool-fixture / separately-approved executor dependency only, not as part of the swap-intent controller surface.

## Contract Split

`AlphaEngineIntentController` owns:

- intent IDs, nonces, statuses, deadlines, and listener-facing events;
- current TA / strategy-allocation submit and cancel lifecycle;
- current `submitSwapIntent(...)` entrypoint;
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

Official `FHERC20ERC20Wrapper.shield(...)` transfers underlying ERC20 into the wrapper contract and mints confidential balance there. Therefore "vault custody" means AlphaEngine-owned orchestration and registry control over vault-managed wrappers; it does not mean the upgradeable vault address must physically retain all underlying ERC20 balances after shielding.

Future swap executor integration owns:

- settlement routing after listener/operator decision;
- output accounting handoff back into the vault.

The executor boundary may take one of two forms:

- a generic UEI executor that calls approved targets from decoded target/selector/calldata payloads, matching the direction of the old hookathon `SwapManager` UEI path;
- a protocol-specific executor, such as a Uniswap v4 executor that imports canonical `v4-core` interfaces and owns `PoolManager.unlock(...)` / `PoolManager.swap(...)` handling.

Either executor path must be introduced only after vault custody and locking invariants are covered. It must not move protocol-specific imports into `AlphaEngineIntentController` or `AlphaEngineConfidentialVault`.

## Atomic Authorization Locking Flow

1. User approves and deposits an ERC20 through `AlphaEngineConfidentialVault`.
2. Vault deploys or reuses the FHERC20 wrapper for that underlying asset.
3. Vault delegates to the official FHERC20 wrapper, which receives the underlying ERC20 and credits the user with confidential balance in that wrapper.
4. User calls `AlphaEngineIntentController.submitSwapIntent(...)` once.
5. The submit call includes the input wrapper, an opaque `routeKey`, encrypted input amount data, and the FHERC20 authorization material required for delegated encrypted transfer.
6. Intent controller computes `intentId`.
7. Intent controller calls `AlphaEngineConfidentialVault.lockForSwapIntent(...)`.
8. Vault calls official FHERC20 delegated encrypted transfer from user to vault escrow.
9. Vault stores the FHERC20-returned actual transferred encrypted handle as canonical for the lock.
10. In the same transaction, vault immediately calls the temporary encrypted-amount `unshield(...)` overload against that locked handle and stores the returned actual unshield request handle.
11. Intent controller stores the swap-intent record and emits `SwapIntentSubmitted` with both the canonical locked handle and the canonical unshield request handle.

The returned transferred handle is mandatory because FHERC20 can preserve privacy by returning an encrypted zero transfer instead of reverting when a requested confidential transfer exceeds balance. Any swap path that needs plaintext-dependent settlement must use a later decrypt / reveal phase and must not assume the requested amount was actually locked.

In the current controller/vault implementation, `submitSwapIntent(...)` verifies the user's `InEuint64` input while `msg.sender` is still the user, grants the vault handle access, and only then calls the vault with the resulting `euint64`. The vault must not verify user encrypted inputs on behalf of the controller because that would bind verification to the controller/vault caller rather than the original user.

`routeKey` remains intentionally opaque after the first concrete Uniswap v4 executor was added. It allows an off-chain route or template registry to evolve without committing the controller or vault to a route-specific ABI. The current `AlphaEngineV4SwapExecutor` consumes explicit execution data; `routeKey` remains metadata, not an on-chain route decoder.

Do not treat `routeKey` as a Uniswap-specific field. It can later resolve to a generic UEI execution template, a Uniswap route, or another approved protocol adapter. That resolution belongs outside the current intent controller/vault state machine.

The currently pinned `fhenix-confidential-contracts@v0.3.1` tag exposes `confidentialTransferFrom(...)`, `setOperator(...)`, and `euint64` token amounts. The public FHERC20 docs mention a newer `encTransferFrom(...)` / permit-oriented flow, but that surface is not present in the latest verified tag at this step. Until Fhenix publishes a compatible tagged release, implementation must target the installed package and treat any permit-specific API as unverified.

The official installed `FHERC20ERC20Wrapper.unshield(...)` only accepts a plaintext `uint64` amount. For encrypted swap intents, a plaintext-only unshield surface forces an extra intermediate decrypt step. AlphaEngine therefore carries a temporary wrapper overload:

```solidity
unshield(address from, address to, euint64 amount) returns (euint64 actualUnshieldHandle)
```

This overload exists only as an integration bridge while Fhenix reviews adding official encrypted-amount unshield support. It must be removed or delegated to the official wrapper surface once upstream support lands.

The vault deposit path must not silently accept the wrapper's default rounding behavior. Amounts must be exact multiples of the wrapper `rate()`, and fee-on-transfer or balance-drift behavior must revert instead of leaving wrapper reserves undercollateralized.

## Cancel And Settlement Semantics

Cancellation:

- applies to strategy intents only in the current implementation;
- does not apply to swap intents because swap submit now auto-requests unshield in the same transaction;
- must not be reintroduced for swap intents unless the vault lifecycle is redesigned around claim refund or re-shield refund semantics.

Refund:

- is a terminal rescue path for swap intents, not a user-cancel path;
- only applies once the swap is already live and either the deadline has passed or the system is paused;
- must verify and claim the stored `unshieldRequestHandle`, then re-shield the recovered underlying back into the original input wrapper for the original submitter;
- must not route through the swap executor.

Settlement:

- only applies to active submitted swap intents whose vault lock is already `UnshieldRequested`;
- must prove and act on the actual returned unshield/burn handle, not just the originally requested encrypted input;
- currently finalizes by verifying the actual unshield handle, claiming underlying into vault custody, executing through a separately configured executor, and shielding the output token back to the submitter;
- must not directly release underlying ERC20 based only on the stored locked handle before proving the actual unshield handle.

Batching:

- is explicitly out of scope for the first swap version;
- may later operate over existing vault lock records without moving custody into the intent controller.

## Testing Requirements

Unit tests must cover:

- wrapper creation and stable lookup per underlying ERC20;
- deposit / shield and withdraw / unshield accounting;
- atomic submit + lock integration between controller and vault;
- canonical locked-handle event/state parity;
- actual settlement through a dedicated executor boundary, including claim, exact-input swap, and output confidential credit;
- every access-control and invalid-state revert path.

Fuzz tests must cover:

- lock, execute, and consume/finalize state transitions;
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

Current gap:

- stateful invariant coverage still focuses on submit-side accounting and pre-execution lock relationships;
- execute-time route/output invariants must be added in a later step now that the concrete executor path exists.

Fhenix mock policy:

- use the best current Foundry-compatible official mock path when it matches pinned production contracts;
- keep local harnesses narrow when upstream mock parity lags;
- document any remaining FHERC20 mock gap in `docs/development-log.md`;
- never downgrade production dependencies to make stale mocks pass.

## Deferred Work

- Final swap route-key semantics and any execution-template mapping.
- Final FHERC20 permit API verification if Fhenix publishes a newer tagged package.
- Vault deployment and upgrade scripts.
- Generic UEI executor and/or protocol-specific executor architecture.
- Deeper PoolManager execution invariants and swap-output vector tests through the separate executor boundary.
- Batch matching and operator settlement.
- AVS or EigenLayer middleware registration.
