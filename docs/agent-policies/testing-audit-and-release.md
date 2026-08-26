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
6. Run the named `solidity-auditor` skill at the stage gates defined by the
   approved implementation plan. Internal skill output complements rather than
   replaces independent external review.

## Documentation

Keep `docs/development-log.md`, architecture, testing strategy, deployment
manifests, and audit-readiness records synchronized with the code and scope.
