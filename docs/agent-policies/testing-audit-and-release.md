# Testing, audit, and release policy

Load this policy for every Solidity behavior change, custody path, deployment,
audit, release, or production-readiness claim.

## Foundry validation

1. Target 100% coverage for repository-owned logic-bearing contracts and
   libraries. Exclude interfaces, mocks, scripts, vendored dependencies, and
   proxy boilerplate.
2. Add unit tests for every success and repository-owned revert branch.
3. Add fuzz tests from day one for nonces, uniqueness, bounds, authorization,
   deadlines, and identifier/hash behavior.
4. Add invariant scaffolding from day one and custody/accounting invariants
   before any real asset path is complete.
5. Every state-changing external function requires an explicit event assertion.
   Assert submit/cancel/admin events, payload-hash determinism, nonce
   monotonicity, and state/getter/event parity.
6. Fhenix work directly tests encrypted-input internalization and permission
   grants when mocks permit; otherwise disclose missing parity while retaining
   full coverage of repository-owned logic.

## Boundary, liveness, and invariant-handler discipline

These rules are mandatory for every contract state machine, custody path,
asynchronous request, and invariant handler.

1. Write deterministic unit tests before relying on fuzz or invariant coverage.
   Every amount-bearing path must cover zero, below balance, exact balance,
   above balance, maximum supported value, and an uninitialized account where
   the dependency distinguishes it from an initialized zero balance.
2. Treat dependency semantics as authoritative. In particular, a confidential
   transfer may return an initialized encrypted zero instead of reverting.
   Tests must inspect the returned plaintext in the mock and exercise the
   resulting lifecycle rather than assuming ordinary ERC20 failure semantics.
3. Every reachable live or custody-bearing record must retain a testable
   terminal path after zero-valued results, dependency preemption, pause,
   expiry, callback reordering, and partial asynchronous completion. A guard
   such as `amount != 0` must never make cleanup unreachable.
4. Do not constrain fuzzed inputs to the happy path merely to avoid reverts.
   Every `bound`, early return, and handler precondition must correspond to a
   true protocol precondition and must be reviewed for excluded adversarial
   states. Model invalid and boundary actions explicitly.
5. Unchecked `catch {}` blocks are prohibited in invariant handlers. An action
   expected to succeed must propagate any revert. An action expected to fail
   must assert the exact allowed error selector and prove all coupled state is
   unchanged. Unknown or newly observed errors fail the run and require manual
   review; never expand an expected-error list mechanically.
6. Keep Foundry invariant `fail_on_revert = true`. If a handler catches a revert
   to classify it, an unexpected selector must explicitly fail the handler.
7. Prevent vacuous passes. Track attempts and successful transitions for
   meaningful actions, and demonstrate that deposits, live records,
   settlements, refunds/cleanup, replays, and emergency transitions are
   actually reached during the configured campaign.
8. Stateful invariants must include both safety and liveness:
   - safety: conservation, backing, exact deltas, replay resistance, state/event
     parity, and terminal-state monotonicity;
   - liveness: once documented preconditions hold, settlement, withdrawal,
     refund, or cleanup does not unexpectedly revert or remain permanently
     unreachable.
9. Test adversarial ordering across public dependency surfaces. A public claim,
   callback, keeper action, pause, or external settlement may occur before the
   protocol's preferred transaction; the later authorized path must either
   reconcile that state or fail without stranding assets.
10. Cross-asset tests maintain independent per-asset ghost ledgers. Never add
    raw units of assets with different decimals or prices. AMM output parity
    belongs in a differential integration suite against an independent
    PoolManager/reference path; escrow invariants prove measured output,
    minimum-output enforcement, wrapper conversion, and atomic rollback.

Methodology reference: [Finding Denial of Service Bugs At Scale With Invariant
Tests](https://allthingsfuzzy.substack.com/p/finding-denial-of-service-bugs-at).
The durable lesson is that excessive preconditioning and ignored handler
failures create false negatives; important functions must not unexpectedly
revert once their real documented preconditions hold.

## Required release gate

Run and record, as applicable:

- `forge fmt --check`;
- offline build and complete test suite;
- unit, fuzz, invariant, and integration suites;
- coverage;
- ABI and storage-layout checks;
- deployment-script chain-id and configuration checks;
- `git diff --check`.

Use focused Conventional Commits. Keep audit-response changes isolated and
reference the finding they address.

## External audit discipline

1. An external audit reviews one immutable commit SHA. Record the exact SHA and
   scope in the audit-readiness document.
2. Do not amend, force-push, or rewrite frozen audit history.
3. Disclose limitations, mock/production differences, temporary extensions,
   deployment assumptions, and out-of-scope components.
4. A post-freeze commit is not reviewed without an explicit delta review.
5. The strategy/swap separation uses fresh deployment architecture; do not
   delete/reorder legacy storage through an in-place upgrade.
6. Run heavyweight security skills only at the consolidated
   end-of-implementation gates defined by the approved implementation plan.
   Do not run them between ordinary implementation stages.
7. At every consolidated internal-audit gate, use this order:
   1. pass the repository's Foundry unit, fuzz, invariant, integration,
      coverage, ABI, layout, size, deployment, and hygiene gates;
   2. run or refresh `x-ray` to produce the source-verified entry-point map,
      threat/trust model, dependency map, test inventory, git-risk analysis,
      and readiness verdict;
   3. resolve or explicitly disposition X-Ray readiness gaps;
   4. run `fizz` in guided mode on its first use, using the X-Ray output as its
      required protocol context, review its entry-point/property selection,
      and execute the generated Medusa/Echidna campaigns where the dependency
      runtime supports them;
   5. reproduce and remediate Fizz violations, run `fizz-sync` after relevant
      contract changes, and refresh X-Ray if production entry points, roles,
      flows, dependencies, or material test evidence changed;
   6. run `solidity-auditor --file-output` only after the readiness and fuzzing
      work is current, providing the X-Ray outputs as context while requiring
      every finding to be verified against source;
   7. include critical dependency implementations explicitly when their
      semantics affect repository safety, because the default auditor scope
      excludes vendored `lib/` code.
8. Fizz complements rather than replaces repository-owned Foundry tests. Its
   generated handlers must obey this policy's boundary, liveness,
   expected-error, and no-unchecked-catch rules. A CoFHE/Echidna/Medusa runtime
   incompatibility must be documented with the exact attempted scope; it does
   not permit removing the equivalent Foundry invariant coverage.
9. Targeted Solidity-auditor re-audits are reserved for fixes arising from the
   consolidated audit. Refresh X-Ray only when architecture/entry points/trust
   boundaries change; rerun or sync Fizz when a finding changes a fuzzed state
   machine or property.
10. Internal skill output complements rather than replaces independent
    external review.

## Documentation

Keep `docs/development-log.md`, architecture, testing strategy, deployment
manifests, and audit-readiness records synchronized with the code and scope.
