# Fhenix decrypt-pressure remediation

Scope: complete findings 2–4 from review of `0595ef4`, following the CoFHE 0.2 /
FHERC20 0.4 migration. No network deployment is included.

## Final behavior and ownership

| Flow | Admission | Amount rule | Completion |
|---|---|---|---|
| Swap/controller | Existing 120/trailing minute, refill 2/s, burst 24; one active/trader; reject during zero-result cooldown | Registry minimum per input wrapper; `gte` + `select` masks smaller requested amounts to zero before escrow transfer | Verified zero refund releases active slot and starts five-minute trader cooldown; valid settlement/refund unchanged |
| Partial unshield/wrapper | One pending/source/wrapper; five-minute zero-result cooldown; registry-wide ordinary budget initially 1/s, burst 8 | Plaintext rejects below minimum; encrypted overload masks below minimum before burn | Single or batch claim verifies actual burn, pays nonzero underlying, clears pending; zero starts source cooldown |
| Full unshield/wrapper | Same pending/cooldown/ordinary budget; caller-only full exits spaced at least five minutes | Entire encrypted balance at request time; explicit exception to partial minimum, including unconfigured policy | Existing claim pays even during cooldown; later deposits remain confidential; zero completion restarts cooldown |
| Score reveal/competition manager | Role and finalization gate; global five-second interval; at most 8 submissions/call | All three existing scores, rank order | Per-competition revealed-through cursor advances atomically, with no repeated or skipped ranks; result readiness remains separate |

Cooldown starts only after verified zero completion for ordinary requests and
swaps. Full exits additionally start it on admission. It is fixed, never an
escalating punishment or permanent ban. Above-balance burns remain all-or-nothing:
zero is burned and the existing balance is retained. Requests from other accounts
are independent; global admission bounds remain necessary against many accounts.
No admission budget is charged again on claim, execution or refund.

Minimum masking adds a `gte` and a `select`, plus constant trivial encryptions,
to each swap and ordinary encrypted unshield. Plaintext withdrawals avoid the
redundant encrypted comparison. No additional eligibility decryption is added.
The existing actual-transfer/burn ciphertext remains the authoritative value.
Invalid requests can still consume their first decryption. A minimum is a valid
spend policy, not proof that every admitted request will transfer funds.

The asset registry owns canonical wrapper identity, per-wrapper amount policy
and the ordinary-withdrawal admission bucket. It holds no assets. The swap
controller owns swap admission/cooldown and the escrow remains the custodian.
The trusted escrow exemption requires the registry's configured escrow to call
the wrapper and burn its own balance; ordinary callers/operators cannot select
the exempt path.

## Units and configuration

Call `setWrapperMinimums(wrapper, swapMinimum, unshieldMinimum)` explicitly for
each reviewed asset. Both values must be positive. There is no decimal-derived
default. New swaps and partial exits reject unconfigured policies; full exits
remain available for users already holding tokens. Minimum changes are
prospective: effective amounts are determined at request time and completion
never rechecks a newer minimum.

All minimums use confidential wrapper units. A six-decimal USDC wrapper maps
1,000,000 units to 1 USDC. A six-decimal WETH wrapper also maps 1,000,000 units to
1 WETH, converted to 10^18 underlying units using its rate. The two assets must
have separately selected economic minimums. No price oracle is introduced.

`setUnshieldRateLimits(perSecond, burst)` tunes the ordinary bucket: rate 1–16,
burst at least the rate and at most 128. It accrues under the old policy before
changing settings and clamps credit when shrinking the burst; changing policy
does not refill the bucket for free. Production registry ownership must be a
timelock. These settings reserve ordinary-exit capacity independently of swaps;
they do not guarantee fair ordering against many competing withdrawal accounts.

Score intervals use timestamps, not Arbitrum block counts. Reducing batches
alone would not stop same-block bursts. At maximum competition size, 32 batches
make 768 scores public exactly once per rank over at least 155 seconds from first
to last authorization. Network completion can take longer. Qualification relies
on finalized rank and need not wait for these scores.

## Public disclosure boundary

The inherited `requestDiscloseEncryptedAmount` remains available. Holders also
have CoFHE ACL rights over their handles and can call Task Manager `allowGlobal`
directly. Limiting a wrapper disclosure helper would not restrict that direct
permission. These controls bound creation of AlphaEngine swap/withdrawal claims
and manager-driven score authorization, not every FHE operation or decrypt a
holder can initiate. Account for inherited shielding, confidential transfers,
private decrypts and public disclosure in the live load assessment. Repeated ACL
grants are not evidence that the network recomputes a cached plaintext each time.
Publishers must deduplicate handles and retry publication independently of rank
admission. Live throughput and service request controls remain release evidence.

## Compatibility and deployment

- Fresh wrappers require the explicit registry as the last constructor argument.
  External registration verifies this binding in addition to existing underlying,
  rate and claim-ID checks. This catches incompatible deployment wiring; owner
  review of external wrapper bytecode remains mandatory.
- The registry adds policy getters/setters and the wrapper-only budget call.
  Set per-asset minimums after registration and before enabling swaps/partial exits.
- `unshieldAll(address recipient)` is a direct caller-owned wrapper entry point.
  Read `latestUnshieldClaimId(recipient)` from the same transaction or consume the
  `FullBalanceUnshieldRequested(account,recipient,claimId)` event. Its return is
  the official transaction-scoped share, not a permanent ciphertext handle.
- Clients handle cooldown/rate-limit errors and their next-available timestamps.
  Wallets must not assume a cleared pending request always permits immediate retry.
- Score reveal retains its selector but requires `startRank ==
  scoreRevealedThrough(competitionId) + 1`, batch size 1–8 and time at least
  `nextScoreRevealAt`. A cursor records authorization, not result readiness.
- Swap cooldown storage and competition cursor/pacing storage are appended into
  existing gaps. Other existing fields and hash domains are preserved.
- Use the already required fresh v2 deployment; drain historical swaps/claims.
  In-place adoption with historical revealed ranges or active untracked intents
  is unsupported. Do not reinterpret old wrapper storage or manifests.
- Generated ABIs, layouts and listener selectors/topics are the consumer contract.
  This change is confined to the contracts repository; SDK/listener cutover and
  real CoFHE integration are required before deployment.

## Validation

Regression tests cover zero/dust/exact/above-balance amounts; both overloads;
full-balance exits and later deposits; single/batch/third-party zero completion;
forged result rollback; cross-wrapper budget exhaustion and refill; source versus
recipient identity; shared-escrow concurrency; registry binding; prospective
minimum changes; score replay/skip/cross-competition pacing; full 256-entry
pagination; and cursor/ACL rollback on a failed grant.

An independent two-asset unshield invariant model tracks balances, pending burns,
payouts, cooldowns and bucket credit, including invalid requests with exact error
assertions. Swap invariants cover masked amounts and cooldown rejection without
excluding zero/above-balance requests. Competition invariants compare cursor and
pacing against independent progress and require each ranked submission's three
scores to be authorized at most once.

Foundry v1.7.1 passed 345 tests, including 40 invariant properties (81,920
aggregate handler calls with zero reverts). Coverage passed with 93.42% overall
line coverage, using the existing minimal-IR deployment-script exclusion.
ABI, listener-surface, storage-layout, hash-vector, runtime-size, formatting and
repository-hygiene checks passed. Existing proxy fields and reserved end slots
are unchanged; only the declared gaps shrink.

Foundry's plaintext compatibility harness does not prove threshold-network
capacity, real signature validity, ciphertext metadata parity or completion
latency. Full validation details are recorded in the development log.
