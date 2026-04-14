# Architecture

## Purpose

`alphaengine-contracts` owns AlphaEngine’s Solidity entrypoint contracts and their upgrade, event, and storage semantics.

## Current shape

- `AlphaEngineIntentController` is the current TA / strategy-allocation intent entrypoint.
- `AlphaEngineConfidentialVault` is the approved next-phase custody boundary for confidential token wrappers, deposit/unshield flows, and vault-level swap-intent escrow locks.
- Transparent proxy pattern is canonical.
- Current intent families:
  - TA / strategy-allocation
  - confidential swap-intent locking
- One configured listener/operator address.
- TA lifecycle is submit + cancel.
- Swap lifecycle is submit + cancel with vault escrow lock/unlock only.
- Market selection is privacy-preserving in v1: the contract accepts and emits an encrypted `marketId` handle rather than a plaintext market address.

## External protocol boundary

`AlphaEngineIntentController` and `AlphaEngineConfidentialVault` must remain protocol-agnostic.

They must not import or directly depend on Uniswap, Pendle, Morpho, Aave, or other route-specific protocol ABIs. Swap intents are custody and lifecycle records at this layer, not a commitment to a concrete execution protocol.

Execution-specific contracts are separate future boundaries:
- a generic UEI executor may call arbitrary approved targets through decoded target/selector/calldata payloads;
- a Uniswap v4 executor may import canonical `v4-core` interfaces and implement the PoolManager unlock callback;
- Pendle, Morpho, Aave, or other typed adapters may be added only if there is a concrete safety or UX reason to avoid generic UEI calls.

`@uniswap/v4-core` is currently allowed as a Foundry fixture dependency for future pool behavior tests. It is not an `AlphaEngineIntentController` or vault dependency. `@uniswap/v4-periphery` remains out of scope unless a specific test-fixture blocker is documented.

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

For the current swap lock family, the listener-facing event shape is:
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

## Fhenix handling

V1 stores internalized encrypted handles only:
- one `bytes32` handle for `marketId`
- `bytes32[]` for strategy components
- one `bytes32` FHERC20 locked amount handle for swap-intent locks

The listener/operator receives access via contract-granted permissions and consumes emitted handles plus plaintext metadata (`timeframeKey`, deadline, nonce, payload hash).

For Foundry testing, this repo uses a local compatibility harness around the task-manager surface it actually relies on. That keeps production contracts pinned to current `cofhe-contracts` semantics while isolating upstream mock-wrapper lag as external integration debt rather than leaking it into production contract design.

## FHERC20 custody handling

The old hookathon `HybridFHERC20` pattern is a reference only, not production direction.

The confidential swap phase must use official Fhenix FHERC20 / confidential token contracts and keep an AlphaEngine vault as the custody boundary. The vault owns wrapper registration, deposit orchestration, unshield orchestration, and lock/settlement records; the official wrapper contract may hold the underlying ERC20 reserves after `shield(...)`. FHERC20 encrypted transfers can return an actual transferred encrypted value that differs from the requested encrypted value, including encrypted zero replacement. Vault lock state and swap-intent events must therefore use the actual returned handle as canonical.

Until Fhenix publishes official encrypted-amount unshield support, `AlphaEngineFHERC20ERC20Wrapper` carries a temporary `unshield(address from, address to, euint64 amount)` overload. This is an integration bridge for swap settlement only: it burns/requests unshield against the actual vault-held locked eUSDC handle and stores a claim for the returned actual unshield handle. Do not replace this with a direct release of underlying ERC20 based only on the pre-burn locked handle.

Current vault lock semantics are intentionally narrow:
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
- Vault rotation affects future swap submissions only because each `SwapIntentRecord` stores the vault used for that intent.
