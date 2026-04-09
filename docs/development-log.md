# Development Log

## 2026-04-09 — Initial scaffold

### Added
- Foundry-only repo scaffold for AlphaEngine contracts.
- Strict Solidity-specific `AGENTS.md` with upgradeability, coverage, fuzz, and invariant guardrails.
- V1 contract boundary locked to one upgradeable TA-family intent controller.

### Decisions
- Transparent proxy + `ProxyAdmin` for upgrades.
- EigenCompute-only in v1; no AVS registration or middleware.
- State + event are canonical.
- Foundry is the only framework in v1.
- Current pinned `cofhe-contracts@v0.1.3` uses `bytes32` encrypted handles, not the older `uint256` handle shape.
- Current pinned OpenZeppelin `TransparentUpgradeableProxy` deploys its own `ProxyAdmin`; deployment scripts derive and report the admin address instead of deploying it separately.

### Temporary Debt
- Upstream `cofhe-mock-contracts` parity with current `cofhe-contracts` remains unresolved on the Foundry path.
  - Owner: AlphaEngine contracts repo
  - Removal trigger: verified upstream version matrix or maintained Foundry mock package that matches the pinned production `cofhe-contracts`

## 2026-04-09 — Foundry compatibility harness

### Added
- Repo-owned Foundry CoFHE compatibility harness for the exact v1 contract surface:
  - encrypted input verification via `verifyInput`
  - handle access grants via `allow`
  - deterministic mock-value assertions for stored `bytes32` handles
- Unit, fuzz, and invariant suites now run cleanly against the current production `cofhe-contracts` package without depending on the stale upstream Foundry wrapper.

### Decisions
- Keep production contracts pinned to current `cofhe-contracts` semantics (`bytes32` handles).
- Do not downgrade production dependencies to match older mock-contract packages.
- Keep Foundry canonical and isolate upstream mock-package lag as external compatibility debt.
- Do not track the stale upstream `cofhe-mock-contracts` package as an active repo dependency in v1.
- Explicitly exclude the transparent-proxy admin address from unauthorized-caller fuzz checks because proxy-admin reverts happen before implementation-level authorization logic.

### Next Steps
- Confirm the current package/version matrix directly with Fhenix.
- Keep local compatibility harness until an upstream Foundry-compatible replacement is verified.
