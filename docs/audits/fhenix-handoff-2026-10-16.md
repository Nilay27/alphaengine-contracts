# Fhenix handoff draft — 16 October 2026

Status: **owner reports proxy request and implementation follow-up sent**.
Fhenix confirmed proxies are sufficient for whitelisting; live admission remains
unverified here. Mainnet deployment and bootstrap handover are
confirmed. All 24 contracts have explorer-verified source; six ProxyAdmins
reuse the registry ProxyAdmin's verified source through `SimilarMatch` pointers.
Additional explicit submissions returned `Already Verified`. All 24 runtime
hashes and seven proxy pairs match the prepared source/build.

## Current brief whitelist request

Hey @liorbond, AlphaEngine is deployed and verified on Arbitrum One (42161).
Please whitelist these CoFHE caller proxies:

- Competition manager: `0x7fFcDa0A08401AcF1d114C83B32cE439C48c3681`
- Capital manager: `0x169e1E9371B421C0Ab8D0259e597d148E4F450a9`
- Swap controller: `0x083492999E0903500f292A9B8926F8cEEAbb023B`
- Swap escrow: `0x5fB529c05A182df3B23fe7B305dBc1ea9e19b314`

Swaps will follow later, integrating Fhenix's canonical confidential tokens and
their liquidity. We will not issue separate AlphaEngine token variants.

## Technical background for later follow-up

AlphaEngine's committed audit candidate is
`7ed4c49d2568bc8f89bf6b426b5c66321dbe3f5a`. The fresh Arbitrum Sepolia
CREATE2 deployment contains 24 source-verified contracts, including all seven
ProxyAdmins. Its declared deployment commit is
`4330d4d56d1c6c2b246f699036d997947bf6f43a`; production `src/` is byte-identical
to the audit candidate. The manifest records bootstrap tooling as uncommitted
at deployment; subsequent commits capture that tooling.

The candidate preserves virtual-offset accounting, a one-whole-share remaining
supply floor, immediate performance fees only on net-new profit after loss
recovery, authorized competition cancellation and explicit ERC4626 exit-share
risk coverage. One internal Solidity Auditor pass, with all 12 specialties at
Max, returned zero confirmed findings and five retained leads. CI passed at the
exact candidate SHA. This internal result does not replace independent review.

Please confirm the production CoFHE package/host implementation and admission
matrix, and review the retained host task-validation questions: malformed cast
argument counts/type pairs, operation/result-type disagreement, and unused
operation IDs. The source accepts these shapes for an admitted task creator;
AlphaEngine's normal helpers use canonical arguments. We have not demonstrated
live coprocessor failure, balance loss or an unprivileged admission route.

Arbitrum One now has the same 24-contract scope, paused and unfunded. No per-asset
AlphaEngine wrapper instances were deployed or are planned for production swaps;
the owner requires Fhenix's canonical assets and supported liquidity. Adaptation
of the current custom-wrapper integration is deferred. Seventeen deployment and
15 handover transactions succeeded from the user-run commands at source commit
`7ed4c49d2568bc8f89bf6b426b5c66321dbe3f5a`. All runtime hashes and proxy pairs
match the prepared build. Twenty-three confirmed addresses match Sepolia;
the PoolManager-bound executor changes to
`0x41F171C68b2fd301018CBA41753ff16dcEc07Ed6`.
The [confirmed mainnet record](../../deployments/v2/arbitrum-mainnet-create2-2026-10-16-confirmed.json)
includes all 24 addresses, receipts, runtime hashes and explorer metadata.
All 24 contracts have explorer-verified source, with six ProxyAdmin source-reuse
pointers retained as metadata. Additional submissions returned `Already Verified`;
Sourcify also confirms those six runtime matches. No repeat submission is needed.
Nine ownerships
and the future-wrapper ProxyAdmin owner moved to the temporary mainnet admin;
the five default-admin transfers are confirmed accepted at October 21 block
516939262, with all lifecycle contracts still paused. Whitelisting, live CoFHE permission/decryption tests,
operational-role migration and Safe/timelock handover remain activation gates.

## Reproduction and concise deployment-to-review diff

- Source: `4330d4d..7ed4c49` changes no production `src/` file or dependency pin.
- Fhenix already approved PR #2, merged as `73207b4`; its post-review delta is
  `73207b4...7ed4c49`. The earlier `0595ef4` baseline includes remediation the
  team had already reviewed and must not be described as the post-approval diff.
- Tooling: explicit opt-in bootstrap-role configuration and cross-sender fork
  regressions; production-only size reporting; coverage-only test gas budget;
  confirmed deployment metadata and documentation.
- Build: Solidity `0.8.26`, Cancun, optimizer `200`, via-IR, `create2` profile,
  metadata bytecode hash `none`; confidential-token library linked at
  `0x89C0FEdfEC30a097BE2b7Fb782Be9610686309f1`.
- Dependencies: CoFHE `1.0.0`, commit
  `0f5ded4f2847ee227f9be0b07a392238f75b656c`; confidential contracts `0.4.0`,
  commit `5138cb8644b19b24a75caf3f383a17457e823e16`.
- [Exact-SHA CI](https://github.com/Nilay27/alphaengine-contracts/actions/runs/38880105498):
  375 passed, zero failed, six expected skips; coverage 94.23% lines / 77.90%
  branches. Local CoFHE tests use the compatibility mock; no live cryptographic
  or throughput guarantee follows from them.
- [Confirmed Sepolia manifest](../../deployments/v2/arbitrum-sepolia-create2-2026-10-16-confirmed.json),
  [internal review and lead dispositions](internal-review-2026-10-16.md),
  [assembled report](../../alphaengine-contracts-pashov-ai-audit-report-20261016-151940.md),
  [mainnet preparation](../engineering/mainnet-preparation-2026-10-16.md).

The future FundVault stack is omitted from this deployment. Its NAV timing,
unsolicited-share closure, real-market and recovery-fulfillment follow-ups are
recorded separately; no economics were changed in response to these leads.
This chat did not grant reviewer access, send a message or activate a contract.

## Recorded explorer-verified Sepolia addresses

Chain ID: `421614`. Verification count: **24**. This table refers to Sepolia.

| Component | Verified Sepolia address |
|---|---|
| `confidentialTokenLibrary` | [0x89C0FEdfEC30a097BE2b7Fb782Be9610686309f1](https://sepolia.arbiscan.io/address/0x89C0FEdfEC30a097BE2b7Fb782Be9610686309f1#code) |
| `assetWrapperImplementation` | [0xa9CA9F6CBF3Da76dDEeD4419D9374d82dE519CfC](https://sepolia.arbiscan.io/address/0xa9CA9F6CBF3Da76dDEeD4419D9374d82dE519CfC#code) |
| `assetRegistryImplementation` | [0x2C03866e688714deF5b72bDE77cdF5496b7868Fb](https://sepolia.arbiscan.io/address/0x2C03866e688714deF5b72bDE77cdF5496b7868Fb#code) |
| `assetRegistry` | [0x4262462423C931BADCFA0DA07bDC67b1b51aa17F](https://sepolia.arbiscan.io/address/0x4262462423C931BADCFA0DA07bDC67b1b51aa17F#code) |
| `assetRegistryProxyAdmin` | [0x4eC4ee582b94b97AA846e781DBD4d14bfAFa3362](https://sepolia.arbiscan.io/address/0x4eC4ee582b94b97AA846e781DBD4d14bfAFa3362#code) |
| `assetGatewayImplementation` | [0x98719e008b30ac48eE2F4bEe0155e60b9c7185Cb](https://sepolia.arbiscan.io/address/0x98719e008b30ac48eE2F4bEe0155e60b9c7185Cb#code) |
| `assetGateway` | [0x5B3aF3fe2A504D4B2a371c13988729785c6a27Dc](https://sepolia.arbiscan.io/address/0x5B3aF3fe2A504D4B2a371c13988729785c6a27Dc#code) |
| `assetGatewayProxyAdmin` | [0x7374eAbC825d6FF57929c62BdC35F262b4974137](https://sepolia.arbiscan.io/address/0x7374eAbC825d6FF57929c62BdC35F262b4974137#code) |
| `qualificationRegistryImplementation` | [0x6DeBF287f1E9B64918078fCcbC36b659D8ea68eD](https://sepolia.arbiscan.io/address/0x6DeBF287f1E9B64918078fCcbC36b659D8ea68eD#code) |
| `qualificationRegistryProxy` | [0xF7017f2e11E22094ef5E3952eA86768eD302C98D](https://sepolia.arbiscan.io/address/0xF7017f2e11E22094ef5E3952eA86768eD302C98D#code) |
| `qualificationRegistryProxyAdmin` | [0x5bEFE82e4d0138E840bc3498ad5bdb3ebE6E1632](https://sepolia.arbiscan.io/address/0x5bEFE82e4d0138E840bc3498ad5bdb3ebE6E1632#code) |
| `competitionManagerImplementation` | [0xA0e845476674Ad39319761f55dEbfba30CFcE1E0](https://sepolia.arbiscan.io/address/0xA0e845476674Ad39319761f55dEbfba30CFcE1E0#code) |
| `competitionManagerProxy` | [0x7fFcDa0A08401AcF1d114C83B32cE439C48c3681](https://sepolia.arbiscan.io/address/0x7fFcDa0A08401AcF1d114C83B32cE439C48c3681#code) |
| `competitionManagerProxyAdmin` | [0x0D4CbA28056f6D4C5d06C1E0d87e9F8A55C0cae0](https://sepolia.arbiscan.io/address/0x0D4CbA28056f6D4C5d06C1E0d87e9F8A55C0cae0#code) |
| `capitalManagerImplementation` | [0x36FC84355163EebDb5a882C5eFc80B565041b4fB](https://sepolia.arbiscan.io/address/0x36FC84355163EebDb5a882C5eFc80B565041b4fB#code) |
| `capitalManagerProxy` | [0x169e1E9371B421C0Ab8D0259e597d148E4F450a9](https://sepolia.arbiscan.io/address/0x169e1E9371B421C0Ab8D0259e597d148E4F450a9#code) |
| `capitalManagerProxyAdmin` | [0x808a47f1E9e9A7A25c7b7d53c255FA6BeD0F0De7](https://sepolia.arbiscan.io/address/0x808a47f1E9e9A7A25c7b7d53c255FA6BeD0F0De7#code) |
| `swapControllerImplementation` | [0x4e3aA848F20342e8A72119046769cA05aCd75CbB](https://sepolia.arbiscan.io/address/0x4e3aA848F20342e8A72119046769cA05aCd75CbB#code) |
| `swapControllerProxy` | [0x083492999E0903500f292A9B8926F8cEEAbb023B](https://sepolia.arbiscan.io/address/0x083492999E0903500f292A9B8926F8cEEAbb023B#code) |
| `swapControllerProxyAdmin` | [0x6B6C2aCEd29705f7b8F34D8Eea9d9d668A2Ed844](https://sepolia.arbiscan.io/address/0x6B6C2aCEd29705f7b8F34D8Eea9d9d668A2Ed844#code) |
| `swapEscrowImplementation` | [0x2966Ff2104D7A5c69c4e4433D181DE8bCa42c38E](https://sepolia.arbiscan.io/address/0x2966Ff2104D7A5c69c4e4433D181DE8bCa42c38E#code) |
| `swapEscrowProxy` | [0x5fB529c05A182df3B23fe7B305dBc1ea9e19b314](https://sepolia.arbiscan.io/address/0x5fB529c05A182df3B23fe7B305dBc1ea9e19b314#code) |
| `swapEscrowProxyAdmin` | [0x1E997Cff7e22B599209C937FC0abaC83b1c2532b](https://sepolia.arbiscan.io/address/0x1E997Cff7e22B599209C937FC0abaC83b1c2532b#code) |
| `swapExecutor` | [0x336e1dbc80935a553a5d5F8D1f12D1a906526386](https://sepolia.arbiscan.io/address/0x336e1dbc80935a553a5d5F8D1f12D1a906526386#code) |
