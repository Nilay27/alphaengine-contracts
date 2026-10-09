# Fhenix, confidential-token, and custody policy

Load this policy for FHE/CoFHE, FHERC20, wrappers, confidential swaps, escrow,
or any custody path.

## FHE correctness

1. Use current CoFHE/FHE Solidity patterns; do not rely on deprecated `cofhejs`
   assumptions.
2. Handle internalization and all required permission grants are part of the
   correctness contract. Changes require synchronized tests and documentation.
3. Use official Fhenix FHERC20/confidential-token contracts.
4. When documentation and the installed pinned package disagree, the installed
   Solidity interface is authoritative and docs/tests must be updated together.
5. For `fhenix-confidential-contracts@v0.4.0`, the installed
   `confidentialTransferFrom(...)`, `sharedEuint64`, unique claim-ID and
   `setOperator(...)` surfaces are authoritative. Follow the documented
   CoFHE 0.2 migration rather than old bare-handle or `InEuint*` assumptions.
6. If Foundry mocks lack production parity, document the integration debt; do
   not downgrade production dependencies or switch the repository to Hardhat.

## Custody invariants

1. Intent and strategy lifecycle contracts never hold FHERC20 balances or
   underlying ERC20 reserves.
2. Custody, wrapper lifecycle, reserve accounting, locks, unlocks, burns,
   settlement credits, and refunds live behind a dedicated vault or escrow.
3. Swap input is locked in the confidential swap escrow, not the controller.
4. Atomic FHERC20 authorization-based locking stores the actual returned
   transferred handle as canonical. Never trust the requested encrypted amount
   as the amount received.
5. Do not reintroduce the hookathon `HybridFHERC20` into production.
6. Wrapper scope remains per underlying ERC20 unless an explicit reviewed
   architecture decision changes it.

## Required verification

Test permission grants, handle internalization, canonical returned-handle
storage, lock/cancel/consume/refund transitions, wrapper/reserve accounting,
cross-wrapper settlement, dust atomicity, and zero residual executor balances.
