# Arbitrum Sepolia v2 deployment — 9 October 2026

Network: **Arbitrum Sepolia (421614)**. Source commit: `4ffb31f0d315efceb358e6332b618e5452017a54`.
Signer: `0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d` (`alphaengine-deployer`).
CoFHE contracts v1.0.0; FHERC20 v0.4.0; Foundry v1.7.1. Test-only collapsed roles.

## Deployment evidence

User broadcast the deployment. The local Foundry broadcast artifact contains **14 successful creation receipts**, spanning Arbitrum L2 blocks **317150657–317150728**. Five ProxyAdmins were created inside their proxy transactions, giving **19 recorded addresses**. No new transactions were submitted while recording this result.

- [Receipt-reconciled manifest](../../deployments/v2/arbitrum-sepolia-2026-10-09-4ffb31f-confirmed.json)
- [Original script candidate](../../deployments/v2/arbitrum-sepolia-2026-10-09-4ffb31f.json) — preserved unchanged; its `deploymentBlock` is simulation context, not the receipt-derived L2 start block.
- Broadcast evidence: `broadcast/DeployAlphaEngineV2.s.sol/421614/run-latest.json` (local, ignored).
- Broadcast artifact SHA-256: `399769e5ab02de84e398b27b7a4cceddbb39372ce4aa07fea49165d6949ac076`.

The user supplied Foundry completion output: **“All (8) contracts were verified!”** Record this as successful verification of the eight contracts submitted by Foundry. It does not establish separate source verification of every proxy and ProxyAdmin. The earlier explorer snapshot is retained as historical evidence; no further explorer checks were made after the user requested stopping them.

## Final addresses

Applications must use the **proxy** addresses for upgradeable managers. Implementations and ProxyAdmins are deployment/administration identities.

| Component | Address | L2 deployment block |
|---|---|---|
| assetGateway | [`0xa3c8E767eA23cE564AEe6b7D1e7Cd49f8887216f`](https://sepolia.arbiscan.io/address/0xa3c8E767eA23cE564AEe6b7D1e7Cd49f8887216f#code) | 317150669 |
| assetRegistry | [`0x01CE620B64D29B1121172CB36f572ebFAf1Eea74`](https://sepolia.arbiscan.io/address/0x01CE620B64D29B1121172CB36f572ebFAf1Eea74#code) | 317150664 |
| capitalManagerImplementation | [`0xa2304788Cb7a030d2EA443CEb36F4a8E4A7ff39a`](https://sepolia.arbiscan.io/address/0xa2304788Cb7a030d2EA443CEb36F4a8E4A7ff39a#code) | 317150696 |
| capitalManagerProxy | [`0x6571f70e9E312A07c851740A4e48a49Df7f714B5`](https://sepolia.arbiscan.io/address/0x6571f70e9E312A07c851740A4e48a49Df7f714B5#code) | 317150701 |
| capitalManagerProxyAdmin | [`0x669e36D8ba474140A20907F6ee64355cF15D70f2`](https://sepolia.arbiscan.io/address/0x669e36D8ba474140A20907F6ee64355cF15D70f2#code) | 317150701 |
| competitionManagerImplementation | [`0x6b695e6bae7c39B70b31136844Ca674abe446842`](https://sepolia.arbiscan.io/address/0x6b695e6bae7c39B70b31136844Ca674abe446842#code) | 317150686 |
| competitionManagerProxy | [`0x9CBF3917Ff31E41393e5D992b3bdbf1fC9C80744`](https://sepolia.arbiscan.io/address/0x9CBF3917Ff31E41393e5D992b3bdbf1fC9C80744#code) | 317150690 |
| competitionManagerProxyAdmin | [`0x4e3841A9e383850bD238377f3471205Ba21ded8c`](https://sepolia.arbiscan.io/address/0x4e3841A9e383850bD238377f3471205Ba21ded8c#code) | 317150690 |
| confidentialTokenLibrary | [`0x4BDF378C53F942c02Ba88FAb39903A7451602a36`](https://sepolia.arbiscan.io/address/0x4BDF378C53F942c02Ba88FAb39903A7451602a36#code) | 317150657 |
| qualificationRegistryImplementation | [`0x1CC758B72F21B45CfDe1378551445922877E09fa`](https://sepolia.arbiscan.io/address/0x1CC758B72F21B45CfDe1378551445922877E09fa#code) | 317150675 |
| qualificationRegistryProxy | [`0x0C4f279C2fC2332CCdcF1842ff4D511A7C12d527`](https://sepolia.arbiscan.io/address/0x0C4f279C2fC2332CCdcF1842ff4D511A7C12d527#code) | 317150680 |
| qualificationRegistryProxyAdmin | [`0x3bD672410F2c86C49457794551228E94E3216aA8`](https://sepolia.arbiscan.io/address/0x3bD672410F2c86C49457794551228E94E3216aA8#code) | 317150680 |
| swapControllerImplementation | [`0x353198589Ca9F90c3BF4907D045F86381abb597B`](https://sepolia.arbiscan.io/address/0x353198589Ca9F90c3BF4907D045F86381abb597B#code) | 317150708 |
| swapControllerProxy | [`0xf02E3684C6DCC24B95418B02A66496C6b8CA46FA`](https://sepolia.arbiscan.io/address/0xf02E3684C6DCC24B95418B02A66496C6b8CA46FA#code) | 317150712 |
| swapControllerProxyAdmin | [`0x499CefDB9b7747F8Fd9978bA635B5092b1B59917`](https://sepolia.arbiscan.io/address/0x499CefDB9b7747F8Fd9978bA635B5092b1B59917#code) | 317150712 |
| swapEscrowImplementation | [`0x0Fb0DB9a20aF9159c1a458d2ce816636b8b6f0Cc`](https://sepolia.arbiscan.io/address/0x0Fb0DB9a20aF9159c1a458d2ce816636b8b6f0Cc#code) | 317150719 |
| swapEscrowProxy | [`0xc270ADFfc60c78e98f746Fb9D9f3906E82754CBc`](https://sepolia.arbiscan.io/address/0xc270ADFfc60c78e98f746Fb9D9f3906E82754CBc#code) | 317150724 |
| swapEscrowProxyAdmin | [`0xE4E1BC2030B7e99C5a7acC9eC15C634AA8B3E35c`](https://sepolia.arbiscan.io/address/0xE4E1BC2030B7e99C5a7acC9eC15C634AA8B3E35c#code) | 317150724 |
| swapExecutor | [`0x8C8af2a132D89DC5f747832De63fBA91708C9491`](https://sepolia.arbiscan.io/address/0x8C8af2a132D89DC5f747832De63fBA91708C9491#code) | 317150728 |

## Creation transactions

| Contract | Transaction | L2 block |
|---|---|---|
| ERC20ConfidentialLib | [`0xdf135fe42d7f6975e9009d91323c8478388045edbde36641030c969663c6d7a1`](https://sepolia.arbiscan.io/tx/0xdf135fe42d7f6975e9009d91323c8478388045edbde36641030c969663c6d7a1) | 317150657 |
| AlphaEngineConfidentialAssetRegistry | [`0xae901938280f3e972ebd568ae22752205e2b9d5dd44510872035edb7cf31d137`](https://sepolia.arbiscan.io/tx/0xae901938280f3e972ebd568ae22752205e2b9d5dd44510872035edb7cf31d137) | 317150664 |
| AlphaEngineConfidentialAssetGateway | [`0x60967ebde404cf11fd1f3bbe7fc55af8ee000b9a7dfe9bd2c6975ae658c98373`](https://sepolia.arbiscan.io/tx/0x60967ebde404cf11fd1f3bbe7fc55af8ee000b9a7dfe9bd2c6975ae658c98373) | 317150669 |
| AlphaEngineTraderQualificationRegistry | [`0x1eacaff233df863d34bc81b17922879e106466d68dbf20c10d3dc096d75c53a3`](https://sepolia.arbiscan.io/tx/0x1eacaff233df863d34bc81b17922879e106466d68dbf20c10d3dc096d75c53a3) | 317150675 |
| TransparentUpgradeableProxy | [`0x71ed87176ddcdba40716f2c2570e2cda0ba1c6b974ee19c82ef9ed98bc0ebb9a`](https://sepolia.arbiscan.io/tx/0x71ed87176ddcdba40716f2c2570e2cda0ba1c6b974ee19c82ef9ed98bc0ebb9a) | 317150680 |
| AlphaEngineCompetitionStrategyManager | [`0x2af29c22ae93b09dcbfd35f9b5e557ce91773c663a96a79873e50821caf55b55`](https://sepolia.arbiscan.io/tx/0x2af29c22ae93b09dcbfd35f9b5e557ce91773c663a96a79873e50821caf55b55) | 317150686 |
| TransparentUpgradeableProxy | [`0x4a287dea0fa2fc2eb2272d364b913589e4b9d6c8a46ad39abd6cb3de63868d63`](https://sepolia.arbiscan.io/tx/0x4a287dea0fa2fc2eb2272d364b913589e4b9d6c8a46ad39abd6cb3de63868d63) | 317150690 |
| AlphaEngineCapitalStrategyManager | [`0x0e690c6a4e6c6daf187f91aa2c0ea02837d89ee9b4f34a90dc88312ff15eecf1`](https://sepolia.arbiscan.io/tx/0x0e690c6a4e6c6daf187f91aa2c0ea02837d89ee9b4f34a90dc88312ff15eecf1) | 317150696 |
| TransparentUpgradeableProxy | [`0x1118abfabc88f2f38b46c0a23488cf5e2a458aef1469203e96a01da2db6fcbb2`](https://sepolia.arbiscan.io/tx/0x1118abfabc88f2f38b46c0a23488cf5e2a458aef1469203e96a01da2db6fcbb2) | 317150701 |
| AlphaEngineConfidentialSwapController | [`0xa74da2c2289fe1b44e59f026b83eb289175d8ff7711ed83541d90a807855ed77`](https://sepolia.arbiscan.io/tx/0xa74da2c2289fe1b44e59f026b83eb289175d8ff7711ed83541d90a807855ed77) | 317150708 |
| TransparentUpgradeableProxy | [`0x5ee44089f2bed47a79414ef341073ad2fe6af9f1bc0a9335a0fc6f721144ac48`](https://sepolia.arbiscan.io/tx/0x5ee44089f2bed47a79414ef341073ad2fe6af9f1bc0a9335a0fc6f721144ac48) | 317150712 |
| AlphaEngineConfidentialSwapEscrow | [`0xf7e2fec6ad7ed5a078991b9c1e9fc75f6af2a1b388aaabace17cfed2a8f1848e`](https://sepolia.arbiscan.io/tx/0xf7e2fec6ad7ed5a078991b9c1e9fc75f6af2a1b388aaabace17cfed2a8f1848e) | 317150719 |
| TransparentUpgradeableProxy | [`0x31074fb113e4b1db16ed3395d2c039b252dd97736ee96d5bc479ed63676bad4d`](https://sepolia.arbiscan.io/tx/0x31074fb113e4b1db16ed3395d2c039b252dd97736ee96d5bc479ed63676bad4d) | 317150724 |
| AlphaEngineV4SwapExecutor | [`0x9660eae740073b71ac8bafc9fcbda05716f7fdd55b1e4d2381872594499410a6`](https://sepolia.arbiscan.io/tx/0x9660eae740073b71ac8bafc9fcbda05716f7fdd55b1e4d2381872594499410a6) | 317150728 |

## Deliberately not deployed

Per-asset FHERC20 wrappers await reviewed asset selection and minimums. FundVault, USDC Vault Manager, Vault Execution Manager and vault-bound decoders remain out of scope. The deployed Swap Escrow is distinct from the omitted FundVault.

## Initial activation and consumer checkpoint

The following records the initial post-deployment state. The subsequent local
integration checkpoint below supersedes its competition-creation and live
submission/decryption TODOs; the on-chain evaluation and other domain gates
remain open.

- The script initializes five proxy domains paused and returns 11 post-deployment admin actions without executing them. This record does not independently recheck live roles, pause state, proxy slots, runtime code hashes or reciprocal links.
- Complete required competition role configuration, qualification-issuer authorization and competition creation before submission. Keep capital paused without the omitted vault/execution system. Review separate swap setup before activation.
- Dashboard and operator SDK migration to `@cofhe/sdk` 0.8.0 is implemented locally: operator Permit → ACP, consuming-contract binding, ordered ciphertext handles plus one batch proof, typed validation and consumer builds. Browser encryption does not create a decryption ACP.
- Dashboard uses the canonical Competition Manager ABI and proxy for `submitCompetitionStrategy(competitionId, timeframeKey, encryptedMarketId, encryptedComponents, inputProof)`. Receipt/history identity checks use the new event; the old per-item tuples and caller deadline are removed from arena submission. Its competition ID remains unset until one is created.
- Listener has an explicit competition profile with canonical ABI, historical getter reconciliation and the existing simulation/evaluation/BFF path. The local profile points at the confirmed proxy with a fresh checkpoint; valid operator credentials are still required. On-chain score posting, finalization/reveal and complete orphan rollback remain pending.
- Run live encrypted submission, authorized operator decryption and evaluation/result tests against the target CoFHE services. Successful deployment/source verification does not prove these flows or Fhenix admission.

Consumer cutover read-only checks at L2 block **317393570** confirmed chain 421614, the Competition Manager paused, `competitionNonce() == 0` and FHE operator `0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d`. This confirms getter compatibility, not encrypted submission/decryption or service admission. No transactions or keystore operations were performed.

SDK integration uses the installed official 0.8.0 package API as its source for consuming-contract binding, ordered handles/shared proof and ACP builders. The [official SDK changelog](https://github.com/FhenixProtocol/cofhesdk/blob/master/packages/sdk/CHANGELOG.md) and [0.7 migration guide](https://cofhesdk.fhenix.io/migrating-to-0-7-0) remain release references; no live CoFHE service readiness is claimed.

## Subsequent local integration checkpoint — 9 October 2026

- Competition `0xb6affee44171d2bb27bf22f6472331b9acaa3dcb7f689bd3de6e69601ff89252`
  is active on the recorded Competition Manager proxy. The dashboard uses this
  competition and the canonical ABI.
- Submission transaction
  [`0x68b7322df9bb893a194ed03d06e4656b8c5f6244e2139ab58b763e8dba1ff38f`](https://sepolia.arbiscan.io/tx/0x68b7322df9bb893a194ed03d06e4656b8c5f6244e2139ab58b763e8dba1ff38f)
  was confirmed at L2 block `317410209`. The operator decrypted the market and
  three components, ran simulation and official evaluation, and persisted the
  result through the local app-bff. The database and frontend leaderboard API
  returned score `50.19000420422378` for this submission.
- This is evidence for one live encrypted submission and operator evaluation
  path. The result is off-chain: the on-chain submission remains `Submitted`.
  On-chain score posting, finalization/public reveal and complete orphan
  rollback remain pending. This checkpoint does not establish production
  throughput, mainnet whitelisting or readiness.
- A second submission by the same trader was rejected by the existing
  `ActiveSubmissionAlreadyExists` guard. Repeated attempts, public market IDs
  and configurable market cooldowns are under owner discussion; no contract
  changes implementing them are included in this checkpoint.

## Validation of this record

Every top-level address and transaction hash matches a successful receipt; all five internal ProxyAdmin addresses match the broadcast transaction metadata. Candidate and legacy manifests are preserved. Receipt-derived L2 blocks replace the simulation block only in the new confirmed record. No live bytecode/proxy/storage reconciliation or new security audit is claimed.
