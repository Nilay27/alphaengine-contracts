# Architecture

## Purpose

`alphaengine-contracts` owns AlphaEngine’s Solidity entrypoint contracts and their upgrade, event, and storage semantics.

## V1 shape

- `AlphaEngineIntentController` is the only production contract.
- Transparent proxy pattern is canonical in v1.
- One intent family only: TA / strategy-allocation.
- One configured listener/operator address.
- Lifecycle is submit + cancel.

## Boundaries

This repo owns:
- contract ABI
- events
- storage layout
- deployment and upgrade scripts
- Solidity tests, fuzzing, and invariants

This repo does not own:
- listener bootstrap or polling
- off-chain decrypt logic
- strategy codec packing
- simulation or ranking
- AVS/middleware registration in v1

## Listener contract

`listener-service` must consume this repo’s emitted event and getter contract, not hookathon ABI. Event compatibility is a release gate.

## Fhenix handling

V1 stores internalized encrypted component handles only as `bytes32[]`. The listener/operator receives access via contract-granted permissions and consumes emitted handles plus metadata.

For Foundry testing, this repo uses a local compatibility harness around the task-manager surface it actually relies on. That keeps production contracts pinned to current `cofhe-contracts` semantics while isolating upstream mock-wrapper lag as external integration debt rather than leaking it into production contract design.
