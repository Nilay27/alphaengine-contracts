# alphaengine-contracts

Foundry-only Solidity repo for AlphaEngine on-chain intent entrypoints.

The approved restructuring is implemented from the single canonical plan at
`docs/engineering/strategy-manager-fund-vault-implementation-plan.md`.

Implementation has reached the Stage 8 review checkpoint. The independent
Qualification Registry, Competition Strategy Manager, Capital Strategy
Manager, confidential asset registry/gateway, confidential swap controller,
swap escrow, and bound V4 execution path are implemented and tested locally.
The fresh contracts have not been deployed to a public testnet, Stage 9
deployment/listener migration remains pending, and the second-pass FundVault
stack is not yet implemented.

## Current testnet scope

- Current upgradeable testnet contracts: `AlphaEngineIntentController` and `AlphaEngineConfidentialVault`
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

The current combined controller and swap-custody naming are being separated before the Fhenix private audit:

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

- `submitStrategyIntent(InEuint128 encryptedMarketId, bytes32 timeframeKey, InEuint128[] encryptedComponents, uint40 deadline)`
- `StrategyIntentSubmitted` emits the encrypted `marketIdHandle`, not a plaintext market address
- Off-chain listener/runtime resolves the decrypted plaintext `marketId` through the temporary shared market registry currently authored in `simulation-service`
- `submitSwapIntent(address inputWrapper, bytes32 routeKey, InEuint64 encryptedInputAmount, uint40 deadline)`
- `SwapIntentSubmitted` emits both the vault-returned locked amount handle and unshield request handle as canonical
- `executeSwapIntent(bytes32 intentId, address outputWrapper, uint64 decryptedInputAmount, uint256 minOutputAmount, bytes decryptionProof, bytes executionData)`
- `refundSwapIntent(bytes32 intentId, uint64 decryptedInputAmount, bytes decryptionProof)` for expired or pause-blocked live swaps
- `routeKey` remains metadata for off-chain route semantics; the concrete execution path is supplied through a dedicated executor boundary

## Commands

```bash
git submodule update --init --recursive
forge fmt --check
forge build --offline
forge test --offline
forge coverage --offline --ir-minimum --report summary
```
