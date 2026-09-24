# 🔐 Security Review — alphaengine-contracts

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | ALL / default / commit `0595ef49e7cdb61b03061dbade3718e540903042` / Solidity Auditor v2 (upstream v3) / supplied release evidence: 306 of 306 tests passed |
| **Files reviewed**               | `DeployAlphaEngineV2.s.sol` · `GenerateAlphaEngineManageRoot.s.sol` · `AlphaEngineERC20DecoderAndSanitizer.sol`<br>`AlphaEngineERC4626DecoderAndSanitizer.sol` · `AlphaEnginePendleV4PtDecoderAndSanitizer.sol` · `AlphaEngineV4SwapExecutor.sol`<br>`AlphaEngineConfidentialAssetGateway.sol` · `AlphaEngineConfidentialAssetRegistry.sol` · `AlphaEngineFHERC20ERC20Wrapper.sol`<br>`IAlphaEngineCapitalStrategyManager.sol` · `IAlphaEngineConfidentialAssetRegistry.sol` · `IAlphaEngineConfidentialSwapController.sol`<br>`IAlphaEngineConfidentialSwapEscrow.sol` · `IAlphaEngineDecoderAndSanitizer.sol` · `IAlphaEngineEncryptedUnshieldFHERC20Wrapper.sol`<br>`IAlphaEngineFundVault.sol` · `IAlphaEnginePendleRouterV4.sol` · `IAlphaEngineSwapExecutor.sol`<br>`IAlphaEngineTraderQualificationRegistry.sol` · `IAlphaEngineVaultExecutionManager.sol` · `AlphaEngineExecutionHashLib.sol`<br>`AlphaEngineManageLeafHashLib.sol` · `AlphaEngineRollingSpendLib.sol` · `AlphaEngineStrategyHashLib.sol`<br>`AlphaEngineCapitalStrategyManager.sol` · `AlphaEngineCompetitionStrategyManager.sol` · `AlphaEngineTraderQualificationRegistry.sol`<br>`AlphaEngineConfidentialSwapController.sol` · `AlphaEngineConfidentialSwapEscrow.sol` · `AlphaEngineFundVault.sol`<br>`AlphaEngineUSDCVaultManager.sol` · `AlphaEngineVaultExecutionManager.sol` · dependency `FHE.sol`<br>dependency `ICofhe.sol` · dependency `TaskManager.sol` · dependency `FHERC20.sol`<br>dependency `FHERC20ERC20Wrapper.sol` · dependency `FHERC20WrapperClaimHelper.sol` · dependency `FHESafeMath.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Findings

[98] **1. Redemptions during vesting can erase or transfer the performance-fee liability**

`AlphaEngineUSDCVaultManager.completeRedeem` · Confidence: 98 · [agents: 2, 4, 5, 8]

**Description**
Partial redemptions are paid from gross vested assets while the fixed `pendingFeeAssets` liability remains deferred, so a near-total redeemer can erase the fee through share rounding or leave the remaining LPs bearing the exiting holder's fee.

**Fix**

```diff
  _settleFinishedProfit();
+ uint256 remainingProfit = remainingLockedProfit();
+ if (remainingProfit != 0 && pendingFeeAssets != 0) {
+     revert ProfitStillVesting(remainingProfit);
+ }
  assets = previewRedeem(request.shares);
```

The simple fail-closed repair is to delay completion of fee-bearing redemptions until settlement; a proportional fee-reservation design is also valid but must preserve loss clawbacks and be proved independently.

---

[95] **2. Public inherited shielding can mint unbacked confidential supply**

`AlphaEngineFHERC20ERC20Wrapper.shield` · Confidence: 95 · [agents: 1, 2, 5, 6, 7, 8]

**Description**
The wrapper's inherited public ingress mints from the requested amount without checking the received balance delta, so a registered fee-on-transfer asset can drain reserves belonging to honest confidential holders while bypassing the guarded gateway.

**Fix**

```diff
- // AlphaEngine inherits shield(...) and onTransferReceived(...) unchanged.
+ function shield(address to, uint256 amount) public override returns (euint64 minted) {
+     uint256 aligned = amount - (amount % rate());
+     uint256 beforeBalance = IERC20(underlying()).balanceOf(address(this));
+     minted = super.shield(to, amount);
+     if (IERC20(underlying()).balanceOf(address(this)) != beforeBalance + aligned) {
+         revert UnexpectedUnderlyingReceipt(aligned);
+     }
+ }
+ // Disable onTransferReceived unless it can enforce the same exact-receipt invariant.
```

---

[92] **3. Pooled preclaim balances let one swap consume another swap's backing**

`AlphaEngineConfidentialSwapEscrow._claimExactInputUnderlying` · Confidence: 92 · [agents: 5, 8]

**Description**
For an already-claimed request the escrow treats its aggregate token balance as proof of that request's receipt, allowing the first refund to consume another intent's backing when wrapper-to-escrow transfers deliver less than the recorded claim amount.

**Fix**

```diff
- // Inherited claimUnshielded(...) transfers without checking recipient receipt.
+ Claim memory pending = getClaim(ctHash);
+ uint256 beforeBalance = IERC20(underlying()).balanceOf(pending.to);
+ super.claimUnshielded(ctHash, decryptedAmount, decryptionProof);
+ uint256 expected = uint256(decryptedAmount) * rate();
+ if (IERC20(underlying()).balanceOf(pending.to) != beforeBalance + expected) {
+     revert UnexpectedUnderlyingReceipt(expected);
+ }
```

Prefer enforcing exact recipient balance increase inside the wrapper before a claim can become terminal; aggregate escrow custody cannot safely substitute for per-claim receipt evidence.

---

[90] **4. ERC4626 exits bypass position-share risk limits**

`AlphaEngineVaultExecutionManager._validateCalls` · Confidence: 90 · [agents: 8]

**Description**
ERC4626 `withdraw` and `redeem` burn FundVault-owned shares without an ERC20 approval, so an authorization can omit the share token from its risk envelope and bypass its configured per-execution and rolling spend caps.

**Fix**

```diff
  if (selector == IERC20.approve.selector) {
      // existing approval-to-risk binding
  }
+ if (selector == IERC4626.withdraw.selector || selector == IERC4626.redeem.selector) {
+     uint256 shareRiskIndex = _riskLimitIndex(call_.target, limits, i);
+     if (limits[shareRiskIndex].maxSpend == 0) {
+         revert MissingPositionShareSpendLimit(i, call_.target);
+     }
+ }
```

The existing before/after balance enforcement will then measure the actual shares burned, including variable-share `withdraw` calls.

---

[88] **5. Zero-valued confidential locks can permanently block escrow migration**

`AlphaEngineFHERC20ERC20Wrapper.claimUnshielded` · Confidence: 88 · [agents: 1, 2, 5, 6, 7, 8]

**Description**
FHERC20 deliberately turns an overdraw into an initialized encrypted zero, but the inherited claim path unconditionally calls `transfer(0)`, making the only refund transition permanently revert for a registered token that rejects zero transfers.

**Fix**

```diff
  Claim memory claim = _handleClaim(ctHash, decryptedAmount, decryptionProof);
- SafeERC20.safeTransfer(IERC20(underlying()), claim.to, uint256(claim.decryptedAmount) * rate());
+ if (claim.decryptedAmount != 0) {
+     SafeERC20.safeTransfer(
+         IERC20(underlying()), claim.to, uint256(claim.decryptedAmount) * rate()
+     );
+ }
```

---

[75] **6. V4 accepts confidential amounts outside its signed delta domain**

`AlphaEngineV4SwapExecutor.unlockCallback` · Confidence: 75 · [agents: 1, 2, 6]

**Description**
A high-decimal registered asset can produce a valid `uint64 * rate` input above `int128.max`, making the committed V4 exact-input route mathematically unable to execute and leaving refund or emergency pause as the only terminal path.

---

[75] **7. Proxy implementation upgrades do not invalidate policy leaves**

`AlphaEngineVaultExecutionManager._validateCalls` · Confidence: 75 · [agents: 3, 5, 8]

**Description**
Policy leaves bind `target.codehash`, which remains unchanged when an ERC4626 proxy changes implementation, so a previously reviewed proof can authorize materially different target behavior until governance revokes the root.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [98] | Redemptions during vesting can erase or transfer the performance-fee liability |
| 2 | [95] | Public inherited shielding can mint unbacked confidential supply |
| 3 | [92] | Pooled preclaim balances let one swap consume another swap's backing |
| 4 | [90] | ERC4626 exits bypass position-share risk limits |
| 5 | [88] | Zero-valued confidential locks can permanently block escrow migration |
| 6 | [75] | V4 accepts confidential amounts outside its signed delta domain |
| 7 | [75] | Proxy implementation upgrades do not invalidate policy leaves |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **ERC4626 entries do not require an output-share bound** — `AlphaEngineVaultExecutionManager._validateCalls` — Code smells: `deposit` can spend a risk-bound underlying while the ERC4626 share token is absent from `limits` — a production target/root and an adverse exchange-rate trace are still required to establish material loss.
- **Late finalization can strand every eligible winner** — `AlphaEngineCompetitionStrategyManager.finalizeCompetition` — Code smells: finalization has no `qualificationValidUntil` check and finalized competitions cannot be cancelled — exploitation requires the privileged finalizer to act after the committed validity window.
- **Swap-executor caller rotation ignores live locks** — `AlphaEngineV4SwapExecutor.setAuthorizedCaller` — Code smells: the owner can rotate away from the escrow snapshotted by active intents without pause or a live-lock check — users can still recover after expiry or an independent emergency pause.
- **Production TaskManager signer safety is not established locally** — `TaskManager.setDecryptResultSigner` — Code smells: the dependency deliberately accepts a zero signer as debug mode, which makes decrypt-result verification succeed without a signature — the live Fhenix deployment's signer state and governance were outside repository evidence.
- **Decrypt-result signatures omit a deployment domain** — `TaskManager._computeDecryptResultHash` — Code smells: the digest omits `address(this)` and encodes `block.chainid` as `uint64` — AlphaEngine hardcodes one TaskManager, so a production same-signer cross-instance replay path remains unverified.
- **Role-collapse escape hatch is not chain-restricted** — `DeployAlphaEngineV2._validateConfig` — Code smells: `testOnlyRoleCollapse` disables separation checks for any configured chain ID — a release process may reject such a manifest, but the deployment script itself does not.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
