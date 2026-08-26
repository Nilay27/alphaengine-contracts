# Fhenix Private Audit Readiness

- Status: first-pass implementation checkpoint recorded; repository is not yet frozen for audit
- Audit partner: Fhenix internal security and efficiency review
- Designated reviewer: `@liorbond`
- First-pass implementation checkpoint: `365b3e668217b1f1ca4caede9e6b8fb60526d430`
- Audit commit: `TBD`
- Target freeze: after the FundVault pass, consolidated internal security cadence, remediation, and production Fhenix validation

## Proposed scope

The proposed review scope is the contracts used by AlphaEngine's Fhenix/CoFHE integration after the approved separation:

- `AlphaEngineTraderQualificationRegistry`
- `AlphaEngineCompetitionStrategyManager`
- `AlphaEngineCapitalStrategyManager`
- `AlphaEngineConfidentialSwapController`
- `AlphaEngineConfidentialSwapEscrow`
- `AlphaEngineConfidentialAssetRegistry`
- `AlphaEngineConfidentialAssetGateway`
- `AlphaEngineFHERC20ERC20Wrapper`
- `AlphaEngineV4SwapExecutor`
- `AlphaEngineStrategyHashLib` and `AlphaEngineExecutionHashLib`
- contract-owned interfaces, v2 deployment/manifest tooling, ABIs, layouts,
  listener surface, and tests required to establish their behavior

The exact first-pass paths and implementation SHA are recorded in
`docs/releases/first-pass-implementation-checkpoint.md`. Do not represent this
document as a frozen audit scope until the final candidate SHA is recorded.

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
- [x] Complete the strategy/confidential-swap separation.
- [x] Record the first-pass implementation checkpoint and Stage 10 evidence.
- [ ] Record the audit commit SHA and branch/tag.
- [x] List exact first-pass source and script paths.
- [ ] Preserve dependency commit SHAs.
- [x] Capture first-pass ABI hashes/artifacts and listener surface.
- [x] Capture storage layouts for each first-pass upgradeable contract.
- [x] Record first-pass test, fuzz, invariant, integration, and coverage results.
- [ ] Record known findings, limitations, and accepted external assumptions.
- [ ] Record testnet deployment addresses separately from any future mainnet manifest.
- [x] Confirm fresh deployment chain/config checks and independent ProxyAdmins.
- [ ] Confirm no secrets, `.env` values, private keys, or broadcast artifacts are committed.

## Reproducible verification

```bash
git submodule update --init --recursive
forge fmt --check
forge build --offline
forge test --offline
forge coverage --offline --ir-minimum --report summary --skip DeployAlphaEngineV2
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
