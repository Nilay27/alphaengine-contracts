# Testing Strategy

## Canonical framework

Foundry is the only framework in v1.

## Required suites

- Unit: initialization, submit/cancel/admin flows, revert paths, event/state parity.
- Unit tests must assert encrypted market-handle persistence and access grants in the submit path.
- Fuzz: nonce monotonicity, intent-id uniqueness, component-count bounds, unauthorized cancellation rejection.
- Invariant: cancelled intents stay cancelled, handle-count parity, nonce monotonicity, non-zero listener operator after valid initialization.

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
  - deterministic mock-value lookup for stored handles
- The submit-path assertions cover both encrypted `marketId` handle semantics and encrypted strategy component handle semantics.
- If upstream mock parity is incomplete, keep Foundry canonical and document the missing integration gap explicitly.
- Assert handle-access grants against the current `bytes32` handle semantics from the pinned CoFHE Solidity package.
