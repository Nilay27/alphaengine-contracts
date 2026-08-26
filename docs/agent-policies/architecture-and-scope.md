# Contract architecture and scope policy

Load this policy for controllers, strategy managers, intent lifecycles, naming,
module separation, and architecture planning.

## Repository ownership

This repository owns Solidity contracts, deployment scripts, Solidity tests,
ABIs, manifests, and contract-facing documentation. It does not own listener
bootstrap logic, off-chain simulation/ranking, or SDK packing semantics.

## Current and approved boundaries

1. The current testnet implementation combines strategy-allocation and
   confidential-swap lifecycles. The approved direction separates them as
   documented in `docs/engineering/strategy-swap-separation-plan.md`.
2. Preserve behavior during the separation. Each family receives independent
   controller/manager storage, nonce domain, pause state, ABI, events, and
   lifecycle invariants.
3. Do not add result posting, arbitrary execution, batching, leverage, LP
   accounting, or new settlement behavior merely to complete the split.
4. Listener-facing getters and events must not assume hookathon or future UEI
   execution families.

## Swap boundary

1. The swap controller owns submission and terminal execution/refund lifecycle.
2. The confidential swap escrow owns wrappers, shield/unshield operations,
   per-intent locks, settlement, output shielding, refunds, and reserves.
3. The V4 swap executor remains a separate protocol-specific adapter and must
   retain zero residual balances.
4. Controllers and custody contracts remain protocol-agnostic. Generic UEI and
   protocol adapters are future, separately reviewed boundaries.
5. Batching is outside the first swap implementation.

## Scope controls

1. Invalid intent inputs fail loudly, including zero market/timeframe/operator,
   past deadlines, invalid component counts, unauthorized cancellation, and
   invalid initialization.
2. Additional deposit, withdrawal, lock, unlock, consume, settlement, batching,
   or execution paths require explicit architecture documentation and tests in
   the same change set.
3. Do not leave dead AVS or middleware logic commented in production code.
4. AlphaEngine is EigenCompute-operated in v1. EigenLayer registration,
   middleware plumbing, and operator registries are out of scope.
5. If scope changes, update the architecture plan and development log before or
   with implementation.
