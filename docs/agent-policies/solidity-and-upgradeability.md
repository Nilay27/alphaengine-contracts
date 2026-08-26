# Solidity and upgradeability policy

Load this policy for Solidity implementation, storage, proxies, dependencies,
deployment, or release work.

## Upgradeability

1. Use initializer-based setup only. Implementation constructors are prohibited
   except `_disableInitializers()`.
2. Preserve proxy compatibility unless an explicit breaking migration is
   approved and documented.
3. Storage evolution is append-only. Never delete, reorder, or reinterpret
   existing slots; maintain storage gaps deliberately.
4. Transparent proxies with `ProxyAdmin` are the only approved upgrade pattern
   for v1 and the confidential-vault phase.
5. Capture and compare storage layouts for every implementation change.

## Solidity standards

1. Use one pinned compiler version, keep warnings clean, and use explicit
   visibility and data locations.
2. Prefer named structs and enums for listener-facing state.
3. Keep storage packing deliberate without sacrificing auditability.
4. Avoid inline assembly unless necessity is documented and directly tested.
5. Use custom errors for repository-owned failure paths; no repository-owned
   revert strings in production contracts.

## Dependency discipline

1. Pin exact dependency revisions.
2. Import canonical OpenZeppelin and Fhenix interfaces; do not duplicate them
   locally.
3. Temporary compatibility shims must record owner, removal trigger, and
   expected removal phase/date in `docs/development-log.md`.
4. Do not import Uniswap, Pendle, Morpho, Aave, or other protocol dependencies
   into an intent/strategy controller or custody vault.
5. `@uniswap/v4-core` is allowed only for pinned pool fixtures and a separately
   approved executor. Do not add `@uniswap/v4-periphery` without a documented
   concrete fixture blocker.
6. Refresh linked and pinned dependencies before trusting integration results.

## Toolchain

Foundry owns builds, formatting, unit tests, fuzzing, invariants, integration,
coverage, scripts, ABI generation, and storage-layout checks. Hardhat is outside
the v1 production toolchain.
