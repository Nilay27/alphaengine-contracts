# Lifecycle invariant scenario review

This inventory records **pre-fix evidence**. Current implementation scope,
focused results and rerun commands are in [the agreed fixes](approved-audit-fixes.md).

Scenario implementation — 2026-10-15. Production baseline: `257eb3183c86359d84cd80019a0feaba8e4e2a8a`.

## Scope and coverage status

Implementation inventory — 2026-10-15. Production baseline remains
`257eb3183c86359d84cd80019a0feaba8e4e2a8a`; only tests and test documentation change.
Existing Foundry handlers are extended rather than replaced with a generated
parallel suite. No production formula, storage, permission or deployment change
is included. All scenario conditions below retain the reviewed scope.

**Latest owner validation: 355 passed, nine failed, two fork skips in 44.36s.**
The repaired harness has no observed memory, gas, setup or drain failures.
Remaining failures reproduce R1–R4 and conditional asset/execution leads.
USDC replayed cached counterexamples in that batch; a separate fresh 64 × 32
campaign completed 2,048 calls with zero handler reverts or memory errors.
All economic assertions, 2/10/100-cycle and 259-submission witnesses remain. Vault
pending ownership is tracked incrementally and audited against every archived
request after each fuzzed action; each changed request is also checked immediately.

| Executable coverage | Meaning |
|---|---|
| **Yes** | Assertions and lifecycle inputs have been implemented, or the dedicated stateless property already exists. This records an implemented check of the stated local obligation, **not a passing test, measured coverage result or proof**. Evidence names the handler, invariant or parameterized lifecycle driver. |
| **Partial** | Local safety/rollback assertions exist, but the stated migration, SLA or consumer guarantee still needs an owner decision or another repository. |
| **No** | The external dependency/valuation policy needed to exercise the guarantee is unavailable; no fake local substitute is counted. |

Inventory: **133 scenarios — 126 Yes, 4 Partial, 3 No.** Six of the Yes rows
are correctly tested as stateless/deployment properties rather than artificial
state machines. The seven incomplete rows are FV-27/FV-29, EX-14/EX-16/EX-17,
AS-16 and XS-06. They cannot truthfully become complete from test-only edits.

A **Decision** or explicitly conditional/exploratory assertion is not a
confirmed defect solely because it fails. Keep those results separate from
reproduced economic defects, invalid fixtures and dependency limitations.
Randomized handlers interleave valid/invalid user actions and permitted admin
changes; rare boundaries also have seeded or parameterized multi-step drivers.
No finite campaign makes the contracts foolproof.

Primary specifications: [implementation plan](strategy-manager-fund-vault-implementation-plan.md),
[invariant ledger](invariant-ledger.md), [testing strategy](testing-strategy.md),
and actual `src/` guards. The tests do not authorize changing a canonical
formula or inventing a new withdrawal priority, freshness limit or migration.

## Economic regression fixtures

R1–R3 are implemented as desired-safety assertions in the existing USDC unit
suite and were reproduced red on unchanged production code before the full
batch was written. Their randomized counterparts are in the existing USDC
handler. R4 is an implemented exploratory regression; its final-batch result
has not been collected. These tests should become green after remediation,
without rewriting them to expect the unsafe behavior.

| Fixture | Exact lifecycle | Current result and intended failing check |
|---|---|---|
| R1 — incoming depositor rounding loss | Fee 0; Alice deposits 100 USDC; report funded 100-USDC profit; redeem all but one atomic share while profit is locked; finish vesting; Bob deposits 199 USDC and immediately redeems. | Bob receives 149.500000 USDC. Assert the plan's bounded deposit-pricing loss and a derived, asset-denominated round-trip bound. One atomic share is `1e-18` whole shares, not one whole share. Covers FV-01/FV-02. |
| R2 — fee burden shifted to remaining holder | Alice/Bob deposit 980/20 USDC before any profit; report funded 100-USDC profit at 20% fee; advance until 1 USDC remains locked; complete Alice's 980-share redemption; finish vesting and settle fees. | Alice receives 1,077.02 USDC and Bob's remaining claim falls to about 2.98 USDC after a profit-only period. Assert that Alice cannot leave her accrued fee burden against Bob's principal. The all-wait value 21.60 USDC is an explanatory benchmark, not an approved during-vesting price formula. Covers FV-10. |
| R3 — accrued fee disappears after a large exit | Initial 100 USDC/100 shares; funded 100-USDC profit; 20-USDC pending fee; 1 USDC still locked; redeem 99 shares; finish vesting and settle. | Redemption pays 197.01 USDC, leaving managed assets 2.99 USDC against the pending 20-USDC fee; `_feeShares` returns zero and settlement clears the claim. Assert surviving earned entitlement is not silently erased. Covers FV-11. |
| R4 — completed competition cancelled before finalization | Submit; evaluate every active entry before the evaluation deadline; advance past that deadline without finalizing; unrelated caller attempts expiry cancellation; attempt finalization and qualification/reveal. | Current public cancellation can make the competition terminal. **Decision:** protect completed evaluation from permissionless expiry cancellation, or explicitly choose a hard finalization deadline and consistent downstream behavior. Covers CM-11. |

R1–R3 fund reported gain with actual fixture USDC. R2 checks a profit-only
pre-existing holder's principal floor; R3 checks earned fee value survives as a
settled or pending claim. Neither assertion prescribes a new fee-pricing
formula. The USDC handler distinguishes payout recipient cash from payments
made on behalf of the request owner and tracks reinvestment without new minting.

## Existing test sources

The evidence column uses these short references. Function names identify the
particular check or action; absence claims refer to these current suites.

| Reference | Sources and material limitations |
|---|---|
| UV | [USDC handler](../../test/handlers/USDCVaultInvariantHandler.sol), [USDC invariants](../../test/invariant/AlphaEngineUSDCVaultManager.invariant.t.sol), [USDC unit/fuzz tests](../../test/unit/AlphaEngineUSDCVaultManager.t.sol). Thirty-five-plus targeted actions: funded P&L, independent owner/share/cash/request ledgers, repeated cycles, relative economic boundaries, administration and active progress. Mock USDC/deployed-liquidity fixture is separate from the real-manager integration. |
| CM | [Competition handler](../../test/handlers/CompetitionManagerInvariantHandler.sol), [competition invariants](../../test/invariant/AlphaEngineCompetitionStrategyManager.invariant.t.sol), [unit/fuzz tests](../../test/unit/AlphaEngineCompetitionStrategyManager.t.sol). Multiple competitions, global admission oracle, rank/publication/reveal/error/governance actions, full-capacity witnesses and compatible populated upgrades. |
| QR | [Qualification handler](../../test/handlers/QualificationRegistryInvariantHandler.sol), [qualification invariants](../../test/invariant/AlphaEngineTraderQualificationRegistry.invariant.t.sol), [unit/fuzz tests](../../test/unit/AlphaEngineTraderQualificationRegistry.t.sol). Independent qualification version/expiry/evidence ledger with boundary, revoke, governance and upgrade actions. |
| CA | [Capital handler](../../test/handlers/CapitalManagerInvariantHandler.sol), [capital invariants](../../test/invariant/AlphaEngineCapitalStrategyManager.invariant.t.sol), [unit/fuzz tests](../../test/unit/AlphaEngineCapitalStrategyManager.t.sol). Future windows, exact authorization mutation/replay/terminal failures, role/manager changes, qualification cycles and populated upgrades. Its local downstream execution dependency remains mocked; QC-12 is real-manager integration. |
| FX | [FundVault execution handler](../../test/handlers/FundVaultExecutionInvariantHandler.sol), [invariants](../../test/invariant/AlphaEngineFundVaultExecution.invariant.t.sol), [unit/fuzz tests](../../test/unit/AlphaEngineFundVaultExecution.t.sol). Maximum batches, protected and indirect/reentrant control-plane probes with independent effect and rollback accounting. Funded LP accounting is in the shared integration. |
| EX | [Execution-manager handler](../../test/handlers/VaultExecutionManagerInvariantHandler.sol), [invariants](../../test/invariant/AlphaEngineVaultExecutionManager.invariant.t.sol), [unit/fuzz tests](../../test/unit/AlphaEngineVaultExecutionManager.t.sol). Distinct traders/executors, independent per-asset spend histories, exact windows/capacity, policy/risk/code changes, approval mutations, callbacks and conditional direct-share-burn probes. |
| SC | [Swap-controller handler](../../test/handlers/ConfidentialSwapControllerInvariantHandler.sol), [invariants](../../test/invariant/AlphaEngineConfidentialSwapController.invariant.t.sol), [unit/fuzz tests](../../test/unit/AlphaEngineConfidentialSwapController.t.sol). Mutable prospective executor/admission settings, exact actual-transfer amounts, pause/preclaim/refund ordering and immutable historical commitments. |
| SE | [Swap-escrow handler](../../test/handlers/ConfidentialSwapEscrowInvariantHandler.sol), [invariants](../../test/invariant/AlphaEngineConfidentialSwapEscrow.invariant.t.sol), [separation tests](../../test/unit/AlphaEngineConfidentialAssetSeparation.t.sol). Mixed ordinary unshield and swap locks on the same real wrappers, failure injection, independent per-user/asset/claim ledgers, governance constraints and compatible asset upgrades. CoFHE is mocked. |
| UA | [Unshield handler and invariants](../../test/invariant/AlphaEngineUnshieldAdmission.invariant.t.sol), [CoFHE migration tests](../../test/unit/CoFheV020Migration.t.sol), [asset-upgrade tests](../../test/unit/AlphaEngineAssetUpgrade.t.sol). Later funding/transfers, distinct recipients/claimants, mutable credit/minima, proof domains, ordinary claims, business ownership and ProxyAdmin handovers. Live network behavior remains AS-16. |
| IN | [Real capital-to-execution integration](../../test/integration/AlphaEngineCapitalVaultExecution.t.sol), [swap differential integration](../../test/integration/AlphaEngineSwapExecutionReference.t.sol), [Pendle decoder fork](../../test/integration/AlphaEnginePendleV4DecoderFork.t.sol). Real qualification/capital/Merkle/USDC-accounting integration with funded LP shares and a controllable independent position book; separate real twin-PoolManager differential swaps. Position quote and CoFHE are mocks; actual Pendle lifecycle remains EX-16. |

## A. Fund shares, USDC accounting, and investor equity

Required baselines: implementation-plan section 6 and its FundVault/USDC
invariants. Track share ownership, idle liquidity, position value, locked gain,
fee entitlement, and unrecovered loss separately. NAV is not necessarily idle
USDC. Accepted participation in remaining unvested gain is not automatically an
attack; its scope is bounded by the documented vesting policy.

| ID | Lifecycle sequence / variation | Invariant or owner question | Executable coverage | Implemented evidence / remaining gap |
|---|---|---|---|---|
| FV-01 | R1; vary initial deposit, profit, and residual supply `1, 2, 1e12-1, 1e12, 1e18`. | Incoming deposit's pre-price rounding loss obeys an asset-denominated bound; one nonzero share is not sufficient protection. | Yes | UV `economicStress` varies initial capital, funded profit and five residual-supply boundaries; `invariant_FV01_incomingDepositLossIsAtMostOneAssetUnit` uses an independent asset-unit inequality. R1 remains red. |
| FV-02 | Deposit then immediately request/complete redemption of the newly minted shares, after arbitrary earlier lifecycles. | With no intervening P&L, time-based accrual, or fees, no free gain and no loss above the approved rounding budget. | Yes | UV `roundTrip` after arbitrary earlier actions; `invariant_FV02_roundTripsPreservePrincipalWithinAssetRoundingBudget` checks both gain and loss without intervening time/P&L. |
| FV-03 | Repeat the same small deposit/redeem or redeem/redeposit cycle 2, 10, and 100 times, with a second holder present. | Neither direction extracts cumulative dust or transfers material value between holders; bound total rounding by the explicit per-operation budget. | Yes | UV `roundTrip` and `redeemAndReinvest` exercise both cycle directions 2/10/100 times using actual returned cash; independent share/cash wealth and asset-unit dust budgets. No new funding in the inverse cycle. |
| FV-04 | First deposit of one USDC base unit; profit/loss; second depositor; empty and re-enter. | Initial scaling and subsequent conversions remain coherent at the smallest admitted amounts; a deposit either issues economically valid shares or rejects atomically. | Yes | UV `exerciseZeroAndTinyLifecycle`: one-base-unit bootstrap, total loss, protected minimum, cancel/zero burn and different-wallet re-entry, with independent actor ledgers. |
| FV-05 | Last holder exits after vest; fee shares remain or also exit; a different wallet deposits again. | Empty/re-entry accounting does not gift prior holders' remaining assets to the next depositor or strand an unexplained NAV balance. **Decision:** residual-asset ownership if virtual balances are adopted. | Yes | UV `_closeCohort` finishes vest, cancels pending requests, returns liquidity, consolidates real holders including fee shares, completes full exit and asserts zero NAV/supply before re-entry. |
| FV-06 | Loss equals full managed NAV; request/cancel/complete a zero-value exit; restore liquidity or later capital. | Zero-minimum shares have a terminal burn path; a nonzero minimum remains protected; no negative NAV, orphaned request, or free revival of burned shares. | Yes | UV `exerciseZeroAndTinyLifecycle`: one-base-unit bootstrap, total loss, protected minimum, cancel/zero burn and different-wallet re-entry, with independent actor ledgers. Exact typed minima failure and eligible zero-minimum burn are separate witnesses. |
| FV-07 | A deposits before profit, B halfway through vest, C near unlock; each exits at different times. | Recognized historical profit is not allocated to a new depositor; only the documented remaining-vest participation applies; fees and value remain explainable per actor. | Yes | UV `exerciseStaggeredEntrants` varies A/B/C admission at vest phases and independently accounts recognized/unvested asset allocations; cohort and per-owner ledgers check fees/value separately. |
| FV-08 | A partially exits during vest, B deposits, report loss, unlock, A/B exit and redeposit. | Preserve claims through the combined sequence, accounting for allowed unvested-profit redistribution and immediate loss. | Yes | UV `exerciseExitEntryAndRelativeLoss` varies partial exit, new entry and loss relative to locked gain; owner cash/shares and allowed vest redistribution are checked. |
| FV-09 | Attempt entire vault-share-supply redemption during vest; then at exact unlock and after fee settlement. | The existing locked-profit guard rejects the first attempt without mutation; eligible final settlement succeeds once its actual preconditions hold. | Yes | UV `exerciseFinalExitGuard`, `attemptGuardedCompletion` and exact unlock−1/unlock witnesses check atomic full-supply rejection and post-unlock completion. |
| FV-10 | R2; vary which holder exits first, ownership split, vest progress, and exit fraction. | Early exits cannot leave their accrued performance-fee burden against remaining investors' principal in the profit-only fixture. | Yes | UV `economicStress` varies profit, large-holder split and exit timing; pre-profit cohort principal floor in `invariant_FV10_profitOnlyCohortRetainsItsPrincipal`. R2 is red. |
| FV-11 | R3; repeatedly reduce supply/NAV while fee entitlement accrues, then settle at/after unlock. | Surviving earned fees are preserved or settled, not silently cleared because fee-share math returns zero. | Yes | UV `economicStress` large exit and `invariant_FV11_earnedFeesAreNotErased` compare actual settled value plus surviving claim with earned asset entitlement, independently of fee-share parity. R3 is red. |
| FV-12 | Preview before unlock, settle explicitly or through deposit/redemption/loss, preview again. | Crystallizing already-earned fees does not itself cause a pricing jump; previews and execution use the same approved effective accounting basis. | Yes | UV settlement previews/model checks retained; prospective configuration and explicit/implicit settlement interleave with the enlarged action set. |
| FV-13 | Positive report, loss below/equal/above remaining locked gain, then another positive report. | Loss cancels unvested gain first, reduces the appropriate unearned fee, recognizes excess loss immediately, and restores recovery accounting correctly. | Yes | UV `exerciseFeeLossBoundaries` varies loss just below/at/above locked profit, unearned fee cancellation and a later report; shadow and per-owner ledgers remain checked. |
| FV-14 | Deposit/withdraw immediately before and after a recognized loss; reverse actor/order choices. | Loss is not deferred until the next vest; payouts use the current recognized NAV. Do not assert that investor value never decreases when a real loss occurs. | Yes | UV `exerciseLossTiming` changes entry/exit order around immediate loss; current recognized NAV and actual owner payout are checked, not a false loss-free guarantee. |
| FV-15 | Loss, partial redemption, fresh deposit, recovery profit, then profit above the recovery balance. | Scale fund-level `lossToRecover` only as specified; recovery is not charged twice. Do not invent per-investor fee equalization, which the plan excludes. | Yes | UV `exerciseRecoveryAndFreshMoney`: partial exit, fresh entry, partial loss recovery and later above-deficit profit; preserves specified fund-level recovery. |
| FV-16 | Several requests by A/B; report P&L; cancel one; complete another out of order. | Requests create no fixed asset claim; cancellation returns only the right owner's shares; completion cannot burn or pay another request twice. | Yes | UV `requestWithMinimum`, random request selection, `attemptTerminalReplay`, immutable `ghostRequestBinding` and independent owner/escrow balances. |
| FV-17 | Submit requests with different nonzero `minAssets`; loss/vest/fees change their prices; retry or cancel. | Failed minima preserve the complete request and escrow state; eligible retries use current pricing, not request-time pricing. | Yes | UV `requestWithMinimum` selects zero/current/current+1 minima; `attemptGuardedCompletion` hashes complete lifecycle state around exact typed reverts; retry/cancel remain selectable. |
| FV-18 | Request exit, deploy idle USDC, reject illiquid completion, unwind partly then sufficiently, retry. | Pending requests remain live; invalid completion is atomic; an eligible completion succeeds after sufficient liquidity returns. | Yes | UV deploy/return/drain actions and real funded integration handler connect idle shortage, authorized unwind and later eligible withdrawal. |
| FV-19 | A and B have pending exits; complete one, then another, after independent P&L and liquidity changes. | Paid assets and remaining claims obey the approved floating-price model; no aggregate overpayment. **Decision:** priority/fairness/SLA is not FIFO by default. | Yes | UV independent ownership ledger and `drainEligibleRequests` actively complete all eligible pending records; real integration also tracks requests across position/P&L transitions. No FIFO/SLA invented. |
| FV-20 | Change fee rate before a report, during a vest, and after settlement; repeat exits around each change. | Prospective fee changes do not rewrite the active tranche's snapshot or transfer old fees to later investors. | Yes | UV `configureAccounting` changes prospective fee bps and asserts active fee snapshot/unlock remain unchanged; exercised across reports/exits. |
| FV-21 | Change fee recipient during pending earned fees, after zero-fee reports, and after settlement. | Enforced configuration gates are exact; existing earned entitlement is neither lost nor redirected contrary to the approved recipient policy. | Yes | UV `configureAccounting` alternates two recipients, checks exact active-fee rejection and preserves historic recipient balances in ghost shares. |
| FV-22 | Change vest duration while a tranche is active or after it finishes; report again and withdraw. | Active vest cannot be shortened or extended through a forbidden update; new settings apply to the intended future tranche only. | Yes | UV `configureAccounting` tests exact active-vest rejection, settles finished fees and applies the next vest duration; boundary/time actions never rewind. |
| FV-23 | Rotate NAV reporter while deposits/requests are live; old and new reporter submit. | Old reporter loses authority; new valid reports maintain epoch/reference ordering and cannot mutate pending ownership. | Yes | UV `rotateReporter` rejects former reporter using exact error and full-state hash; valid reports use only the current reporter. |
| FV-24 | Pause manager, vault, or both during pending exits; attempt risk-taking, cancellation, completion, and resume. | Respect each component's documented pause boundary; preserve permitted exit cleanup; prohibit a resumed operation from bypassing accounting. | Yes | UV `configurePause` varies manager/vault independently; deposits/requests/reports explicitly reject while cancellation/completion remain modeled and selectable. |
| FV-25 | Transfer/approve/transferFrom shares before requests, while other shares are escrowed, during vest, and after a partial exit. | Per-owner balance + escrow + transferred value reconciles; transferred shares cannot authorize spending another owner's pending request; no unbacked mint. | Yes | UV `transferShares` covers transfer/approve/transferFrom with exact allowance consumption; owner/receiver/pending-share ledgers are separate. |
| FV-26 | Donate USDC before/after deposits, active profit, deployed capital, and redemption. | Donation changes physical liquidity, not manager NAV, issued shares, or the accounting conversion rate. | Yes | UV donation ghosts, NAV-delta invariant, funded physical P&L and independent actual-USDC conservation; donations cannot become priced NAV. |
| FV-27 | Stop reports, let positions change externally, then try new deposits and redemptions. | **Decision:** define maximum report age and stale-NAV admission behavior; a mock report hash alone cannot establish fair market valuation. | No | OPEN POLICY: no canonical maximum report age or independent live valuation source has been selected. Do not encode an arbitrary freshness threshold as a protocol guarantee. |
| FV-28 | Consecutive daily profit reports; holders request exits throughout; losses or fee changes interleave. | Existing code cannot overwrite an unfinished vest. **Decision:** if remediation adds exit gating, guarantee an explicit usable exit opportunity instead of indefinite report-induced starvation. | Yes | UV `exerciseDailyReportsAndExitProgress` varies 3–7 daily reports, prospective fee settings, active-vest overwrite rejection and eligible exit progress; dedicated counters prove reachability. |
| FV-29 | With holders and pending exits, pause and recover supported assets to the precommitted replacement vault. | Source recovery cannot redirect assets; shareholder claims remain reconcilable across migration. **Decision:** define how requests are fulfilled after migration. | Partial | Real funded integration checks fixed recovery destination, unchanged LP/escrow/request bindings and irreversible source pause. OPEN POLICY: replacement-vault request fulfillment is not specified and is not simulated as if implemented. |
| FV-30 | All above actions over repeated amounts, zero/maximum boundaries, multiple actors and report epochs. | An independent actor-value ledger explains cash, remaining shares, fees, reported P&L and allowed rounding; aggregate conservation alone is insufficient. | Yes | UV independent per-owner share, request and cash ledgers; funded asset P&L; asset-unit deposit/round-trip inequalities; separate profit-only principal and earned-fee preservation properties. Real funded integration adds position book. |
| FV-31 | Begin and accept two-step manager/vault ownership transfers with live deposits, requests and reports; old owner attempts updates. | Only the accepted owner obtains configuration authority; pending claims, reporter identity and asset ownership do not change merely from the handover. | Yes | UV `handoverOwners` begins/accepts both two-step business transfers, rejects former owner, and preserves requests/reporter/assets; subsequent actions use current ownership. |

## B. Competition lifecycle and administration

| ID | Lifecycle sequence / variation | Invariant or owner question | Executable coverage | Implemented evidence / remaining gap |
|---|---|---|---|---|
| CM-01 | Submit, cancel, resubmit repeatedly across traders. | Successful submissions alone advance independent nonces; IDs remain unique; cancellation never reuses a nonce. | Yes | CM nonce/count/pointer invariants retained across submit/cancel/replacement and multiple competitions. |
| CM-02 | Several replacements, cancel an older entry, then evaluate/finalize the latest entry. | Exactly the latest entry is active; old/superseded entries cannot clear its pointer, receive rank, or qualify. | Yes | CM `attemptInvalidCancellationOrReplacement`, out-of-order evaluation and parameterized replacement→ranking→publication→upgrade driver. |
| CM-03 | Fail replacement through proof/input validation after a valid entry. | Keep the old entry, nonce, allowance history and all prior ciphertext permissions unchanged; no partial new entry. | Yes | CM `attemptInvalidCancellationOrReplacement` injects invalid proof after a live entry and checks nonce/history/pointer/ciphertext permission atomicity. |
| CM-04 | One wallet submits across several markets and several concurrent competitions. | One global wallet allowance; changing competition/market or cancelling does not refund it. | Yes | CM `selectOrCreateCompetition`, global allowance-history oracle and several encrypted markets; cancellation does not restore successes. |
| CM-05 | Submit at oldest timestamp + window - 1, exactly the boundary, and + 1; repeat equal timestamps and history wrap. | Refill removes only expired successes; no reset-boundary double spending; rejection precedes FHE verification. | Yes | CM boundary/history-wrap driver and `phaseBoundary` exercise oldest+window−1/exact/+1, equal timestamps and wrap; rejection precedes proof verification. |
| CM-06 | Exhaust allowance, pause, change limit/window up or down, unpause and retry. | History persists; new eligibility reflects the intended current policy without fabricating old successes or restoring spent allowance. | Yes | CM `governanceCycle` changes limit/window while paused without resetting the independent history; exact budget boundaries remain checked. |
| CM-07 | Fill competition to maximum active capacity; replace an existing trader; try a new trader. | Replacement does not consume another active slot; new entry respects capacity; invalid calls preserve counts. | Yes | CM `fillCompetitionCapacity` and full-capacity lifecycle driver exercise 256 live entries, old-trader replacement, rejected new trader, rank/reveal drain and upgrade. |
| CM-08 | Approach submission/evaluation deadlines naturally, then begin evaluation or submit on each side. | No time reversal in the harness; exact documented phase boundaries; late invalid calls fail without state/FHE changes. | Yes | CM `phaseBoundary`/`attemptLateSubmission` plus exact submission/evaluation boundary drivers; natural monotonic time only. |
| CM-09 | Evaluate entries out of order; retry rank, duplicate score, superseded entry, or cancelled entry. | Rank is unique/bounded and only current eligible entries can be evaluated once; failure preserves counts and stored scores. | Yes | CM `evaluateOutOfOrder` and adversarial rank attempts check immutable scores/counts and rank uniqueness; latest-entry pointers remain authoritative. |
| CM-10 | Attempt finalization before all entries are evaluated; then finish and retry. | Incomplete finalization is atomic; complete eligible finalization succeeds exactly once. | Yes | CM `attemptIncompleteFinalization` and `attemptTerminalFinalization`; all successful/failed transitions checked against snapshots. |
| CM-11 | R4: fully evaluate, pass evaluation deadline, race public cancellation against finalization. | **Decision:** public expiry cleanup must not destroy completed work, or define a consistent hard finalization deadline. Keep authorized emergency cancellation distinct. | Yes | CM `test_CM11_exploratory_completedEvaluationSurvivesPublicExpiryCancellation` is a protective RED regression; cancellation policy still requires owner disposition. |
| CM-12 | Empty or partly evaluated competition expires; cancel; attempt later evaluation/finalization. | Under the selected expiry policy, cleanup is available and terminal; no cancelled competition can issue qualifications or new reveals. | Yes | CM `cancelCompetitionLifecycle` and parameterized expiry/emergency cancellation drivers check terminal cleanup and forbidden later publication/evaluation. |
| CM-13 | Authorized emergency cancellation while active/evaluating and paused; unauthorized caller retries. | Exact role gating; terminal competition state, counts, and downstream publication stay consistent. | Yes | CM `cancelCompetitionLifecycle`, paused emergency cancellation and role probes; exact unauthorized failure and terminal-state assertions. |
| CM-14 | Finalize, publish qualifying ranks in different orders, retry duplicates/nonqualifying ranks. | Only finalized evaluated eligible entries publish once; registry evidence and competition publication counters agree. | Yes | CM `publishQualificationAt`, `attemptInvalidPublication`, randomized rank order and published-version/evidence counters. |
| CM-15 | Publish qualification, advance past its expiry, revoke/requalify, then inspect historical competition evidence. | Publication was valid at publication time; historical evidence stays true even when current qualification expires. Do not require it to stay active forever. | Yes | CM `qualificationHistory` advances expiry/revocation/requalification; historical evidence checks recorded publication/version, not perpetual current qualification. |
| CM-16 | Paginate score reveal, repeat/skip a cursor, mix batch sizes, retry after result publication. | Finalized rank prefix only; three component grants move together; no duplicate grants or cursor drift. | Yes | CM cursor/pacing/component-grant oracle; `attemptInvalidRevealBatch`, repeated/skipped cursor and full-capacity reveal drain. |
| CM-17 | Two finalized competitions alternate reveals around the global pacing boundary. | Global pacing cannot be bypassed by changing competition; qualification publication need not wait for reveal. | Yes | CM parameterized two-competition reveal-pacing driver; qualification is independently publishable. |
| CM-18 | Fail the second/third component grant or a later entry in a reveal batch. | Roll back earlier grants, cursor and global pacing together; a later correct attempt remains possible. | Yes | CM `attemptInvalidReveal` injects component/later-entry grant failure and checks complete ACL/cursor/pacing rollback, then retries. |
| CM-19 | Submit under operator A, pause/rotate operator and evaluator/revealer roles, resume and process old/new entries. | Historical handles retain intended recorded access; new handles use new configuration; former role holders cannot perform newly forbidden actions. | Yes | CM `governanceCycle`/`processingRoleCycle`, historical operator/ACL ledger and old/new entry processing. |
| CM-20 | Pause/unpause in each phase, including between finalization, qualification, reveal and expiry cleanup. | Per-selector pause/role rules hold without orphaning permitted terminal work; failures leave all counters and handles unchanged. | Yes | CM `pausePhaseProbe`, role/cancellation/governance actions and typed rollback checks across phases. |
| CM-21 | Compatible implementation upgrade with active, superseded and evaluated entries, allowance history and partial reveal progress. | Preserve storage, domain-separated IDs, operator/role permissions, timestamps, final-entry pointers, evaluation records and reveal cursor; initialization cannot replay. | Yes | CM `upgradeCycle` plus populated replacement/evaluation/reveal drivers retain records, allowance history, pointers, permissions and cursor; reject initializer/admin replay. |

## C. Qualification and capital authorization lifecycle

| ID | Lifecycle sequence / variation | Invariant or owner question | Executable coverage | Implemented evidence / remaining gap |
|---|---|---|---|---|
| QC-01 | Qualify an active trader repeatedly with later or shorter expiry/evidence. | Valid extension preserves version and never shortens validity; invalid updates preserve all evidence. | Yes | QR exact independent qualification ledger, `qualifyOrExtend`, `attemptShorterExtension` and exact version/expiry witnesses. |
| QC-02 | Revoke, requalify, attempt old pending approval and old approved execution. | Old qualification version stays invalid and cannot authorize progress; rejected calls preserve commitments/nonces. | Yes | QR/CA revoke/requalify and explicit invalid-version progress; immutable commitments/nonces remain checked. |
| QC-03 | Reach exact expiry, requalify, extend, expire again; use both old and new intents. | Expiry invalidates at the exact boundary; new qualification increments version; valid new intents remain usable. | Yes | QR `expiryCycle`, CA `qualificationExpiryCycle` and exact-expiry/requalification/fresh-consumption driver. |
| QC-04 | Submit multiple capital intents per trader, approve/reject/cancel/expire in different orders. | Per-trader nonce exactness; immutable payload/version binding; terminal states cannot revive. | Yes | CA `attemptTerminalProgress` retries every terminal selector; status/payload/version/nonce invariants retained. |
| QC-05 | Approve several intents and consume in a different order, then retry commitments/nonces. | Each immutable authorization belongs to one intent; both replay domains and status agree; a successful consume occurs once. | Yes | CA replay attempts and parameterized multi-intent out-of-order consumption/retry driver; both replay domains are checked. |
| QC-06 | Approve, make downstream execution fail after consume, then retry correctly. | All consumption state rolls back on failure; original authorization can still complete once. | Yes | CA typed downstream failure after consume, complete replay/status rollback and correct retry in multi-intent driver. |
| QC-07 | Approve a future-start authorization; try before/at validAfter and before/at deadline. | Time-window inequalities match the contract exactly; invalid attempts do not consume or alter qualification. | Yes | CA `approveFuture`/`consumeAtBoundary` and parameterized validAfter/deadline/paused-expiry driver. |
| QC-08 | Cancel/revoke/expire a live intent while manager is paused; later unpause and attempt approval/consume. | Permitted cleanup stays live while risk-taking remains blocked; terminal status remains terminal. | Yes | CA `governanceCycle`/`expireWhilePaused`, terminal cleanup and forbidden later approval/consume. |
| QC-09 | Approve for execution manager A; pause and deauthorize it; authorize B; attempt the old authorization. | New governance state cannot silently substitute a different bound executor/manager; exact authorization and current authorization gates apply. | Yes | CA authorized manager-B substitution probes retain binding to manager A; deauthorization/re-authorization tested without rewriting old approvals. |
| QC-10 | Rotate FHE operator with pending and approved intents, then submit new intents. | Recorded operator/handle permissions stay coherent; rotation does not rewrite prior payloads, commitments, ranks or evidence. | Yes | CA operator/governance driver plus recorded input ACL/payload ledger; old records are not rewritten. |
| QC-11 | Registry paused or issuer/revoker/evaluator role removed during pending intent lifecycles. | Only authorized operations progress; failed cross-contract calls are atomic; still-permitted revocation/cleanup remains available. | Yes | QR governance/issuer/revoker actions and CA registry pause/role cycle with cross-contract atomicity. |
| QC-12 | Qualification expires or is revoked between approval and the real Merkle execution transaction. | Recheck current qualification/version before real funds move; failure preserves FundVault balances and both managers' replay markers. | Yes | Real funded integration approval→qualification revocation/expiry→Merkle execution attempts; exact guard, FundVault balances and both replay domains checked. Expiry may hit outer authorization deadline first. |
| QC-13 | Mutate chain, vault, trader, intent, calls, risk, evidence or version fields of a previously approved authorization. | No cross-domain reuse or field substitution; rejection preserves original approval and all downstream state. | Yes | CA `attemptMutatedConsume` varies 19 field/condition mutations with exact allowed errors and full rollback; original authorization stays immutable. |
| QC-14 | Attempt to progress an old intent after multiple revoke/expire/requalify cycles with the same wallet. | Wallet identity alone never revives a superseded qualification version or terminal intent; fresh qualified submissions remain possible. | Yes | CA revoke/expire/requalify/old-intent attempts, exact version ledger and fresh qualified consumption. |
| QC-15 | Compatible registry/capital upgrades with expired/revoked qualification history and pending/approved/consumed intents. | Preserve every old version and approval/replay binding; no reinitialization, qualification revival or lost terminal request. | Yes | QR/CA `upgradeCycle` preserve populated versions, pending/approved/consumed records, roles, business bindings and separate ProxyAdmin ownership; initialization replay rejected. |

## D. FundVault execution, risk policy, and actual positions

| ID | Lifecycle sequence / variation | Invariant or owner question | Executable coverage | Implemented evidence / remaining gap |
|---|---|---|---|---|
| EX-01 | Approved entry, hold for randomized time, partial/full exit; repeat in both asset directions. | Independent spend/receipt ledgers match actual balances; approvals clear; no execution-manager custody. | Yes | EX entry/hold/exit and independent two-asset/window/allowance ledgers retained. |
| EX-02 | Same execution lifecycle while real LP shares, fees, and pending redemptions exist. | Execution cannot mint/burn shares, bypass NAV ownership, or corrupt investor claims. | Yes | Real funded integration uses USDC accounting, LP share/escrow ledger and pending exits while exact capital authorizations execute entry/unwind. |
| EX-03 | Several traders/executors execute interleaved bundles against their own roots and limits. | Independent authorization, policy, replay and rolling-spend domains; one actor cannot consume another's budget. | Yes | EX `executeSecondTrader`, distinct executor relay, separate roots and independent per-trader spend-history invariants. |
| EX-04 | Repeated equal spends just before/at/after a trailing 24-hour boundary, including same-block aggregation. | True rolling totals match an independent history; time boundaries do not permit a double budget. | Yes | EX `exerciseRollingBoundary` deliberately repeats equal same-block spends and t+24h−1/exact/+1 against independent history. |
| EX-05 | Fill 64 distinct spend records, attempt the 65th, expire the oldest, retry. | Capacity rejection is atomic; eligible history pruning restores progress without losing nonexpired spend. | Yes | EX `exerciseSpendCapacity` fills 64 records, rejects the 65th atomically, expires first record and retries. |
| EX-06 | Propose/cancel/activate/revoke a root while old approvals and positions exist; attempt stale and fresh execution. | Delay, executor binding and version rules hold; old proof cannot execute under changed policy; permitted unwind remains an explicit operational concern. | Yes | EX `exerciseRootGovernance` covers cancellation, premature/exact activation, stale approval, revoke/pause, restore and fresh execution. |
| EX-07 | Pause, lower/raise/remove per-asset limits, unpause and execute against prior spend. | Old authorizations obey risk-version checks; configuration cannot erase historical spend. A lowered cap may legitimately be below already-spent history; new spend must then be blocked. | Yes | EX `exerciseRiskGovernance` lowers/removes/restores limits while asserting unchanged spend history, stale-version rejection and fresh eligibility. |
| EX-08 | Code/decoder/facet identity changes between proof preparation, approval and execution. | Enforced identity checks fail before funds/replay state change; code-hash checks are not proof that a proxy's implementation cannot change. | Yes | EX `exerciseCodeIdentity` and `exerciseFacetIdentity` mutate target/decoder/facet code or mappings after approval; exact failure precedes balance/replay changes. |
| EX-09 | Several nonzero approvals for one asset in one batch; uses and resets reordered; repeat with another asset. | Aggregate authorized exposure obeys the exact risk envelope; every required reset is committed and leaves zero allowance. | Yes | EX `exerciseApprovalOrdering`/`exerciseAggregateApprovals` vary uses/resets and cumulative approvals in both asset directions. |
| EX-10 | Slippage, cap, invalid proof or downstream failure after earlier successful calls. | Atomic rollback across vault balances, consumed capital authorization, local replay and rolling spend; exact typed failure. | Yes | EX enhanced failure snapshots cover both assets/allowances/windows and both replay domains; shared real-capital integration supplies the real-consumption composition. |
| EX-11 | Replay a successful bundle, vary caller, then submit a fresh approved bundle. | Replay never succeeds or blocks a genuinely fresh nonce; caller and commitment domains remain bound. | Yes | EX stored original authorization replay, wrong executor and fresh nonce paths; stale/expired authorizations are distinguished from replay. |
| EX-12 | Use execution to call custody/accounting/control-plane selectors, including through a multi-call bundle. | Execution cannot mint/burn, reconfigure managers, recover assets, or reach protected targets through the allowed direct-call graph. | Yes | FX indirect authority probe checks 12 accounting, custody, recovery, configuration and nested-execution denials during a valid external call. |
| EX-13 | Allowed external target callbacks try to reenter execution, accounting, or recovery while a bundle is running. | No cross-function authority or partially updated-state bypass; rollback and allowances remain correct. | Yes | FX callback authority probes and EX Merkle-allowed `exerciseReentrantTarget` check reentrancy, custody authority and balance/allowance/replay consistency. |
| EX-14 | Emergency pause/recovery after entry, with pending capital and user withdrawal requests. | Fixed recovery recipient, no unauthorized drains, irreversible source recovery state; later claim handling follows an approved migration policy. | Partial | Real funded integration recovery with live LP shares/requests checks destination, source pause and claim preservation. OPEN POLICY: post-migration fulfillment is unspecified. |
| EX-15 | Enable ERC4626 exit policy where shares burn directly without an ERC20 approval; omit the share asset from risk limits. | **Decision:** every supported economic spend, including direct share burns, needs the intended risk coverage; otherwise explicitly prohibit that policy shape. | Yes | EX `exerciseDirectShareBurn` checks explicit share-risk spend/rollback, plus a separately named exploratory omitted-envelope invariant. Conditional enabled-policy lead; no default ERC4626 policy assumed. |
| EX-16 | Pendle PT entry, holding/P&L report, partial unwind, return USDC, complete a real user exit. | Exact route/receiver/asset accounting and permitted settlement after liquidity returns; no double-counted profit on redemption. | No | EXTERNAL ROUTE GATE: no canonical supported Pendle market/PT/direct-USDC-to-SY entry/exit fixture is selected. Decoder/facet fork parity is explicitly skipped without opt-in and does not establish a position lifecycle. |
| EX-17 | Position loses value or becomes hard to unwind after admission; tighter root/risk policy arrives. | Actual loss is reported immediately when recognized; no fabricated USDC liquidity or unauthorized emergency unwind. **Decision:** unwind authorization and withdrawal SLA. | Partial | Real funded integration uses independent variable position book, immediate recognized loss and exact authorized unwind/failure. OPEN POLICY: emergency unwind and withdrawal SLA remain unspecified. |
| EX-18 | Exact maximum batch, invalid later target or malformed arguments, then valid retry. | Preflight rejects forbidden bundles before earlier side effects; full maximum valid batch remains usable. | Yes | FX `exerciseBatchBoundaries`, EX `exerciseMaximumPreflight`: exact maximum, invalid later target/malformed arguments, atomic rejection and valid retry. |

## E. Confidential swap controller, escrow, and executor

| ID | Lifecycle sequence / variation | Invariant or owner question | Executable coverage | Implemented evidence / remaining gap |
|---|---|---|---|---|
| SW-01 | Repeated submits, successful executes and refunds by two traders. | Nonces/IDs advance exactly once; controller/escrow terminal states stay paired; neither controller nor executor becomes a custodian. | Yes | SC/SE nonce, identity, lock-terminal and no-custody invariants retained across the enlarged randomized action sets. |
| SW-02 | Below-minimum, exact-minimum, over-balance, zero and uninitialized accounts; then valid requests. | Store the actual transferred/burned handle and amount; valid initialized zero can terminate; a typed failure does not consume admission/nonce. | Yes | SC independent actual-transfer amount oracle; SE uninitialized/zero-lock probes and valid cleanup; boundaries also retain fixed vectors. |
| SW-03 | Submit, third party preclaims input, then settle; repeat with refund and out-of-order claims. | Claim exactly once, reconcile attributable escrow custody, pay only the recorded trader; terminal lock remains reclaimable. | Yes | SE preclaim, settle/refund and per-account claim ledgers now interleave with ordinary pending exits on the same wrappers. |
| SW-04 | Two live users; preclaim one; execute/refund the other; repeat. | One lock cannot spend another's preclaimed input or disturb its unique claim ID; per-user and per-asset ghosts reconcile. | Yes | SE multi-user unique claim and pending/preclaimed ledgers; one lock cannot consume another account's amount. |
| SW-05 | Submit under one route/executor/wrapper configuration, pause and rotate for new submissions, then process old records. | Every old record retains its original commitments and recorded dependencies; new configuration cannot redirect prior custody or settlement. | Yes | SC `rotateFutureExecutor` retains recorded executor/payload and exact dependencies for live records; later requests use the new executor. |
| SW-06 | Pause controller, escrow, or both before/after a permissionless preclaim; refund and later resume. | Risk-taking respects pause domains; documented early refund remains available when escrow is paused; no stranded claimed input. | Yes | SC `pausedPreclaimRefund` and SE `pauseAndRefund` vary controller/escrow/both pauses with claimed input and resume. |
| SW-07 | Several active locks; attempt escrow controller/registry rotation, clear some/all locks, retry. | Live-lock counter equals actual live records and blocks forbidden pointer changes; clearing the last lock restores permitted governance progress. | Yes | SE `rotateAfterDrainOrReject`/`drainAndRotate` reject live-lock changes, clear records and retry after the last terminal transition. |
| SW-08 | Zero refund starts cooldown; vary claimant, trader, exact boundary, and another trader's requests. | Cooldown belongs only to the recorded trader; invalid proof changes no state; later eligible submission can progress. | Yes | SC `rejectIncorrectRefundResult`, independent trader cooldown and third-party refund; boundary admission history is independently modeled. |
| SW-09 | Exhaust/refill swap admission; pause and change burst/rate; retry existing and new work. | Admission precedes FHE; no history reset exploit; already admitted settlement/refund does not require fresh admission. | Yes | SC `configureLimits`/`_rejectAdmission`, independent rolling success history/credit model; existing work does not need new admission. |
| SW-10 | Mutate execution data, minimum salt/output, wrappers, route or executor after admission. | Execute only the exact stored commitment; failures preserve the live lock, nonce, approvals and balances. | Yes | SC commitment mutations plus frozen route/executor/wrapper fields across future configuration changes; snapshots preserve live lock/nonce/balances. |
| SW-11 | Executor or output shielding fails after input claim or transfer; retry/refund. | Roll back claims, tokens and statuses atomically; original lock keeps a terminal route. | Yes | SE `failExecutorThenRetry`/`failOutputShieldThenRetry` check exact failure, full coupled-state rollback and retained terminal path. |
| SW-12 | Settle/refund once; replay either operation before/after later locks by the same trader. | Terminal lock cannot revive, pay twice, or clear another active slot. | Yes | SC `rejectTerminalRefundReplay` plus SE `rejectTerminalOperations` around later work by the same users. |
| SW-13 | Six-to-higher-decimal swaps where output is not an exact wrapper-rate multiple. | Total output = shielded representable units + exact dust to original trader; minimum applies to total before splitting; zero residual output. | Yes | IN `testFuzz_SW13_HighDecimalRepeatedLifecycle` uses real twin pools and independent cumulative total/shielded/dust deltas. |
| SW-14 | Several swaps in both directions, changing real pool liquidity/price and trading amount. | Respect actual minimum, exact PoolManager deltas, and zero executor residue; do not assume output units equal input units. | Yes | IN `testFuzz_SW14_RepeatedBidirectionalPoolLifecycle` changes actual twin liquidity/price, amount and direction through repeated calls. |
| SW-15 | PoolManager callback called directly, by wrong sender, with malformed deltas, or twice. | Callback cannot spend balances outside an authorized active swap; exact errors/rollback; legitimate callback still completes. | Yes | IN `testFuzz_SW15_CallbackOrderingCannotSpendOutsideSwap` tests wrong sender/locked state/malformed deltas and a later valid swap. |
| SW-16 | High-decimal input near signed PoolManager amount limits; fail execution, then refund. | Typed supported-domain rejection must not strand a valid lock. **Decision:** supported decimal/amount ceiling and deployment restrictions. | Yes | IN conditional high-decimal supported-domain property, plus typed execution-failure/refund witness. An unsupported-domain assumption is not classified as a default asset vulnerability. |
| SW-17 | Donated wrapper reserves approach confidential uint64 capacity before a valid refund re-shields input. | **Decision:** define reserve headroom/admission policy so supported refunds cannot be blocked by unrelated donated balances. | Yes | AU `testFuzz_SW17_ConditionalDonatedReserveHeadroomCannotStrandRefund` is a protective RED conditional liveness property; exact reserve-ceiling refund is a separate positive boundary. |
| SW-18 | Upgrade registry/gateway/wrappers compatibly with live/preclaimed swap locks and then settle/refund. | Stable addresses/bindings, balances, ACL access, claim IDs and terminal cleanup. | Yes | SE `assertAssetPermissions`, compatible upgrades, independent balance/claim/terminal ledgers and mixed live/preclaimed locks. |
| SW-19 | Executor owner changes its authorized caller while an admitted swap is pending; attempt settlement, then permitted refund. | Revoked execution authority must fail without partial consumption; the recorded swap retains its documented refund route. Do not require a deliberately deauthorized caller to execute. | Yes | IN `testFuzz_SW19_CallerRotationPreservesRefundLifecycle`: real executor deauthorization, atomic execution failure, refund, restoration and fresh valid swap. |

## F. Wrapper, gateway, registry, ordinary unshield and upgrades

| ID | Lifecycle sequence / variation | Invariant or owner question | Executable coverage | Implemented evidence / remaining gap |
|---|---|---|---|---|
| AS-01 | Several users shield, transfer confidential balances, request/claim exits, shield again. | Account-level deposited/received/transferred/paid/pending amounts reconcile; no unbacked mint or lost claim. | Yes | UA `depositAgain`/`transferConfidential` plus independent source endowments, exited amounts, recipient payouts, pending balances and later claims. |
| AS-02 | Both partial-unshield overloads and full exits interleave for one source/wrapper. | One shared pending gate; no overload bypass; balance + pending + paid remains conserved. | Yes | UA all three unshield modes and shared pending/admission oracle retained across funding/configuration/upgrade sequences. |
| AS-03 | Wrong/expired/misdirected input proof or share token; replay it across user, wrapper, chain or consumer. | No FHE input/share reuse or unauthorized debit; failure preserves balances, pending state, budget and cooldown. | Yes | UA unauthenticated share, source/consumer/chain proof mutation, unauthorized debit and incorrect-decryption probes with atomic hashes. Live proof readiness/expiry parity belongs to AS-16. |
| AS-04 | Claim B before A; single then batch; retry claimed IDs; substitute ciphertext for claim ID. | Unique claims remain independent; recipient/handle/ID immutable; exactly one payout per ID. | Yes | UA single/batch ordering, `rejectClaimReplay`, paid-ID replay and ciphertext-ID substitution across pending records. |
| AS-05 | Zero-valued claim, including a token that rejects transfer(0), followed by a later valid request. | Clear pending state, pay zero safely, start only source cooldown, and restore eligibility at its boundary. | Yes | UA zero-transfer-reverting underlying fixture participates in mixed request/claim/zero-cooldown/funding actions. |
| AS-06 | Third-party claimant and different recipient process a source's zero/nonzero claim. | Claimant/recipient cannot receive the source's cooldown or redirect payout; delegated authority stays exact. | Yes | UA distinct source/recipient selection and third-party claimant; payout and source-only cooldown are checked independently. |
| AS-07 | Exhaust registry-wide credit across wrappers/users; wait, claim old requests, retry new requests. | Shared budget equals independent refill/spend history; exhausted admission never prevents an existing valid claim. | Yes | UA independent cross-wrapper credit/history oracle and active claims under exhausted admission. |
| AS-08 | Change bucket capacity/refill while partly spent, after long idle, and at saturation. | Accrue at the old rate until the update; cap new credit as specified; no free reset or corruption of pending claims. | Yes | UA `configureBudget` accounts old-rate accrual before new capacity/rate, clipping and pending-claim preservation. |
| AS-09 | Change partial/swap minima while old zero/nonzero claims and swaps remain live. | New admissions use new policy; historical claims use recorded amounts and do not become unclaimable. | Yes | UA ordinary minimum changes and SE `configureOrdinaryAndSwapMinimum` while ordinary/swaps remain live. |
| AS-10 | Request full balance, receive a later deposit/transfer, then complete the old claim and exit again. | Old claim amount stays frozen; later balances are neither burned nor paid twice; full-exit dust follows the intended rule. | Yes | UA later funding/transfer during full-balance pending requests, immutable old claim hash/amount and second exit. |
| AS-11 | Change trusted escrow while ordinary and swap requests are pending; process old claims and try new requests. | No privilege bypass for ordinary users; previously admitted claims remain processable under their original binding. **Decision:** allowed escrow-rotation operational constraints. | Yes | UA `rotateTrustedEscrow`, SE mixed ordinary requests/claims and drain/rotation enforce recorded claims and admission domains. |
| AS-12 | Attempt duplicate/rebound registration and future wrapper-template/admin changes while old wrappers are used. | Existing underlying↔wrapper bijection, rate, registry and owner remain unchanged; future wrappers use the selected template/admin. | Yes | UA duplicate/rebinding rejection plus future-wrapper configuration; historical bijection/rate/registry/template remain checked. |
| AS-13 | Compatible upgrades of registry/gateway/wrapper during ordinary pending claims, including zero claims. | Preserve balances, ACL grants, claim hashes, cooldown, budget and completion usability. | Yes | UA populated upgrade actions retain live/zero claims, budget/cooldown, balances and explicit ACL checks. |
| AS-14 | Transfer ProxyAdmin ownership with pending claims; old owner tries upgrade, new owner upgrades and claims complete. | Old admin cannot upgrade; business ownership/claims do not change merely from admin handover. | Yes | UA ProxyAdmin handover rejects old admin and checks business owner remains separate from upgrade authority. |
| AS-15 | Direct inherited shield versus gateway shield with non-exact-transfer behavior; later unshield/refund. | **Decision/release restriction:** unsupported assets cannot be admitted as if exact-transfer; reject or explicitly prohibit unsafe direct paths. | Yes | AU `testFuzz_AS15_ConditionalDirectShieldNeverMintsUnbackedClaims` contrasts protected gateway failure with inherited direct path. Protective RED probe under deliberately unsupported non-exact-transfer input. |
| AS-16 | Same local lifecycle against live CoFHE proof verification, ACL and asynchronous decrypt readiness. | Real network permissions/proof types and once-only claim/reveal behavior match the mocked assumptions. | No | EXTERNAL LIVE GATE: no live CoFHE proof generation, threshold readiness or network ACL transactions were authorized/run. Local mocks cannot close this row. |
| AS-17 | Transfer registry business ownership while claims are pending; the old/new owner attempts template, minimum, budget and trusted-escrow updates. | Correct one-step business authority, separate ProxyAdmin ownership, unchanged historical claim bindings and terminal usability. | Yes | UA `handoverBusinessOwnership` checks actual one-step Ownable transfer, rejection of all four old-owner setter families and continued claims; ProxyAdmin is separate. |

## G. Cross-subsystem scenarios that isolated suites do not establish

| ID | Lifecycle sequence / variation | Invariant or owner question | Executable coverage | Implemented evidence / remaining gap |
|---|---|---|---|---|
| XS-01 | Competition submit/replace → evaluate/finalize → qualify → capital submit/approve → real vault execution. | Only eligible latest competition evidence can establish qualification; exact current qualification/approval gates precede fund movement. | Yes | Real shared integration fixture chains latest competition evidence through finalization, registry qualification, fresh capital approval and Merkle-verified execution; superseded evidence rejected. |
| XS-02 | User deposit → capital execution → gain/loss reports → request → unwind → fee settlement → completion. | Independent investor equity and physical/position accounting reconcile through the complete funded lifecycle. | Yes | Real shared lifecycle handler connects LP deposits, requests, real capital/Merkle consumption, position-value reports, authorized unwind, fees and withdrawal with independent ledgers. |
| XS-03 | During XS-02, revoke qualification or policy, change a risk version, fail execution, retry with a fresh approval. | No unauthorized funds move; no consumed authorization or lost user claim on failure; permitted exits require explicit authorization rather than a fallback. | Yes | Real shared lifecycle handler invalidates qualification/root/risk after approval, checks exact atomic failure and retries only using an explicitly fresh valid authorization. |
| XS-04 | Ordinary unshield and swap locks use the same asset/users; bucket exhaustion, zero claims and preclaims interleave. | Intended ordinary/shared versus swap-specific admission domains remain separate; balances/claims cannot be counted twice. | Yes | SE mixed ordinary request/claim and swap lock/preclaim/settle/refund actions share real wrappers/users with independent balances, claims and ordinary admission credit. |
| XS-05 | Several manager/registry/vault pause and role changes during an existing cross-contract workflow. | Apply actual selector-level rules; failures roll back all participants; approved cleanup remains possible under stated preconditions. | Yes | Real shared manager pause/role/governance probes and local multi-component pause actions enforce actual selector-level cleanup/atomicity. |
| XS-06 | Transfer/recover actual custody while frontend/listener-visible entries remain pending; process emitted events and getters. | State/events agree; any migration/terminal interpretation is explicit. **Decision:** indexer reorg/retry behavior belongs in consumer tests, not Solidity-only invariants. | Partial | Solidity shared fixture checks lifecycle event/getter parity and recovery claim bindings. CONSUMER/POLICY GATE: indexer reorg/retry semantics and replacement-vault fulfillment are outside this test-only change. |

## H. Deployment and stateless properties: use the right test type

| ID | Condition | Invariant / property | Executable coverage | Implemented evidence / remaining scope |
|---|---|---|---|---|
| ST-01 | Fresh proxies, implementation initialization, replayed initialization, unauthorized upgrades. | Initialization/upgrade authority is exact; no uninitialized takeover window. | Yes | Existing asset upgrade, strategy/registry initialization and deployment properties; new populated manager upgrade handlers test initializer replay and separate upgrade authority. |
| ST-02 | Different deployers/nonces on two chains; changed initializer, library, salt or factory code. | Deterministic addresses only when the complete CREATE2 inputs match; wrong factory or occupied address fails closed. | Yes | CREATE2 sender/nonce/initializer/factory/collision tests plus `testFuzz_ST02_creationInputsBindEveryPredictedAddress` independently binds component salt, linked-library and constructor bytes. Separate create2 profile; live fork run still opt-in. |
| ST-03 | Role/configuration overlap, wrong chain, missing library code, test-only collapse on mainnet. | Deployment fails before creating an invalid production domain; manifest distinguishes candidates/receipts and omitted components. | Yes | Existing V2 wrong-chain/role-collapse/library/artifact/manifest/traversal properties retained. Operational timelock/Safe configuration is not simulated as complete. |
| ST-04 | Hash every commitment field, mutate one, reorder components, change domain. | Exact deterministic hashing and domain binding; no ephemeral fields or ambiguous encodings. | Yes | Existing independent fixed reference vectors, every-field mutations and deterministic hash tests; domain changes are also adversarial capital/execution actions. |
| ST-05 | Merkle input permutations, odd cardinality, duplicate leaves, missing/mutated proof nodes, maximum tree size. | Deterministic root/proof generation; invalid/mutated policies do not verify. | Yes | Existing independent root vectors, permutations, odd/max cardinality, malformed/mutated proofs and stateless fuzz properties retained. |
| ST-06 | Decoder amounts, nested calldata, receiver/owner/token/market fields, selector/facet/code changes. | Only explicit supported actions and policy-bearing arguments pass; malformed/noncanonical calls fail closed. | Yes | Existing decoder amount/nested-calldata/address/facet/selector/code mutation properties, now also exercised by execution identity and direct-share-burn policy actions. Live Pendle position coverage remains EX-16. |

## Handler and validation requirements

These requirements apply across the tables; they are not extra production
features. Existing handlers are extended in place. The shared funded handler
lives in the existing capital/vault integration file.

1. **Separate safety from progress.** Check state relationships after every
   successful action and exact rollback after every rejected action. In a
   separate bounded drain/progress phase, once liquidity, deadlines, roles,
   proof readiness and valid minima permit completion, actively finish eligible
   work and assert it succeeds. Randomly making a completion callable is not a
   proof that the campaign ever completes it.
2. **Generate both valid and invalid calls.** Do not silently return before
   every difficult path. Deliberately attempt inadmissible calls, assert the
   exact typed error, and verify balances, nonces, allowance/budget history,
   handles, request ownership and terminal state are unchanged. Unexpected
   failures must fail the campaign; keep `fail_on_revert = true` and no
   unchecked catches.
3. **Use relative boundaries, not only random magnitudes.** Generate `0`, `1`,
   divisor ± 1, balance/supply ± 1, entire balance, all-but-one, current minimum
   ± 1, limit/capacity ± 1, and deadline/unlock/window ± 1. Include equal amounts
   repeated across actors and epochs. Time must move forward; never rewind to a
   convenient valid phase after the actual deadline has passed.
4. **Assert economic meaning independently.** Use a rational/high-precision
   reference or conservation/entitlement identities with explicit unit-aware
   rounding, not production `preview*` calls or the same formula as the sole
   oracle. Specify exactly when an actor is entitled to vested/unvested gain,
   fee liability, and loss. Do not assume per-user fee equalization or claim
   lossless exit during a reported loss.
5. **Track the complete owner ledger.** Distinguish deposits, withdrawals,
   wallet-share transfers, escrowed shares, fees, donated liquidity, idle USDC,
   deployed positions, reported P&L and recoveries. Other holders' shares and
   value cannot be ignored merely because total supply and cash conserve.
6. **Randomize permitted governance.** Include reporter/operator/role changes,
   pause/resume, prospective fee/vesting settings, admission limits, risk/root
   updates, and compatible upgrades in the relevant domain. Check both allowed
   changes and prohibited changes during live work. Governance may revoke
   execution rights deliberately; tests must not require revoked rights to keep
   working. Already admitted exit/claim semantics require their own checks.
7. **Prove each meaningful path was exercised.** Record per-scenario attempts,
   expected failures, successes and the critical pre-state (such as one-unit
   residual supply or fee-bearing partial exit). Setup success counters do not
   establish randomized coverage of a later boundary. Give important properties
   a deterministic seed fixture so rare sequences do not depend on luck.
8. **Make dependency assumptions explicit.** Reported profit needs a backing
   fixture or independently valued position; a mock minting executor cannot
   prove AMM pricing; mocked CoFHE cannot prove threshold-network behavior.
   Exact-transfer USDC assumptions do not imply support for rebasing/FOT assets.
9. **Keep failures useful.** Persist the shortest sequence, actors, time/report
   history, state before failure, violated guarantee, seed and dependency
   configuration. First rule out a bad oracle, unsupported token assumption,
   stale fixture, or overly strong policy claim; do not suppress a valid failure
   just to obtain green tests.

## Decisions to settle before asserting new policy

| Topic | Required clarification |
|---|---|
| Near-empty vault / virtual balances | Who owns retained vested/unvested assets when actual supply becomes tiny or zero? Adding virtual terms must not silently strand that entitlement. No ERC4626 conversion/refactor is approved by this checklist. |
| Rounding budget | Preserve the intended asset-denominated bound and derive the deposit/redeem round-trip budget from the chosen formulas. Do not redefine the budget as a potentially expensive whole atomic share. |
| Fee-aware pricing | Define vested fee reservation/allocation across partial exits, losses and fresh deposits. Keep the approved fund-level loss-recovery model; do not silently add investor fee equalization. |
| Competition expiry | Resolve CM-11: preserve completed evaluation for late finalization, or consistently define a hard finalization cutoff. Emergency authorized cancellation is a separate privilege. |
| NAV freshness and withdrawal progress | Define report-age limits, exit SLA/priority, and any guaranteed window if a future remediation restricts withdrawals during vesting. Existing illiquidity is not automatically a contract bug. |
| Migration / external policies | Define how pending user claims continue after recovery, supported amount/decimal/reserve headroom, and direct share-burn risk coverage before those policies/assets are enabled. |

## Run the completed local batch

The user chose to run the final batch. Do not interpret Yes as a run result.
Use the repository's installed Forge and the existing profile (256 fuzz runs;
64 invariant runs × depth 32; `fail_on_revert = true`). These commands are local
simulations; they do not broadcast.

```sh
cd /Users/nilay/alphaEngine/alphaengine-contracts
set -o pipefail
forge test --offline --threads 2 -vv 2>&1 | tee /tmp/alphaengine-lifecycle-tests.log
```

CREATE2 has its existing separate linking profile:

```sh
FOUNDRY_PROFILE=create2 forge test --offline --threads 2 --match-contract DeployAlphaEngineCreate2Test -vv 2>&1 | tee /tmp/alphaengine-create2-tests.log
```

Live fork tests remain opt-in. Actual live CoFHE and the unselected Pendle
position route are not established by either local command. After the run,
classify failed test functions separately from unique root causes: R1–R3 are
known economic defects; CM-11, AS-15, SW-16/SW-17 and EX-15 include explicit
policy/domain assumptions. Unexpected handler/oracle/setup failures must be
fixed before counting a contract defect. Preserve minimized sequences and
seeds before comparing newly reproduced root causes with the Pashov report.

Method references: installed Pashov X-Ray threat profiles and Fizz property/
handler guidance, adapted to existing Foundry tests under the user's scope.
No new audit, generated Fizz tree, Echidna or Medusa campaign was launched.
