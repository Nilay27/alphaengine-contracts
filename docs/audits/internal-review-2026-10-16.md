# Internal source review — 16 October 2026

Reviewed commit: **`7ed4c49d2568bc8f89bf6b426b5c66321dbe3f5a`** (`main`).
Result: **zero confirmed findings; five unscored leads**. This is one internal
AI-assisted source pass, not an external audit or activation approval.

## Scope and method

- X-Ray skill version 2 refreshed the overview, entry points, invariants,
  dependencies, history and readiness model. The source map covers 19 authored
  logic files / 5,996 nSLOC, with deployment scripts and dependencies separate.
- A Fizz-derived requirements review inspected existing assertion bodies,
  independent oracles and reachability witnesses. The user chose reuse of the
  current Foundry/Echidna evidence instead of a second harness or broad campaign.
  The historical Echidna runs are limited to their recorded asset/control-plane
  scope; no fresh all-domain Echidna run is claimed.
- Solidity Auditor version 4.1 ran **one pass, all 12 specialties at Max**,
  against 22 authored Solidity/source-script files plus 11 explicitly included
  critical Fhenix/CoFHE/OpenZeppelin implementations. The runtime permitted
  three workers at once, so the single pass used successive groups. All 12
  workers returned; no loop, second pass or finding-memory ledger was used.
- Eleven raw leads across nine labels were merged into five leads at two
  distinct contract/function locations. Every raw mechanism has a disposition;
  no item was merged across functions. No confirmed finding was discarded.
- All 33 frozen files retain their recorded hashes. Production contracts,
  dependency pins, tests and economic assertions were not edited by this pass.

The complete assembled output is
[the audit report](../../alphaengine-contracts-pashov-ai-audit-report-20261016-151940.md).
Local provenance lives in `.solidity-auditor/runs/20261016-151940/`: scope,
all 12 raw reports, bundle hashes, tuple mapping, gate evidence, run file and
the byte-identical assembled report. The transient input bundles were cleaned
after that evidence was preserved. These local evidence directories are ignored
by Git; the report and this disposition record are the durable review entry.

## Retained leads and disposition

| Lead | Source result | What remains before promotion or a code change |
|---|---|---|
| `TaskManager.createTask`: cast shape | The pinned host source accepts zero/two plaintext cast arguments and a target type different from `returnType`. A directed shared handle can feed wrapper balance operations. | Establish an admitted untrusted caller, deployed implementation parity, real coprocessor behavior and material victim impact. AlphaEngine's ordinary typed helpers emit the canonical shape. |
| `TaskManager.createTask`: result type | Trivial-encryption and arithmetic tasks can declare a return type different from their input/operand type. | Establish the runtime's actual type rules and a victim-facing result. Source acceptance alone does not prove invalid ciphertext, excess claims or balance loss. |
| `TaskManager.createTask`: operation ID | The pinned source accepts `_31`, emits an empty operation name and returns an authorized handle. | Establish whether the runtime rejects, normalizes or completes this task and whether another holder's transfer/exit fails. |
| `USDCVaultManager.completeRedeem`: NAV timing | A shareholder can redeem using the last recognized NAV after an external position loss. Pause blocks a new loss report while pending exits remain executable. The conditional examples shift real loss to remaining holders. | FV-27 explicitly leaves report age and admission at old NAV as open policy; FV-24 intentionally preserves paused exits. Define the operating policy and selected real-market reporting process before vault activation. No arbitrary freshness limit or pause rule was added. |
| `USDCVaultManager.completeRedeem`: unrequested shares | A direct transfer of shares to FundVault, or a deposit to that receiver, leaves shares outside any request. The floor can prevent final closure; batch/recovery paths cannot consolidate them. | Determine whether irreversible protocol-held shares differ materially from the accepted fragmentation/consolidation tradeoff. The demonstrated retained value is about one whole share without compounding. No transfer lock, new orphan-share authority or weaker floor was introduced. |

The vendor leads stop short of an exploit: the access-list guard and canonical
AlphaEngine forwarding paths do not establish an unprivileged malformed-task
route. At mainnet block `515348609`, the public runtime getters report access
listing enabled and the checked simulation sender absent. The four prepared
FHE lifecycle proxies are also absent. This snapshot is not proof that the
deployed host implementation equals the pinned source, and no malformed task
was submitted. Fhenix must resolve those runtime questions.

Independent repetition does not fill a missing runtime/impact proof or settle
an explicit owner policy decision. The two vault leads therefore remain visible
for investigation, rather than becoming automatic edits to approved economics.

## Decisions preserved

The [agreed fixes](../engineering/approved-audit-fixes.md) remain authoritative:
one asset base unit / `1e12` virtual shares, real supply zero or at least `1e18`,
protocol ownership of the final virtual residual, immediate fee shares on
net-new profit after loss recovery, no fee clawback, authorized cancellation
including completed evaluations, and EX-15 share-risk coverage. AS-15, SW-16
and SW-17 remain the recorded admission/capacity restrictions. Their opt-in
protective probes remain skipped by default and are not reported as passes.

## Validation and remaining gates

[CI run 38880105498](https://github.com/Nilay27/alphaengine-contracts/actions/runs/38880105498)
passed at the exact reviewed SHA: **375 tests passed, zero failed, six expected
skips**; separate CREATE2 checks also passed. Coverage ran 364 tests with zero
failures and five expected skips: **94.23% lines, 93.61% statements, 77.90%
branches, 99.29% functions**. Deployment scripts are excluded from coverage.
ABI/layout, build/size, hygiene and final consistency gates passed. The current
CI evidence replaces the earlier in-progress status; full local coverage was
not restarted.

The refreshed local reports are `x-ray/x-ray.md`, `entry-points.md`,
`invariants.md`, `architecture.svg` and
`x-ray/evidence/7ed4c49/fuzz-requirements.md`. X-Ray's **FRAGILE** readiness
label concerns governance/live integration and is not a vulnerability finding.
Two focused local compositions remain: the zero-transfer-reverting token
through the controller/escrow zero-refund path, and unsolicited vault shares.
Extend the owning tests if one becomes an approved concrete requirement;
another broad campaign was not required for this source pass.

Independent external review, Fhenix whitelisting and live permission/decryption
checks, governance handover, a selected real Pendle enter/hold/unwind lifecycle,
recovery-destination request fulfillment and NAV operating policy remain open
activation/release gates as applicable to each product.

The [mainnet preparation](../engineering/mainnet-preparation-2026-10-16.md)
passed a fresh local Arbitrum One fork rehearsal, with all 24 explorer
verification commands prepared. **No mainnet signing, broadcast or explorer
submission occurred at that review checkpoint.** The subsequent user-broadcast
deployment and accepted bootstrap handover are recorded in the confirmed
mainnet manifest. The omitted vault stack remains outside that deployment.
