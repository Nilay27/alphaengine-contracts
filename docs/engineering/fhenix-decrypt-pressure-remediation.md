# Fhenix decrypt-pressure remediation

Findings 2–4 from review of `0595ef4`, following the
[CoFHE 0.2 / FHERC20 0.4 migration](cofhe-v020-migration.md).

## Admission and completion

| Flow | Controls |
|---|---|
| Swap/controller | 120/trailing minute, refill 2/s, burst 24; one active/trader; per-input-wrapper minimum; verified zero refund starts a five-minute trader cooldown |
| Partial unshield/wrapper | One pending/source/wrapper across both overloads; registry-wide ordinary budget initially 1/s, burst 8; per-wrapper minimum; verified zero single/batch claim starts a five-minute source cooldown |
| Full unshield/wrapper | Caller-only `unshieldAll(recipient)` snapshots the full encrypted balance, including dust; same pending/budget gates; five-minute cooldown from admission; verified zero completion restarts it |
| Score reveal/manager | All three scores; at most 8 submissions/24 handles; five-second interval across competitions; forward-only per-competition cursor |

Plaintext partial withdrawals below minimum revert before FHE work. Encrypted
partial withdrawals and swaps add `gte`/`select` plus trivial constants to mask
below-minimum requests to zero before burn/transfer. No eligibility decrypt is
added. Actual transfer/burn handles remain authoritative: insufficient balance
resolves to zero without spending funds. The first invalid decrypt remains
possible; cooldowns start only after verified zero completion (plus admission
for full exits), and always apply to the recorded source/trader.

Claims, settlement and refunds never consume admission credit. Third-party claims
remain supported. The registry holds no assets; the escrow retains swap custody.
Only the registry's configured escrow calling to burn its own balance bypasses
ordinary withdrawal gates, using controller admission instead. Full exits exclude
later deposits and remain available before minimum configuration.

## Configuration and consumer contract

- Set positive `setWrapperMinimums(wrapper, swapMinimum, unshieldMinimum)` values
  explicitly. Unconfigured policies block new swaps/partial exits. Values use
  confidential base units: 1,000,000 means 1 token for a six-decimal wrapper,
  including WETH. Select economic minimums per asset; no decimal-based defaults
  or oracle. Policy changes never recheck existing claims/locks.
- `setUnshieldRateLimits` accepts refill 1–16/s and burst from refill through 128.
  It accrues at the old rate and clamps existing credit; updates do not refill
  for free. Production registry ownership requires a timelock. Separate budgets
  reserve withdrawal capacity but do not guarantee fairness against many accounts.
- Wrappers require an explicit registry constructor argument; external registration
  checks the binding, underlying, rate and claim-ID surface. Review external
  bytecode separately. Full exits emit `FullBalanceUnshieldRequested` with the
  unique claim ID; returned shares are transaction-scoped. Handle typed cooldown/
  admission errors and their next-available timestamps.
- Score calls require `startRank == scoreRevealedThrough(id) + 1`, batch 1–8 and
  time at least `nextScoreRevealAt`. The cursor records authorization, not result
  readiness. Publishers retry authorized handles independently. Full competition:
  32 batches, 768 scores, at least 155 seconds first-to-last authorization plus
  network latency. Qualification does not wait for public results.
- New proxy state consumes declared gaps; existing fields/hash domains are
  preserved. Use fresh v2 deployment and drain historical claims/locks; in-place
  adoption with untracked active intents or historical reveal ranges is unsupported.
  Regenerate SDK/listener consumers from the updated ABIs before cutover.

## Scope and validation

Inherited `requestDiscloseEncryptedAmount` and holders' direct Task Manager
`allowGlobal` permissions remain available. These controls bound protocol claim
creation and manager score authorization, not all shielding, transfers, private
or public decrypts. Repeated ACL grants do not establish repeated computation of
cached results. Rates are provisional; real CoFHE integration/throughput remains
a deployment gate. The plaintext harness does not prove production signatures,
ciphertext metadata parity, threshold-network capacity or completion latency.

### Validation

- 345 tests, including 40 invariant properties / 81,920 calls / zero handler
  reverts. Coverage at implementation commit `90297de`: 93.42% lines, 93.11% statements, 73.65% branches, 99.28%
  functions; 336 coverage tests use the existing `--ir-minimum --skip
  DeployAlphaEngineV2` workaround. Nine deployment tests pass in the normal suite.
- Cases include amount boundaries, forged results, single/batch/preclaims,
  source/recipient identity, shared escrow concurrency, registry binding,
  cross-wrapper budgets, prospective policy changes, dust/later deposits,
  cursor/replay/pacing rollback and full 256-submission pagination.
- ABI/listener/layout/hash-vector/size/hygiene checks pass. Layout comparisons
  ignore compiler AST IDs while retaining field order, types, slots and offsets.
  PR formatting checks cover changed Solidity files. Tests and contract behavior
  are preserved by the subsequent whitespace/documentation cleanup.
