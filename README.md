# alphaengine-contracts

Foundry-only Solidity repo for AlphaEngine on-chain intent entrypoints.

## V1 scope

- One upgradeable production contract: `AlphaEngineIntentController`
- One intent family: TA / strategy-allocation
- One listener/operator address
- Lifecycle: `submit + cancel`
- EigenCompute-operated only
- Encrypted component handles stored/emitted as `bytes32[]` using the current CoFHE Solidity package
- Foundry tests use a repo-owned CoFHE task-manager compatibility harness for the exact v1 surface we rely on

## Non-goals in V1

- Uniswap hooks
- AVS/EigenLayer middleware registration
- Result posting or settlement
- Swap, leverage-loop, arbitrage, or UEI families
- Hardhat scaffold or CI

## Current Fhenix testing stance

- Production contracts stay pinned to the current `cofhe-contracts` package.
- The upstream Foundry mock wrapper is not used in v1 because it is not aligned cleanly with the current contract package.
- Local Foundry tests cover encrypted input verification, handle storage, and permission grants through a repo-owned mock task manager instead.

## Commands

```bash
forge fmt
forge build
forge test
forge coverage
```
