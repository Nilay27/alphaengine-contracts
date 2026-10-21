# 🔐 Security Review — alphaengine-contracts

---

## Scope

|  |  |
| --- | --- |
| **Mode** | default + explicit critical dependencies; one max-reasoning pass; source review |
| **Files reviewed** | `./script/DeployAlphaEngineCreate2.s.sol` · `./script/GenerateAlphaEngineManageRoot.s.sol` · `./script/DeployAlphaEngineV2.s.sol`<br>`./src/swap/AlphaEngineConfidentialSwapController.sol` · `./src/swap/AlphaEngineConfidentialSwapEscrow.sol` · `./src/libraries/AlphaEngineExecutionHashLib.sol`<br>`./src/libraries/AlphaEngineStrategyHashLib.sol` · `./src/libraries/AlphaEngineManageLeafHashLib.sol` · `./src/libraries/AlphaEngineRollingSpendLib.sol`<br>`./src/executors/AlphaEngineV4SwapExecutor.sol` · `./src/decoders/AlphaEngineERC4626DecoderAndSanitizer.sol` · `./src/decoders/AlphaEnginePendleV4PtDecoderAndSanitizer.sol`<br>`./src/decoders/AlphaEngineERC20DecoderAndSanitizer.sol` · `./src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol` · `./src/fherc20/AlphaEngineConfidentialAssetRegistry.sol`<br>`./src/fherc20/AlphaEngineConfidentialAssetGateway.sol` · `./src/vault/AlphaEngineVaultExecutionManager.sol` · `./src/vault/AlphaEngineFundVault.sol`<br>`./src/vault/AlphaEngineUSDCVaultManager.sol` · `./src/strategy/AlphaEngineTraderQualificationRegistry.sol` · `./src/strategy/AlphaEngineCapitalStrategyManager.sol`<br>`./src/strategy/AlphaEngineCompetitionStrategyManager.sol` · `lib/fhenix-confidential-contracts/contracts/FHERC20/FHERC20Core.sol` · `lib/fhenix-confidential-contracts/contracts/FHERC20/FHERC20Upgradeable.sol`<br>`lib/fhenix-confidential-contracts/contracts/FHERC20/extensions/FHERC20ERC20WrapperCore.sol` · `lib/fhenix-confidential-contracts/contracts/FHERC20/extensions/FHERC20ERC20WrapperUpgradeable.sol` · `lib/fhenix-confidential-contracts/contracts/FHERC20/utils/FHERC20WrapperClaims.sol`<br>`lib/fhenix-confidential-contracts/contracts/ERC20Confidential/ERC20ConfidentialLib.sol` · `lib/cofhe-contracts/contracts/FHE.sol` · `lib/cofhe-contracts/contracts/internal/host-chain/contracts/TaskManager.sol`<br>`lib/cofhe-contracts/contracts/internal/host-chain/contracts/ACL.sol` · `lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol` · `lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol` |
| **Confidence threshold (1-100)** | 75 |

---

## Findings

_None — this scan raised no findings._

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Redemptions use old NAV between reports** — `AlphaEngineUSDCVaultManager.completeRedeem` — Code smells: Redemptions lack a report-age check; pause blocks loss reports while pending redemptions remain executable. — A shareholder can redeem before a position loss reaches NAV, including during pause. The owner must define the permitted delay and admission at old NAV.
- **Unrequested vault shares prevent final closure** — `AlphaEngineUSDCVaultManager.completeRedeem` — Code smells: FundVault accepts direct share transfers or deposits to itself without a request; the floor counts those shares. — An attacker can strand about one whole share's value and prevent final closure. Harm beyond the accepted consolidation rule remains unproven.
- **TaskManager accepts malformed casts** — `TaskManager.createTask` — Code smells: TaskManager accepts casts with zero or two plaintext arguments and conflicting destination and return types. — An admitted caller can share malformed handles with a wrapper, which stores derived recipient balances. Live coprocessor behavior and victim impact remain unverified.
- **TaskManager accepts conflicting result types** — `TaskManager.createTask` — Code smells: TaskManager validates returnType separately from the trivial-encryption type or arithmetic operand type. — An admitted caller can label uint128 tasks as uint64 and share the result with a wrapper. The coprocessor's type rules and victim impact remain unverified.
- **TaskManager accepts unsupported operation IDs** — `TaskManager.createTask` — Code smells: TaskManager accepts `_31`, emits an empty operation name and grants access to the result handle. — An admitted caller can feed that handle into a wrapper's recipient balance. The coprocessor response and the recipient's exit failure remain unverified.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
