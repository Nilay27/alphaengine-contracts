# alphaengine-contracts

Foundry-only Solidity repo for AlphaEngine on-chain intent entrypoints.

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

## Approved pre-audit separation

The current combined controller and swap-custody naming are being separated before the Fhenix private audit:

- strategy intents remain an AlphaEngine strategy subsystem;
- individual-user confidential swaps move to a dedicated swap controller and transient escrow module;
- the existing V4 executor remains protocol-specific and separately bounded; and
- `AlphaEngineFundVault` is reserved for future pooled LP fund management and is not part of this refactor.

The behavior-preserving plan and one-day execution gate are documented in
`docs/engineering/strategy-swap-separation-plan.md`.

## Non-goals in V1

- Uniswap hooks
- AVS/EigenLayer middleware registration
- Result posting
- Swap batching, leverage-loop, arbitrage, or UEI families
- Hardhat scaffold or CI

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
