# Agreed audit fixes — 2026-10-15

This is the agreed implementation scope for the reviewed findings. Preserve the
existing failing economic assertions; update fixtures only for these rules.

1. **Rounding: virtual conversion offsets.** Use one virtual USDC base unit
   and `1e12` virtual share units in deposit/redemption conversion. Shares
   remain 18 decimals; USDC remains 6. Both previews and execution agree.
2. **Rounding: minimum real supply of one whole share (`1e18`).** A deposit
   must establish at least that supply. Every redemption completion, whether
   or not profit is vesting, must leave either zero supply or at least `1e18`.
   Only the full-supply exit waits for vesting to finish; other eligible exits
   proceed during vesting. Full closure requires all managed assets in idle
   USDC, pays the virtual residual to the protocol fee recipient, and resets
   managed NAV to zero for re-entry. Requests continue earning until completion;
   there is no request-time price lock or per-wallet minimum.
3. **Fee shifting/erasure: mint performance-fee shares immediately.** Recover
   prior recognized losses first when calculating feeable profit. Charge the
   configured fee only on net-new profit, mint its shares at the pre-report
   recognized price using the same virtual offsets, and vest `profit - fee`.
   There is no special recovery pricing. Issued fee shares participate in later
   vesting and losses like other shares; losses do not claw them back. Vesting
   cleanup mints no further fee. For the fresh deployment, remove obsolete
   pending-fee getters/error; fund-level loss-recovery accounting stays intact.
4. **Competition ending: authorized callers only.** Add the existing
   `COMPETITION_CANCELLER_ROLE` check to `cancelExpiredCompetition`, keeping its
   deadline/status checks. Both cancellation entry points require that role;
   finalization keeps its existing `FINALIZER_ROLE`. Authorized callers retain
   the ability to cancel completed evaluations. No extra completed-count guard.
5. **EX-15: require share-risk coverage for ERC4626 exits.** Before execution,
   `redeem`/`withdraw` must include their target share token with nonzero
   `maxSpend`; otherwise revert with `ExitShareAssetNotRiskBound`. Existing
   configured caps, actual balance deltas and rolling spend remain authoritative.
   No new storage, pricing, decoder or custody path.

No ERC4626 migration, treasury seed/transfer lock, extra fee, new settlement role,
or deployment is part of this change. Accepted asset limitations are recorded below.

## Accepted asset restrictions — 2026-10-16

- AS-15: the registry owner must exclude fee-on-transfer/non-exact-transfer assets.
- SW-16: exclude the 44–46-decimal assets in the unsupported signed-amount probe;
  review decimal/rate/amount bounds before admitting a new asset.
- SW-17: accept the inferred `uint64` reserve ceiling for intended USDC/WETH-like
  assets (about 18.45 trillion whole tokens with six confidential decimals).
  Reassess before admitting unusually abundant assets or changing wrapper precision.

These are operator asset-admission restrictions and an accepted capacity limit,
not new on-chain guards. The three strict protective probes are skipped by default;
`RUN_ACCEPTED_ASSET_LIMIT_PROBES=true` enables them and still reproduces failures.
EX-15 retains its default-suite protective assertion and now tests missing/zero
share risk, undersized limits and exact-limit exits for both ERC4626 selectors.

Focused validation: the two companion boundary/refund checks pass and the three
probes skip by default. Opting in reproduces all three original failures; their
bodies are unchanged apart from the gate. Production source hashes are unchanged
in this test-policy step.

## Validation and handoff

Passed: 100 focused unit/regression checks and 3 integration checks. The five
original failing vault invariant functions remain byte-identical; their economic
bounds are unchanged. Formatting and hygiene pass. Existing ABI entries are
unchanged; ABI/layout/size comparisons pass using source-hash-verified focused
build artifacts. The broader rebuild was stopped after seven minutes compiling
other test files. CM-11 preserves its public-cancellation protection, with
the expected error updated to the agreed access-control failure. The owner's
affected-suite run passed 117 checks and exposed one setup error: a fixture
rounded remaining net profit down instead of up. The new boundary regression
failed before the fixture correction; afterward all 7 targeted checks passed,
including FV-01 with the original seed (64 runs, 2,048 calls). The owner rerun passed
119 affected checks; CREATE2 passed 12 with the network-fork test skipped. The full
suite passed 372, failed the four existing conditional probes, and skipped three.
Owner post-EX-15 full suite: 375 passed, zero failed, six expected skips;
EX-15's protective invariant, deterministic check and 256-case fuzz test pass.
Post-EX-15 local CREATE2 checks passed 12 with one network-fork skip.

EX-15 compilation and the deterministic both-selector smoke check pass. Existing
ABI entries and normalized storage layout are unchanged; only the new error is
added to the ABI. The subsequent fresh-deployment cleanup intentionally removes
`pendingFeeAssets()`, `pendingFeeBps()` and `ActiveFeePending`; the report event's
fee argument is named `feeAssets`. Event topics/types are unchanged. This is a
fresh-address API, not an in-place migration. Economic assertions retain their
original bounds; obsolete zero-entitlement checks are removed.
After cleanup, the complete suite again passes 375 with zero failures and six
expected opt-in/profile skips. This is the source to commit before fork rehearsal.
Fork evidence for the committed revision goes under
`deployments/v2/rehearsals/create2-audit-fixes-2026-10-16/` (Git-ignored).

```sh
cd /Users/nilay/alphaEngine/alphaengine-contracts
set -o pipefail
forge test --offline --threads 2 -vv 2>&1 | tee /tmp/alphaengine-all-after-ex15.log
FOUNDRY_PROFILE=create2 forge test --offline --threads 2 --match-contract DeployAlphaEngineCreate2Test -vv 2>&1 | tee /tmp/alphaengine-create2-after-fixes.log
```

No broadcast is part of these checks. Existing audit artifacts remain untouched.
