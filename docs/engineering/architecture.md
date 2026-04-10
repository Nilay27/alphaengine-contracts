# Architecture

## Purpose

`alphaengine-contracts` owns AlphaEngine’s Solidity entrypoint contracts and their upgrade, event, and storage semantics.

## Current shape

- `AlphaEngineIntentController` is the current TA / strategy-allocation intent entrypoint.
- `AlphaEngineConfidentialVault` is the approved next-phase custody boundary for confidential token wrappers, deposit/unshield flows, and vault-level swap-intent escrow locks.
- Transparent proxy pattern is canonical.
- One intent family only: TA / strategy-allocation.
- One configured listener/operator address.
- TA lifecycle is submit + cancel.
- Market selection is privacy-preserving in v1: the contract accepts and emits an encrypted `marketId` handle rather than a plaintext market address.

## Next phase: confidential swap vault

The approved next architecture phase is documented in `docs/engineering/confidential-swap-vault-architecture.md`.

Locked boundaries for that phase:
- swap intent submission remains in `AlphaEngineIntentController`
- confidential token custody and accounting move to `AlphaEngineConfidentialVault`
- official Fhenix FHERC20 / confidential token contracts are the token behavior target
- wrappers are scoped per underlying ERC20
- vault-managed wrapper contracts may physically hold underlying ERC20 reserves because official `FHERC20ERC20Wrapper.shield(...)` transfers underlying into the wrapper contract
- atomic FHERC20 authorization-based locking is the submit-time custody path
- the intent controller must never hold FHERC20 balances or underlying ERC20 reserves
- batching, AVS registration, and hook logic remain out of scope for the first swap-intent version

## Boundaries

This repo owns:
- contract ABI
- events
- storage layout
- deployment and upgrade scripts
- Solidity tests, fuzzing, and invariants
- confidential vault contract semantics once that next phase is implemented

This repo does not own:
- listener bootstrap or polling
- off-chain decrypt logic
- strategy codec packing
- simulation or ranking
- AVS/middleware registration in v1
- client SDK encryption UX

## Listener contract

`listener-service` must consume this repo’s emitted event and getter contract, not hookathon ABI. Event compatibility is a release gate.

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

## Fhenix handling

V1 stores internalized encrypted handles only:
- one `bytes32` handle for `marketId`
- `bytes32[]` for strategy components

The listener/operator receives access via contract-granted permissions and consumes emitted handles plus plaintext metadata (`timeframeKey`, deadline, nonce, payload hash).

For Foundry testing, this repo uses a local compatibility harness around the task-manager surface it actually relies on. That keeps production contracts pinned to current `cofhe-contracts` semantics while isolating upstream mock-wrapper lag as external integration debt rather than leaking it into production contract design.

## FHERC20 custody handling

The old hookathon `HybridFHERC20` pattern is a reference only, not production direction.

The confidential swap phase must use official Fhenix FHERC20 / confidential token contracts and keep an AlphaEngine vault as the custody boundary. The vault owns wrapper registration, deposit orchestration, unshield orchestration, and lock/settlement records; the official wrapper contract may hold the underlying ERC20 reserves after `shield(...)`. FHERC20 encrypted transfers can return an actual transferred encrypted value that differs from the requested encrypted value, including encrypted zero replacement. Vault lock state and swap-intent events must therefore use the actual returned handle as canonical.

Current vault lock semantics are intentionally narrow:
- `lockForSwapIntent(...)` is callable only by the configured intent controller.
- The caller must pass a controller-verified `euint64` amount handle that has already been allowed to the vault.
- `unlockSwapIntent(...)` refunds to the original locked account and is allowed while the vault is paused so cancellation/refund remains available.
- `consumeSwapIntentLock(...)` marks the lock as consumed and non-refundable; burn, unshield, PoolManager execution, and output confidential credit are not implemented yet.
