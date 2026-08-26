# 🔐 Security Review — alphaengine-contracts

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | ALL / default / baseline `49d96e8a80d6903d1d30affc6f836bcc0ac13800` |
| **Files reviewed**               | `DeployAlphaEngineArbitrumSepolia.s.sol` · `DeployAlphaEngineIntentController.s.sol` · `UpgradeAlphaEngineIntentController.s.sol`<br>`AlphaEngineIntentController.sol` · `AlphaEngineV4SwapExecutor.sol` · `AlphaEngineFHERC20ERC20Wrapper.sol`<br>`AlphaEngineConfidentialVault.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Findings

[95] **1. Encrypted-zero transfers create permanent live locks**

`AlphaEngineConfidentialVault.lockForSwapIntent` · Confidence: 95 · [agents: 5]

**Description**
A valid nonzero ciphertext handle may encrypt zero after an insufficient confidential transfer, but both terminal paths reject the only valid decrypted value and can permanently poison `liveSwapLockCount`.

**Fix**

```diff
- if (decryptedInputAmount == 0) revert ZeroAmount();
+ if (decryptedInputAmount == 0) {
+     _verifyAndConsumeZeroClaim(intentId, decryptionProof);
+     _terminalizeZeroValueLock(intentId);
+     return;
+ }
```
---

[90] **2. Permissionless pre-claiming strands swap locks**

`AlphaEngineConfidentialVault.claimUnshielded` · Confidence: 90 · [agents: 2]

**Description**
Anyone with a public decryption proof can consume a swap unshield claim without advancing its lock, after which settlement and refund both revert `AlreadyClaimed` while the underlying remains stranded in the vault.

**Fix**

```diff
- function claimUnshielded(...) public virtual {
+ function claimUnshielded(...) public virtual {
+     Claim memory pending = getClaim(ctHash);
+     if (msg.sender != pending.to) revert UnauthorizedClaimant(msg.sender, pending.to);
      Claim memory claim = _handleClaim(ctHash, decryptedAmount, decryptionProof);
      ...
  }
```
Also map swap claim handles to intent IDs and reject them from the vault's generic claim relay.

---

[90] **3. Public wrapper ingress can mint unbacked confidential supply**

`AlphaEngineFHERC20ERC20Wrapper.shield` · Confidence: 90 · [agents: 3]

**Description**
The inherited public `shield` mints from the nominal transfer amount without verifying actual receipt, so a registered fee-on-transfer asset can drain reserves belonging to existing confidential holders.

**Fix**

```diff
- underlying.safeTransferFrom(msg.sender, address(this), alignedAmount);
- return _mint(to, FHE.asEuint64(uint64(amount / rate())));
+ uint256 beforeBalance = underlying.balanceOf(address(this));
+ underlying.safeTransferFrom(msg.sender, address(this), alignedAmount);
+ if (underlying.balanceOf(address(this)) != beforeBalance + alignedAmount) {
+     revert UnexpectedUnderlyingBalance();
+ }
+ return _mint(to, FHE.asEuint64(uint64(alignedAmount / rate())));
```
Apply the same receiver-balance assertion to every ingress path and settlement shielding.

---

[75] **4. Swap execution terms are not bound to the user's commitment**

`AlphaEngineIntentController.executeSwapIntent` · Confidence: 75 · [agents: 6]

**Description**
The listener can substitute the output wrapper, current executor, minimum output, and concrete calldata because none are bound to the stored route metadata or payload hash.

---

[75] **5. Higher-decimal swap outputs frequently fail wrapper precision**

`AlphaEngineConfidentialVault._shieldOutputForSettlement` · Confidence: 75 · [agents: 2]

**Description**
Exact-input AMM output is not quantized to the wrapper rate, so ordinary output amounts for a capped 18-decimal asset can revert settlement and keep the input locked until refund.

---

[75] **6. FHE operator rotation desynchronizes authorization and ciphertext access**

`AlphaEngineIntentController.setListenerOperator` · Confidence: 75 · [agents: 4]

**Description**
The old listener retains access to previously submitted ciphertext while the new listener lacks that access but becomes the only address authorized to post evaluations.

---

[75] **7. Evaluation remains possible after the strategy deadline**

`AlphaEngineIntentController.submitStrategyEvaluationScores` · Confidence: 75 · [agents: 3]

**Description**
Score submission checks active status but not the recorded deadline, allowing a trusted listener to post the first evaluation indefinitely after expiry.

---

[75] **8. Upgrade execution does not validate the live chain**

`UpgradeAlphaEngineIntentController.run` · Confidence: 75 · [agents: 2]

**Description**
The script reads a manifest chain ID but never compares it with `block.chainid`, so an operator using the wrong RPC can upgrade a same-address proxy while preserving misleading chain metadata.

---

[75] **9. Proxy overrides corrupt deployment attribution**

`UpgradeAlphaEngineIntentController._writeManifest` · Confidence: 75 · [agents: 2]

**Description**
When `PROXY_ADDRESS` differs from the manifest proxy, the script upgrades the override but records its new implementation against the original manifest proxy.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [95] | Encrypted-zero transfers create permanent live locks |
| 2 | [90] | Permissionless pre-claiming strands swap locks |
| 3 | [90] | Public wrapper ingress can mint unbacked confidential supply |
| 4 | [75] | Swap execution terms are not bound to the user's commitment |
| 5 | [75] | Higher-decimal swap outputs frequently fail wrapper precision |
| 6 | [75] | FHE operator rotation desynchronizes authorization and ciphertext access |
| 7 | [75] | Evaluation remains possible after the strategy deadline |
| 8 | [75] | Upgrade execution does not validate the live chain |
| 9 | [75] | Proxy overrides corrupt deployment attribution |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Cross-contract reentrancy window** — `AlphaEngineConfidentialVault.settleSwapIntent` — Code smells: controller and lock remain active across multiple external calls without a mutex — exploitability still depends on a callback path that can satisfy controller-only authority.
- **Premature public amount disclosure** — `AlphaEngineFHERC20ERC20Wrapper.unshield` — Code smells: immediate `FHE.allowPublic` and an emitted request handle — production CoFHE publication timing and the intended confidentiality window require confirmation.
- **EIP-7702 listener-role borrowing** — `AlphaEngineIntentController.initialize` — Code smells: any nonzero listener address is accepted and privilege relies only on `msg.sender` — target-chain support and the deployed listener account type remain unverified.
- **Single-key and split-admin migration risk** — `DeployAlphaEngineArbitrumSepolia.run` — Code smells: business ownership and two ProxyAdmins initially share one owner without an atomic transfer procedure — actual production Safe/timelock configuration is not present in the baseline.
- **Immutable PoolManager misconfiguration** — `AlphaEngineV4SwapExecutor.constructor` — Code smells: only the zero address is rejected — a wrong-chain address or EOA produces an unusable executor, though governance can deploy and select a replacement.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
