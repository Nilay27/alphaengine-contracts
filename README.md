# alphaengine-contracts

Foundry-only Solidity repo for AlphaEngine on-chain intent entrypoints.

The approved restructuring is implemented from the single canonical plan at
`docs/engineering/strategy-manager-fund-vault-implementation-plan.md`.

Implementation has reached the Stage 11 first-pass checkpoint. The independent
Qualification Registry, Competition Strategy Manager, Capital Strategy
Manager, confidential asset registry/gateway, confidential swap controller,
swap escrow, and bound V4 execution path are implemented and tested locally.
Fresh paused deployment, manifest, governance-action, ABI/topic, and listener
cutover tooling is implemented, and the complete first-pass validation evidence
is recorded under `docs/releases/`. The fresh contracts have not been deployed
to a public testnet, and the second-pass FundVault stack is not yet implemented.

## Historical testnet scope

- Historical upgradeable testnet contracts: `AlphaEngineIntentController` and `AlphaEngineConfidentialVault`
- Current TA / strategy-allocation intent family
- Current confidential swap-intent submit / execute / refund phase
- One listener/operator address
- Lifecycle:
  - strategy intents: `submit + cancel`
  - swap intents: `submit + execute`, with terminal `refund` rescue for expired or pause-blocked live swaps
- EigenCompute-operated only
- Encrypted market selection is submitted as an encrypted `marketId` handle, not a plaintext market address
- Encrypted component handles stored/emitted as `bytes32[]` using the current CoFHE Solidity package
- Swap input amounts are submitted as encrypted FHERC20 `InEuint64` amounts and locked through `AlphaEngineConfidentialVault`
- Foundry tests use a repo-owned CoFHE task-manager compatibility harness for the exact v1 surface we rely on

## Approved restructuring

The combined controller and swap-custody implementation has been removed from
the active source tree after full functional replacement. Its deployment
manifest, ABI, storage layouts, addresses, and Git history remain immutable
historical evidence. The replacement boundaries are:

- strategy intents remain an AlphaEngine strategy subsystem;
- individual-user confidential swaps move to a dedicated swap controller and transient escrow module;
- wrapper administration now lives in an append-only confidential asset
  registry, while ordinary shield/unshield convenience calls use a separate
  non-custodial gateway;
- the existing V4 executor remains protocol-specific and separately bounded; and
- the future pooled fund is a separate second pass: `AlphaEngineFundVault`
  holds assets and shares, `AlphaEngineUSDCVaultManager` owns USDC-only
  deposits/withdrawals and NAV accounting, and
  `AlphaEngineVaultExecutionManager` owns Merkle-verified deployment policy.

The earlier single strategy-controller separation proposal is retained as
historical context in `docs/engineering/strategy-swap-separation-plan.md` and
is superseded by the current StrategyManager/FundVault implementation plan.

## Non-goals in V1

- Uniswap hooks
- AVS/EigenLayer middleware registration
- Result posting
- Swap batching, leverage-loop, arbitrage, or UEI families
- Hardhat scaffold

## Toolchain and CI

- Canonical CI Foundry release: `v1.7.1`.
- GitHub Actions are commit-pinned and run with read-only repository
  permissions.
- Pull-request CI runs formatting, build/size, the complete test suite,
  coverage, repository hygiene, ABI parity, and storage-layout parity.
- Nightly and release-candidate workflows increase fuzz and invariant runs.
- The current local baseline was originally captured on the historical nightly
  recorded in `docs/audits/internal/baseline-49d96e8-evidence.md`; CI is the
  authoritative stable-toolchain gate.

## Current Fhenix testing stance

- Production contracts stay pinned to the current `cofhe-contracts` package.
- The upstream Foundry mock wrapper is not used in v1 because it is not aligned cleanly with the current contract package.
- Local Foundry tests cover encrypted input verification, handle storage, and permission grants through a repo-owned mock task manager instead.

## Listener-facing contract surface

- Source ABIs live under `ABI/v2/`; the canonical generated selector, typed
  error, and event-topic map is `ABI/v2/listener-surface.json`.
- Listener cutover, dual-read, reorg, deduplication, and getter-reconciliation
  requirements are documented in `docs/migrations/v2-listener-cutover.md`.
- Competition qualification never implies capital approval. Capital and swap
  consumers use their independent event, nonce, pause, and lifecycle domains.

## Commands

```bash
git submodule update --init --recursive
forge fmt --check
forge build --offline
forge test --offline
forge coverage --offline --ir-minimum --report summary --skip DeployAlphaEngineV2
python3 script/reference/alphaengine_listener_surface.py --check
```
