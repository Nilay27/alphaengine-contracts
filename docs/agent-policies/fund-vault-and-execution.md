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
   approval, expiry, and replay state.
5. `AlphaEngineFundVault` owns pooled custody, deployed positions, and the ERC20
   share ledger. It exposes disjoint role-gated entry/exit and `manage`
   selectors; it does not calculate NAV or accept public requests.
6. `AlphaEngineUSDCVaultManager` owns the initial USDC-only public deposit,
   withdrawal, checkpoint pricing, daily NAV report, positive-P&L vesting, and
   immediate-loss lifecycle. It is not a custodian and cannot manage positions.
7. `AlphaEngineVaultExecutionManager` owns Merkle policy, exact capital
   authorization consumption, risk limits, replay, and fund deployment. It
   cannot mint/burn shares, settle users, or report NAV.
8. The initial release uses USDC as both deposit asset and accounting unit. It
   does not require a multi-asset Teller/Accountant stack or deposit-conversion
   oracle.

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
5. Strategy execution cannot consume pending-deposit principal or USDC reserved
   for priced withdrawals.
6. The NAV reporter is separate from execution authority. Positive P&L vests
   over 24 hours; confirmed loss is recognized immediately and offsets
   unvested gain first.

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
