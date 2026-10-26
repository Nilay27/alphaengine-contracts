# Security policy

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/Nilay27/alphaengine-contracts/security/advisories/new)
to contact the maintainers. On the repository's Security tab, select
**Report a vulnerability**. Do not disclose exploit details in public issues,
pull requests, or discussions before coordinated disclosure.

Include the affected contract/file and commit, chain and deployment address
if applicable, expected versus observed behavior, potential impact, and a
minimal reproduction or proof of concept. Never send private keys, seed
phrases, credentials, or private user strategy data.

Use a local fork or test environment for reproduction. Do not move other
users' funds or disrupt live services. Coordinate disclosure timing with the
maintainer after the report has been assessed.

## Scope and review status

Reports about current `main` and deployed AlphaEngine contracts are welcome.
Include an exact commit or deployment address: historical branches and ABI
snapshots do not imply an actively supported deployment. Dependency issues
should identify the pinned revision and affected AlphaEngine path.

Public source availability is not a production-safety claim. The
[internal review record](docs/audits/internal-review-2026-10-16.md) describes
the reviewed commit, retained leads, and validation limits. Current deployment
and release gates are tracked in the
[readiness record](docs/audits/fhenix-private-audit-readiness.md).
