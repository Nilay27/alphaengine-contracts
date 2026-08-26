# Fhenix Private Audit Readiness

- Status: preparation in progress; repository is not yet frozen for audit
- Audit partner: Fhenix internal security and efficiency review
- Designated reviewer: `@liorbond`
- Audit commit: `TBD`
- Target freeze: after the strategy/confidential-swap separation and validation gate

## Proposed scope

The proposed review scope is the contracts used by AlphaEngine's Fhenix/CoFHE integration after the approved separation:

- `AlphaEngineStrategyIntentController`
- `AlphaEngineConfidentialSwapController`
- `AlphaEngineConfidentialSwapEscrow`
- `AlphaEngineFHERC20ERC20Wrapper`
- `AlphaEngineV4SwapExecutor`
- contract-owned interfaces, deployment scripts, upgrade scripts, and tests required to establish their behavior

The exact paths and commit SHA must be updated after implementation. Do not represent this document as a frozen scope until then.

## Explicitly out of scope

- the future `AlphaEngineFundVault` and all LP share/NAV/fee/allocation accounting;
- listener, SDK, simulation, ranking, and frontend repositories;
- AVS/EigenLayer middleware;
- batching, leverage loops, arbitrage, generic UEI, and arbitrary-call execution;
- production/mainnet deployment transactions;
- economic or legal review of AlphaEngine's fund-management model.

## Trust and privilege assumptions to confirm

- Proxy-admin and contract-owner addresses are trusted administrative roles.
- Strategy and swap listener/operator roles are trusted to perform only their documented family-specific actions.
- The swap executor is callable only through the authorized swap custody boundary.
- Protocol-specific PoolManager behavior and official Fhenix contracts are external dependencies.
- No intent controller holds token custody.
- Swap escrow custody is temporary and per intent; it is not pooled LP custody.

## Known integration considerations

- Production contracts are pinned to the exact dependency commits recorded by git submodules.
- Foundry tests use a repo-owned CoFHE task-manager compatibility harness because upstream Foundry mock parity does not currently match the pinned production package cleanly.
- `AlphaEngineFHERC20ERC20Wrapper` contains a temporary encrypted-amount unshield extension required by the current settlement path; its production compatibility and removal trigger must be reviewed with Fhenix.
- Official package behavior is authoritative over stale or untagged documentation.
- The target Fhenix network, chain ID, canonical contract addresses, supported compiler/EVM profile, and package-version matrix must be confirmed before deployment.

## Audit package checklist

- [ ] Add the designated reviewer to the private repository.
- [ ] Complete the strategy/confidential-swap separation.
- [ ] Record the audit commit SHA and branch/tag.
- [ ] List exact in-scope source and script paths.
- [ ] Preserve dependency commit SHAs.
- [ ] Capture ABI hashes/artifacts.
- [ ] Capture storage layouts for each upgradeable contract.
- [ ] Record test, fuzz, invariant, integration, and coverage results.
- [ ] Record known findings, limitations, and accepted external assumptions.
- [ ] Record testnet deployment addresses separately from any future mainnet manifest.
- [ ] Confirm deploy/upgrade chain checks.
- [ ] Confirm no secrets, `.env` values, private keys, or broadcast artifacts are committed.

## Reproducible verification

```bash
git submodule update --init --recursive
forge fmt --check
forge build --offline
forge test --offline
forge coverage --offline --ir-minimum --report summary
git diff --check
```

Record the exact command outputs and tool versions against the frozen audit commit.

## Immutable-review protocol

- The reviewer audits one exact commit SHA.
- Do not force-push, amend, squash, or rewrite the frozen audit history.
- Each finding receives a separate traceable remediation commit.
- Any post-audit deployment commit requires an explicit delta review from the frozen SHA.
- Do not describe a deployment as audited if its bytecode comes from an unreviewed commit.

## Open confirmations for Fhenix

- Target mainnet launch window and chain/network identifiers.
- Required whitelist identities and repository permissions.
- Expected Fhenix package and contract-address versions.
- Whether Fhenix wants only the confidential-swap/FHE surface or the complete contracts repository included in its internal review report.
- Preferred format for findings, remediation responses, and final acknowledgement.
