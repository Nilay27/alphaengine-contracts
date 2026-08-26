# Baseline internal audit evidence

- Stage: 1 — baseline evidence and full audit
- Baseline commit: `49d96e8a80d6903d1d30affc6f836bcc0ac13800`
- Audit date: 2026-08-26
- Solidity-auditor skill version: 2
- Mode: full repository-owned production/script Solidity with persistent file output
- Report: `assets/findings/alphaengine-contracts-pashov-ai-audit-report-20260826-170601.md`

## Scope

- `script/DeployAlphaEngineArbitrumSepolia.s.sol`
- `script/DeployAlphaEngineIntentController.s.sol`
- `script/UpgradeAlphaEngineIntentController.s.sol`
- `src/AlphaEngineIntentController.sol`
- `src/executors/AlphaEngineV4SwapExecutor.sol`
- `src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol`
- `src/vault/AlphaEngineConfidentialVault.sol`

Interfaces, libraries, mocks, and tests were excluded from the primary source
bundle according to the auditor mode, but installed dependency behavior was
traced while validating relevant findings.

## Validation baseline

- Foundry: `1.3.2-nightly`, commit
  `6071d59dc5b1d9d411822fe92f4182d204a10e00`.
- Solidity: `0.8.26`; Cancun; optimizer 200; via-IR.
- `forge test --offline`: 152 passed, 0 failed, 0 skipped.
- `forge build --sizes --offline`: passed.
- `git diff --check`: passed after P0 documentation publication.
- `forge fmt --check`: known baseline failure in the controller score tests and
  controller upgrade script; reserved for the isolated release-hygiene stage.

## Runtime sizes

| Contract | Runtime bytes | EIP-170 margin |
|---|---:|---:|
| `AlphaEngineConfidentialVault` | 23,746 | 830 |
| `AlphaEngineFHERC20ERC20Wrapper` | 12,554 | 12,022 |
| `AlphaEngineIntentController` | 9,421 | 15,155 |
| `AlphaEngineV4SwapExecutor` | 4,419 | 20,157 |

## Repository-owned storage baseline

`AlphaEngineIntentController`:

| Slot | Field |
|---:|---|
| 0 | `listenerOperator` |
| 1 | `_intentRecords` |
| 2 | `_intentComponentHandles` |
| 3 | `submitterNonces` |
| 4 | `confidentialVault` |
| 5 | `swapExecutor` |
| 6 | `_swapIntentRecords` |
| 7 | `_evaluationScoreRecords` |
| 8–49 | `__gap` |

`AlphaEngineConfidentialVault`:

| Slot | Field |
|---:|---|
| 0 | `intentController` |
| 1 | `liveSwapLockCount` |
| 2 | `_wrappersByUnderlying` |
| 3 | `_underlyingByWrapper` |
| 4 | `_swapIntentLocks` |
| 5–49 | `__gap` |

These layouts are historical evidence only. New product contracts use fresh
proxies and must not reinterpret either layout.

## Artifact hashes

- Controller ABI:
  `59881bbcce521aa202d0d0042ac766ce06aa5eca5e3b8dd8b24fafb9e82c531e`
  (the stale checked-in baseline, now archived under
  `ABI/legacy/AlphaEngineIntentController.checked-in-49d96e8.json`)
- Controller ABI regenerated from baseline source:
  `eb87679305079d2f76cd625517e8166c3131ae431533f893b586941c7cc52c87`
- Vault ABI:
  `afd4778d3458e07d239aef626533767302672476efe7ccdeb192edb998ff4146`
- Wrapper ABI:
  `e658bc0f96d76d60d59de9f5521b5f8bbb576584dabec68abd33b8750a6fe4c2`
- V4 executor ABI:
  `14e3c5163b30da0af3b4ee083803b4f3532e83c1d82ed2ebe8720bad91153de7`
- Legacy Arbitrum Sepolia manifest:
  `e35253ff1c1aaa16e67cf6543942332031ac1691392bb578a07ca6fa2c5aa7e2`
- `foundry.lock`:
  `9b2fef684250ea05367cf4fd54a7c62c50b24166e208c9604f6ca56caf124579`
- `foundry.toml`:
  `c11e7f43a2d82397b24b3ba16475f7a83020ff84c476e51b1459d441f95e4b2a`
  (pre-release-hygiene baseline)
- Controller storage-layout snapshot:
  `5226fb0ea2e19fbc096556596f0ead9d2881ab1ea0c9ad463a2b77e47bbd29ae`
- Vault storage-layout snapshot:
  `0c8296a828f284f51797a263e2bba9ae6c3e470ba57d3e48b74b7d0b5a15932b`

## Primary dependency pins

- `cofhe-contracts`: `cb76c99620e1b4acd395e00672be21e48702429f`
- `fhenix-confidential-contracts`: `0823e57e320c1c72e0caee7faeebc4d3a0710373`
- `forge-std`: `3b20d60d14b343ee4f908cb8079495c07f5e8981`
- `openzeppelin-contracts`: `dbb6104ce834628e473d2173bbc9d47f81a9eec3`
- `openzeppelin-contracts-upgradeable`: `723f8cab09cdae1aca9ec9cc1cfa040c2d4b06c1`
- `v4-core`: `e50237c43811bd9b526eff40f26772152a42daba`

## Finding disposition and progression gate

| Finding | Severity | Stage disposition |
|---|---|---|
| Encrypted-zero permanent live lock | Medium | Remediate in replacement and verify in consolidated end audit |
| Permissionless pre-claim lock stranding | High | Legacy production blocker; close through fresh escrow replacement and regression tests |
| Fee-on-transfer wrapper undercollateralization | High | Legacy production blocker; close through hardened fresh wrapper/gateway deployment and regression tests |
| Unbound swap execution terms | Medium | Superseded only after bound controller tests and consolidated end audit |
| Output-rate precision liveness | Medium | Remediate in the separated swap design |
| FHE operator-rotation desynchronization | Medium | Remediate through epoch/resubmission lifecycle |
| Evaluation after deadline | Low | Remediate in competition terminal semantics |
| Missing upgrade chain validation | Medium | Remediate before any upgrade tooling is used |
| Proxy-override manifest mismatch | Medium | Remove or strictly bind override in replacement tooling |

There are no Critical findings. The two High findings block any production use
or upgrade-based continuation of the legacy combined swap architecture. They do
not require rehabilitating superseded source before the fresh-address
restructuring begins; closure requires exploit-regression tests and the
consolidated end audit against the replacement wrapper, escrow, and controller. Internal audit
evidence complements and does not replace an independent external audit.

## Residual and operational notes

- Local CoFHE mocks do not establish production cryptographic behavior.
- The auditor remote-version check was unavailable; the locally installed
  version was recorded without claiming it is current.
- The legacy deployment and manifest remain unchanged.
- The stale controller ABI has been archived and the canonical legacy ABI now
  matches baseline source. CI compares all checked-in legacy ABIs and both
  upgradeable storage layouts against compiler output.
