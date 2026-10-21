# Arbitrum One preparation — 16 October 2026

Status: **user-broadcast mainnet deployment confirmed; paused and unfunded**.

Owner decision after deployment: future swaps must use Fhenix's canonical
confidential assets and supported liquidity, with no AlphaEngine-issued token
variants or per-asset AlphaEngine wrapper deployments. The deployed template and
historical preparation evidence below are retained; current custom-wrapper
dependencies require a later compatibility change. See the
[canonical-token decision](strategy-manager-fund-vault-implementation-plan.md#canonical-confidential-token-decision-2026-10-16).

## Confirmed mainnet checkpoint

The [confirmed Arbitrum One manifest](../../deployments/v2/arbitrum-mainnet-create2-2026-10-16-confirmed.json)
records 17 successful deployment transactions in blocks 515424455–515424529,
followed by 15 successful bootstrap handover transactions. Read-only RPC checks
at block 515426805 confirm all 24 runtime hashes, all 17 creation-input hashes,
seven proxy implementation/admin pairs, five paused lifecycle contracts and zero
native balance at all 24 deployed addresses. The deployed source commit remains
`7ed4c49d2568bc8f89bf6b426b5c66321dbe3f5a`.

The seven ProxyAdmins, registry/executor business ownerships and future-wrapper
ProxyAdmin owner now belong to `0xAcc08cBbeD784Ba9b5B07ADb5F0E299Cb0fD3d95`.
On October 21, read-only checks at Arbitrum One block 516939262 confirm that all
five default-admin transfers have been accepted by that same successor. Pending
admins/schedules are zero and all five lifecycle contracts remain paused.
The initiation schedules below are historical evidence:

| Contract | Acceptance schedule, 18 October 2026, IST |
|---|---|
| Qualification registry | 21:48:24 |
| Competition manager | 21:48:25 |
| Capital manager | 21:48:26 |
| Swap controller | 21:48:27 |
| Swap escrow | 21:48:28 |

Acceptance required a block timestamp after the respective schedule. The Codex
scheduler remains disabled at the user's request. Operational roles, FHE
operators and final Safe/timelock authority remain separate activation gates;
acceptance was user-signed, with no activation performed by these checks.

All 24 contracts have explorer-verified source. Six ProxyAdmin API records
include a `SimilarMatch` pointer to the explicitly verified registry ProxyAdmin;
this is source-reuse metadata, not six missing source verifications. The user
provided explorer screenshots showing `Exact Match` alongside the `Similar Match`
badge and constructor caveat. Creation inputs, runtime hashes and current owners
were independently reconciled. Additional explicit submissions returned
`Already Verified`; no repeat submission is required. Sourcify also confirms six
runtime matches, with creation matches for five and a null creation field for
the escrow ProxyAdmin. The confirmed manifest counts all 24 as verified and
retains the six pointers. Preparation sections below preserve earlier evidence.

The source candidate is `7ed4c49d2568bc8f89bf6b426b5c66321dbe3f5a`.
The confirmed Sepolia deployment records
`4330d4d56d1c6c2b246f699036d997947bf6f43a`; production `src/` is byte-identical
between those commits. Later changes cover explicit bootstrap tooling,
deployment tests/manifests, CI and documentation.
The Sepolia manifest explicitly records that bootstrap tooling was uncommitted
at deployment time. The recorded deployment SHA alone does not describe that
then-uncommitted tooling; the current committed scripts capture it.

## Prepared scope and public evidence

Use the same first-pass scope as the
[confirmed Sepolia manifest](../../deployments/v2/arbitrum-sepolia-create2-2026-10-16-confirmed.json):
eight implementation contracts, seven core transparent proxies and their seven
ProxyAdmins, the confidential-token library, and the fixed V4 executor: **24
contracts**. No per-token AlphaEngine wrapper instances were deployed; future
swap assets must follow the canonical-token decision above. FundVault,
USDCVaultManager, VaultExecutionManager and vault-bound decoders remain omitted.
The five lifecycle proxies initialize paused, and deployment includes no funding
or activation calls. Registry and gateway do not expose a pause control.

Public preparation artifacts are retained under
[`deployments/v2/rehearsals/mainnet-preparation-2026-10-16-7ed4c49/`](../../deployments/v2/rehearsals/mainnet-preparation-2026-10-16-7ed4c49/):

- `mainnet-preflight.json`: chain `42161`, block `515348609`, hash
  `0x24d3da24a9ac54e7244f72ca72e348bcf5d1157e02e83469872164030e9d806e`;
  the factory runtime matches, PoolManager has code, and all 24 predicted
  addresses have zero code and zero nonce at that block.
- `rehearsal.json`, `rehearsal.env`, `forge-simulation.log` and
  `arbitrum-mainnet-candidate.json`: successful local-fork execution, with no
  signing, broadcast or verification submission.
- `unsigned-transactions-summary.json`: 17 zero-value unsigned creations,
  seven nested ProxyAdmins and zero receipts.
- `deployment.env`: public configuration for a later deployment, with a
  separate broadcast-candidate output path that preserves rehearsal evidence.
- `verification-plan.json` and `verify-all-24.sh`: explicit source identifiers,
  encoded constructor arguments and explorer commands for every contract,
  including the internally created ProxyAdmins. No credential is stored here.
- `cofhe-public-runtime-snapshot.json`: service ID 1 resolves to
  `0x52E7a0cAF234b266bCFAa6aA933a412FDe58432A`; its getters report the service
  and access list enabled. The four prepared FHE lifecycle proxy addresses
  checked are not listed. This read-only snapshot establishes neither source
  implementation parity nor successful encrypted operations.

The rehearsal uses sender `0x1000000000000000000000000000000000000001` solely
as a public simulation input. This address does not designate the mainnet signer.
All 33 frozen source/dependency files were hash-checked before preparation.

## Deterministic addresses and initial authority

Retain factory `0x4e59b44847b379578588920cA78FbF26c0B4956C`, namespace
`keccak256("alphaengine-v2-create2-v1")`, profile `create2`, Solidity 0.8.26,
Cancun, optimizer 200, via-IR, metadata bytecode hash `none`, and the configured
library link. All 17 creation-code hashes were checked against the Sepolia
record before changing the executor's PoolManager input.

The seven core proxy addresses remain:

| Component | Predicted Arbitrum One address |
|---|---|
| Asset registry | `0x4262462423C931BADCFA0DA07bDC67b1b51aa17F` |
| Asset gateway | `0x5B3aF3fe2A504D4B2a371c13988729785c6a27Dc` |
| Qualification registry | `0xF7017f2e11E22094ef5E3952eA86768eD302C98D` |
| Competition manager | `0x7fFcDa0A08401AcF1d114c83B32cE439C48c3681` |
| Capital manager | `0x169e1E9371B421C0Ab8D0259e597d148E4F450a9` |
| Swap controller | `0x083492999E0903500f292A9B8926F8cEEAbb023B` |
| Swap escrow | `0x5fB529c05A182df3B23fe7B305dBc1ea9e19b314` |

The mainnet PoolManager is
`0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32`. Its constructor input changes
the executor address to **`0x41F171C68b2fd301018CBA41753ff16dcEc07Ed6`**.
The other 23 addresses match Sepolia. All 24 prepared mainnet addresses are now
confirmed by the user-broadcast deployment recorded above.

Address parity also requires the same initial roles and ProxyAdmin owner:
`0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d`, with
`BOOTSTRAP_ROLE_COLLAPSE=true` and `TEST_ONLY_ROLE_COLLAPSE=false`.
A different broadcasting key does not replace this initial authority.
Complete and verify the governance/operator handover and bootstrap revocations
before funding or activation. Each ProxyAdmin must transfer to the designated
Safe-controlled upgrade timelock with its actual delay verified; the separate
default-admin transfer delay does not delay upgrades or operational setters.

## Earlier rehearsal with a candidate mainnet deployer

A second local-fork rehearsal used the candidate mainnet deployer address
`0x02188Cadd14e1cc02D92683381d291b2589335D7` at Arbitrum One block
`515404493` (`0x922ae773095be62325bdd6d70ff9e163ec8b087ed9a22b8a01e83595cb23eaac`).
The initial role/owner inputs remain the original bootstrap address above.
All 24 addresses match the prepared mainnet candidate, and all 17 creation-code
hashes are unchanged. There are 17 zero-value unsigned transactions, zero
receipts, no wallet unlock, no broadcast and no handover execution.

Evidence is retained in
[`mainnet-deployer-2026-10-16-144531-7ed4c49/`](../../deployments/v2/rehearsals/mainnet-deployer-2026-10-16-144531-7ed4c49/).
The rehearsal estimates 42,053,744 gas and a budget of
`0.001682149802053744 ETH` at a maximum fee of `0.040000001 gwei`.
That sender had `0.0024 ETH` at the recorded block. This is deployment
gas in the sender wallet; the protocol deployment still includes no funding.

The deployment script does **not** automatically transfer authority to the
broadcasting wallet. Any later transfer to the current mainnet deployer is a
separate on-chain procedure, requiring signatures from the original bootstrap
account for the outgoing actions:

- Transfer the seven ProxyAdmin ownerships and the separate asset-registry and
  executor business ownerships explicitly.
- For each of the five lifecycle contracts, the current default admin calls
  `beginDefaultAdminTransfer(newAdmin)`; the new admin calls
  `acceptDefaultAdminTransfer()` after the 48-hour delay has elapsed.
- Separately grant/revoke operational roles, rotate the two FHE-operator
  settings and update the registry's future-wrapper ProxyAdmin-owner setting.
  Transferring a default admin or business owner does not perform these steps.
  The post-deployment role grants/configuration emitted by `buildAdminActions`
  are also separate from deployment and must use the intended final recipients.

No authority migration is performed by this rehearsal. Final governance/operator
separation and the Safe-controlled upgrade-timelock handover remain required
before activation; a new EOA does not satisfy those governance requirements.

## Current accounts and prepared handover

The current `alphaengine-mainnet-deployer` account is
`0xAcc08cBbeD784Ba9b5B07ADb5F0E299Cb0fD3d95`. The earlier candidate
`0x02188Cadd14e1cc02D92683381d291b2589335D7` is retired and must not receive
authority. The outgoing bootstrap account remains `alphaengine-deployer`,
`0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d`.
At Arbitrum One block 515420888, the current sender has
`0.002297967682504 ETH` and the outgoing bootstrap account has `0.0001 ETH`.
These are signer gas balances; no protocol funding is authorized.

A local-only deployment/handover rehearsal at that block confirms all 24
prepared addresses and 17 creation-code hashes. The 32 unsigned transactions
consist of 17 deployments from the current sender and 15 handover calls from
the bootstrap account, all with zero ETH value and zero receipts. Assertions
reject immediate acceptance, accept after a simulated 48-hour time advance,
reject the former ProxyAdmin owner, and retain the five paused lifecycle states.
The production source and existing deployment scripts are unchanged.

The separate one-time helper is
[`MainnetHandover.s.sol`](../../deployments/v2/rehearsals/mainnet-launch-2026-10-16-7ed4c49/MainnetHandover.s.sol).
It starts five default-admin transfers, changes the future-wrapper ProxyAdmin
owner, transfers registry/executor business ownership and transfers the seven
existing ProxyAdmin ownerships to the current mainnet deployer. It does not
accept delayed transfers, unpause, fund, upgrade, grant/revoke operational
roles or rotate FHE operators. Those separate operational/governance actions
and the final Safe-controlled upgrade timelock remain activation gates.
The rehearsal file `RehearseHandover.s.sol` is local validation only and must
never be used with `--broadcast`.

Deployment and handover commands use the locally configured Alchemy
`ARBITRUM_MAINNET_RPC_URL`; do not persist its credential-bearing value in
public records. The reviewer can inspect
`mainnet-launch-2026-10-16-7ed4c49/handover-rehearsal-result.json` for the local
evidence. That rehearsal made no live deployment, verification submission or
handover; the later user-broadcast checkpoint is recorded above.

## Rehearsal and later deployment commands

The successful rehearsal uses only the public inputs and never unlocks a wallet:

```sh
cd /Users/nilay/alphaEngine/alphaengine-contracts
. deployments/v2/rehearsals/mainnet-preparation-2026-10-16-7ed4c49/rehearsal.env
forge script script/DeployAlphaEngineCreate2.s.sol:DeployAlphaEngineCreate2 \
  --rpc-url https://arb1.arbitrum.io/rpc --fork-block-number 515348609 \
  --sender 0x1000000000000000000000000000000000000001 \
  --non-interactive --no-proxy
```

The owner has authorized deployment, all 24 explorer verifications and initiation
of the bootstrap handover, with signing performed locally by the owner. Run the
following in a shell with `ARBITRUM_MAINNET_RPC_URL` loaded. The subshell stops
on failure before proceeding to the next stage. This prepared block has **not**
run; do not rerun it as a fresh deployment after any partial broadcast:

```sh
(
  set +x
  set -eu
  cd /Users/nilay/alphaEngine/alphaengine-contracts
  set -a
  . ./.env
  set +a
  : "${ARBITRUM_MAINNET_RPC_URL:?Load your Alchemy Arbitrum One RPC variable first}"
  . deployments/v2/rehearsals/mainnet-preparation-2026-10-16-7ed4c49/deployment.env
  export DEPLOYMENT_MANIFEST=deployments/v2/rehearsals/mainnet-launch-2026-10-16-7ed4c49/broadcast-candidate.json

  forge script script/DeployAlphaEngineCreate2.s.sol:DeployAlphaEngineCreate2 \
    --rpc-url "$ARBITRUM_MAINNET_RPC_URL" \
    --account alphaengine-mainnet-deployer \
    --sender 0xAcc08cBbeD784Ba9b5B07ADb5F0E299Cb0fD3d95 \
    --broadcast --verify --slow --no-proxy --offline

  bash deployments/v2/rehearsals/mainnet-preparation-2026-10-16-7ed4c49/verify-all-24.sh

  forge script deployments/v2/rehearsals/mainnet-launch-2026-10-16-7ed4c49/MainnetHandover.s.sol:MainnetHandover \
    --rpc-url "$ARBITRUM_MAINNET_RPC_URL" \
    --account alphaengine-deployer \
    --sender 0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d \
    --broadcast --slow --no-proxy --offline
)
```

Keep the candidate distinct from a confirmed manifest. Reconcile the 17 receipts,
runtime hashes and seven proxy implementation/admin slots, then execute
`verify-all-24.sh` and retain successful explorer results for every address.
`--verify` alone is insufficient evidence for the seven nested ProxyAdmins.
The explicit commands use the pinned compilation profile and constructor inputs.
Explorer credentials remain in the local credential configuration.

After verification, the Fhenix handoff must identify the confirmed chain and
addresses, deployed commit, source/tooling diff, dependency pins and outstanding
live-network questions. Whitelisting, live CoFHE checks and governance handover
remain activation gates. The omitted vault stack additionally requires the real
market/recovery/NAV-policy gates before any future activation.

## Completed explicit ProxyAdmin verification follow-up

The user already ran this verification-only follow-up. It submitted no
transactions and used no wallet. All six returned `Already Verified`; the
Arbiscan labels remained similar matches. Keep this as historical evidence,
not an instruction to repeat it. Foundry used the local explorer configuration.

```bash
(
  set +x
  set -eu
  cd /Users/nilay/alphaEngine/alphaengine-contracts
  export FOUNDRY_PROFILE=create2
  for proxy_admin in \
    0x7374eAbC825d6FF57929c62BdC35F262b4974137 \
    0x5bEFE82e4d0138E840bc3498ad5bdb3ebE6E1632 \
    0x0D4CbA28056f6D4C5d06C1E0d87e9F8A55C0cae0 \
    0x808a47f1E9e9A7A25c7b7d53c255FA6BeD0F0De7 \
    0x6B6C2aCEd29705f7b8F34D8Eea9d9d668A2Ed844 \
    0x1E997Cff7e22B599209C937FC0abaC83b1c2532b
  do
    forge verify-contract "$proxy_admin" \
      lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin \
      --chain 42161 \
      --compiler-version v0.8.26+commit.8a97fa7a \
      --num-of-optimizations 200 --via-ir --evm-version cancun \
      --constructor-args 0x0000000000000000000000000cd73a4e3d34d5488bc4e547fecedac86305db9d \
      --verifier etherscan --skip-is-verified-check --watch
  done
)
```
