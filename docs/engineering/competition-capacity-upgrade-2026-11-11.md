# Competition capacity upgrade

Upgrade the existing Competition Manager proxies with one implementation build,
Sepolia first. Set each current Arena round to 512. Every other round uses the
effective default of 256 until configured. No initializer is called. The script
checks the chain, signer, proxy slots, current implementation hash, admin roles,
and the target round's open submission window before queuing transactions.

| Network | Proxy | Target round | Foundry account |
|---|---|---|---|
| Arbitrum Sepolia | `0x9CBF3917Ff31E41393e5D992b3bdbf1fC9C80744` | `0x5e361d7809649fb68530babe18e33537abf553d09b986b38889f606cea1cb317` | `alphaengine-deployer` |
| Arbitrum One | `0x7fFcDa0A08401AcF1d114C83B32cE439C48c3681` | `0xda6ffb7ec090a3eb2c19f17f18e3c22e96b19b23f7043f5e56ac04f2e9aea708` | `alphaengine-mainnet-deployer` |

Sepolia also picks up the [previously approved expired-round cancellation
restriction](approved-audit-fixes.md), which is already deployed on Arbitrum One.
The same implementation then enforces the restriction on both networks. The
submission ABI and event schema continue to support the existing dashboard and
listener. The new cap uses one slot from the storage gap, separate from the
256-entry rolling timestamp ring and qualification limit.

Run from `alphaengine-contracts` with Foundry 1.8.5 and solc 0.8.26 installed.
Set `ARBITRUM_SEPOLIA_RPC_URL` and `ARBITRUM_RPC_URL` through your normal RPC
configuration. For explorer verification, set `ETHERSCAN_API_KEY` through your
usual local configuration. The commands use the default build profile on both
chains.

## Sepolia

Dry run:

```sh
FOUNDRY_PROFILE=default forge script script/UpgradeCompetitionCapacity.s.sol:UpgradeCompetitionCapacity \
  --sig 'run(uint256)' 421614 --rpc-url arbitrum_sepolia \
  --sender 0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d \
  --slow --no-proxy --offline
```

For the keystore broadcast and Arbiscan source verification, add
`--account alphaengine-deployer --broadcast --verify --verifier etherscan`.
The script deploys the implementation, pauses the manager, upgrades the proxy,
sets the round's cap to 512, and unpauses. `--slow` waits for each successful
receipt before sending the next transaction. A run cannot safely be restarted
from scratch after a partial broadcast. Inspect the receipt file and live
implementation, pause, and cap values before resuming. Use Foundry `--resume`
only with the same script, account, network and recorded pending nonces.

Confirm five successful receipts, the installed runtime hash, the existing
proxy admin, the effective cap of 512, a historical round still at 256, and an
unpaused manager. Check the wallet admission settings and event parity. The
Sepolia round remains under the ID in the table. Reconcile the deployment
manifest from receipts after verification.

## Arbitrum One

After Sepolia verification, dry run against Arbitrum One and compare the
implementation runtime hash to the installed Sepolia runtime:

```sh
FOUNDRY_PROFILE=default forge script script/UpgradeCompetitionCapacity.s.sol:UpgradeCompetitionCapacity \
  --sig 'run(uint256)' 42161 --rpc-url arbitrum \
  --sender 0xAcc08cBbeD784Ba9b5B07ADb5F0E299Cb0fD3d95 \
  --slow --no-proxy --offline
```

For the keystore broadcast and Arbiscan source verification, add
`--account alphaengine-mainnet-deployer --broadcast --verify --verifier etherscan`.
Repeat the receipt and read-only state checks for the mainnet round. Both proxies
should have identical implementation runtime hashes.

If the transactions succeed but explorer verification needs a retry, verify the
implementation address from the deployment receipt separately. Set `CHAIN_ID`
to `421614` or `42161` and `IMPLEMENTATION_ADDRESS` to that address:

```sh
FOUNDRY_PROFILE=default forge verify-contract --chain "$CHAIN_ID" \
  --verifier etherscan --watch "$IMPLEMENTATION_ADDRESS" \
  src/strategy/AlphaEngineCompetitionStrategyManager.sol:AlphaEngineCompetitionStrategyManager
```

## Fork rehearsal

```sh
RUN_COMPETITION_CAPACITY_FORKS=true forge test --offline --no-storage-caching \
  --match-contract CompetitionCapacityUpgradeForkTest -vv
```

The forks use the actual populated proxy storage. They simulate the upgrade
locally and use the CoFHE test fixture only for new encrypted inputs. They do
not replace a live wallet submission or receipt check after broadcast.
