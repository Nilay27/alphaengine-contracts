# FundVault and Merkle-verified execution policy

Load this policy for pooled capital, trader execution, Veda/BoringVault,
Merkle-root policy, decoder/sanitizer, or capital-strategy architecture.

## Boundary

1. `AlphaEngineFundVault` is a separate future pooled-capital subsystem. It
   never reuses confidential-swap escrow locks, swap nonces, or transient swap
   settlement accounting.
2. Competition evidence may qualify a trader; it does not whitelist a strategy
   or automatically authorize capital.
3. Qualified traders submit fresh encrypted capital intents. Each intent is
   evaluated independently before any vault action.
4. The strategy/capital manager owns encrypted submission, evaluation,
   approval, expiry, and replay state. The FundVault owns pooled custody and
   execution constraints.

## Merkle execution controls

1. A Merkle policy constrains permitted targets, selectors, value behavior, and
   decoder/sanitizer-extracted address arguments. It does not replace economic
   risk, sizing, expiry, or per-intent approval.
2. Every vault call batch must bind to one approved, unexpired, unconsumed
   execution commitment covering chain, vault, intent, targets, calldata,
   values, nonce, and deadline.
3. Consume the authorization atomically with successful execution and reject
   replay or mismatched call bundles.
4. Traders do not receive an unrestricted arbitrary-call vault role. Apply
   least privilege and separate operator, evaluator, root-admin, pause, and
   upgrade authorities.

## Second-pass reference

Use `/Users/nilay/yieldfi/veda-poc` only as a design reference, particularly:

- `src/StrategyWithMerkleVerification.sol`;
- `src/BoringVault.sol`;
- `src/DecodersAndSanitizers/**`;
- `resources/BaseMerkleRootGenerator.sol`;
- `test/StrategyWithMerkleVerification.t.sol`.

Do not import or copy the POC in the first Fhenix pass. Before second-pass reuse,
pin an exact clean revision, compare it with current official Veda contracts,
review licensing and dependencies, define AlphaEngine-specific invariants, and
complete a separate security and external-audit scope.
