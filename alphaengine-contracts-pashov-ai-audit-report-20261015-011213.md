# 🔐 Security Review — alphaengine-contracts

---

## Scope

|  |  |
| --- | --- |
| **Mode** | default + explicit critical dependencies; source review only, no live CoFHE validation |
| **Files reviewed** | `./script/DeployAlphaEngineCreate2.s.sol` · `./script/GenerateAlphaEngineManageRoot.s.sol` · `./script/DeployAlphaEngineV2.s.sol`<br>`./src/swap/AlphaEngineConfidentialSwapController.sol` · `./src/swap/AlphaEngineConfidentialSwapEscrow.sol` · `./src/libraries/AlphaEngineExecutionHashLib.sol`<br>`./src/libraries/AlphaEngineStrategyHashLib.sol` · `./src/libraries/AlphaEngineManageLeafHashLib.sol` · `./src/libraries/AlphaEngineRollingSpendLib.sol`<br>`./src/executors/AlphaEngineV4SwapExecutor.sol` · `./src/decoders/AlphaEngineERC4626DecoderAndSanitizer.sol` · `./src/decoders/AlphaEnginePendleV4PtDecoderAndSanitizer.sol`<br>`./src/decoders/AlphaEngineERC20DecoderAndSanitizer.sol` · `./src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol` · `./src/fherc20/AlphaEngineConfidentialAssetRegistry.sol`<br>`./src/fherc20/AlphaEngineConfidentialAssetGateway.sol` · `./src/vault/AlphaEngineVaultExecutionManager.sol` · `./src/vault/AlphaEngineFundVault.sol`<br>`./src/vault/AlphaEngineUSDCVaultManager.sol` · `./src/strategy/AlphaEngineTraderQualificationRegistry.sol` · `./src/strategy/AlphaEngineCapitalStrategyManager.sol`<br>`./src/strategy/AlphaEngineCompetitionStrategyManager.sol` · `lib/fhenix-confidential-contracts/contracts/FHERC20/FHERC20Core.sol` · `lib/fhenix-confidential-contracts/contracts/FHERC20/FHERC20Upgradeable.sol`<br>`lib/fhenix-confidential-contracts/contracts/FHERC20/extensions/FHERC20ERC20WrapperCore.sol` · `lib/fhenix-confidential-contracts/contracts/FHERC20/extensions/FHERC20ERC20WrapperUpgradeable.sol` · `lib/fhenix-confidential-contracts/contracts/FHERC20/utils/FHERC20WrapperClaims.sol`<br>`lib/fhenix-confidential-contracts/contracts/ERC20Confidential/ERC20ConfidentialLib.sol` · `lib/cofhe-contracts/contracts/FHE.sol` · `lib/cofhe-contracts/contracts/internal/host-chain/contracts/TaskManager.sol`<br>`lib/cofhe-contracts/contracts/internal/host-chain/contracts/ACL.sol` · `lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol` · `lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 2 (pass 1 ran 9/12 agents) |
| **Memory** | 0 records before this scan · 10 after · `257eb31` |

---

## Findings

[90] **1. Public cancellation accepts completed evaluations**

`AlphaEngineCompetitionStrategyManager.cancelExpiredCompetition` · Confidence: 90 · seen in 2/2 runs · NEW

**Description**
Any caller cancels a fully evaluated competition after its deadline and blocks finalization, qualification, and public score publication.

Severity: Medium. Source evidence: timely evaluation can leave status Evaluating with equal evaluated and active counts. `finalizeCompetition` accepts that completed state without a deadline check, while public expiry cancellation accepts it after the deadline and writes terminal Cancelled. Qualification and public score publication require Finalized.

**Fix (Option A — guard the Evaluating status)**

```diff
--- a/src/strategy/AlphaEngineCompetitionStrategyManager.sol
+++ b/src/strategy/AlphaEngineCompetitionStrategyManager.sol
@@ -771,6 +771,10 @@
             (competition.status != CompetitionStatus.Active
                     && competition.status != CompetitionStatus.Evaluating)
                 || block.timestamp <= competition.evaluationDeadline
+                || (
+                    competition.status == CompetitionStatus.Evaluating
+                        && competition.evaluatedCount == competition.activeSubmissionCount
+                )
         ) {
             revert CompetitionCancellationNotAvailable(
                 competitionId, competition.status, block.timestamp
```

The unapplied repair preserves authorized emergency cancellation and treats evaluationDeadline as the evaluation deadline, consistent with current finalization guards. Confirm that semantic choice before remediation; a finalization deadline would require a different explicit rule.

**Fix (Option B — guard nonempty completed counts)**

```diff
             (competition.status != CompetitionStatus.Active
                     && competition.status != CompetitionStatus.Evaluating)
                 || block.timestamp <= competition.evaluationDeadline
+                || (
+                    competition.activeSubmissionCount != 0
+                        && competition.evaluatedCount == competition.activeSubmissionCount
+                )
```

This reviewer proposed a different predicate for the same public expiry path. Choose one consistent rule after confirming the deadline semantics; neither proposal changes the separate authorized emergency cancellation path.

---

[90] **2. Near-total redemptions make later deposits lose value**

`AlphaEngineUSDCVaultManager.completeRedeem` · Confidence: 90 · seen in 1/2 runs · NEW

**Description**
A shareholder leaves one share unit against locked profit, so later deposit rounding transfers new depositor value to that shareholder.

Severity: High for the FundVault source path; this module is omitted from the current beta deployment. This differs from the fee finding because zero fees suffice, and the harmed party is a later depositor.

Source evidence: zero fees are permitted. The final-redemption guard rejects only the exact total supply. A partial exit can burn all but one share unit while leaving locked profit unchanged. After unlock, previewDeposit floors against that one-unit supply, and deposit checks only nonzero shares and minShares. FundVault verifies exact USDC receipt but adds no precision bound. Canonical section 6 requires deposit rounding residue below one USDC base unit of value.

Exact integer check: 100 USDC creates 100e18 share units. An honest funded 100-USDC profit starts a vest. An exit of all but one unit at vest start receives 99.999999 USDC, leaving 100.000001 USDC and one share unit. After unlock, a 199-USDC deposit mints one unit with minShares=1. Its redemption value becomes 149.5 USDC; the incumbent receives the 49.5-USDC difference. No donation, false report, non-exact token, or privileged misconduct is required. This is a source and static-arithmetic result, not an executed Solidity test.

**Fix**

```diff
--- a/src/vault/AlphaEngineUSDCVaultManager.sol
+++ b/src/vault/AlphaEngineUSDCVaultManager.sol
@@ -62,6 +62,7 @@
     error UnauthorizedNAVReporter(address caller);
     error ZeroAssets();
     error ZeroShares();
+    error DepositRoundingLoss(uint256 assets, uint256 pricedAssets);
     error ZeroReportHash();
     error InsufficientShares(uint256 shares, uint256 minimum);
     error InsufficientAssets(uint256 assets, uint256 minimum);
@@ -375,6 +376,10 @@
         uint256 assetsForShares = availableAssets();
         if (assetsForShares == 0) revert InsolventVault();
         shares = Math.mulDiv(assets, supply, assetsForShares);
+        if (shares == 0) return 0;
+        uint256 pricedAssets =
+            Math.mulDiv(shares, assetsForShares, supply, Math.Rounding.Ceil);
+        if (pricedAssets != assets) revert DepositRoundingLoss(assets, pricedAssets);
     }

     function previewRedeem(uint256 shares) public view returns (uint256 assets) {
```

The unapplied guard preserves the canonical floor formula and initial/zero-share preview behavior. It rejects a deposit when the pre-deposit value of its minted shares falls short by at least one USDC base unit. Low-precision states will reject many deposit amounts; preventing those states requires a separate owner-approved residual-supply policy. This repair has passed only a read-only patch check, not compilation or runtime tests.

---

[90] **3. Early redemptions omit fees from share prices**

`AlphaEngineUSDCVaultManager.completeRedeem` · Confidence: 90 · seen in 2/2 runs · NEW

**Description**
A shareholder redeems gross vested profit before fee settlement, so remaining shareholders bear the fee or the fee recipient loses it.

Severity: High for the FundVault source path; FundVault is omitted from the current beta deployment. This accounting issue was also reported in the September 2026 audit; NEW means a new ledger record, not a new regression.

Source evidence: `completeRedeem` lowers managed assets and share supply but leaves pending fees unchanged; `_supplyAfterFinishedFee` excludes those fees while profit remains locked. At maturity, `_settleFinishedProfit` clears the fee even when `_feeShares` returns zero. An honest, funded gain and an ordinary shareholder suffice.

Arithmetic check: with 1,000 USDC principal, 100 USDC gain, a 20 USDC fee, and 1 USDC still locked, a 98% exit receives 1,077.02 USDC. The remaining 2% holds 22.98 USDC before the whole fee, then 2.98 USDC after settlement. Its original principal was 20 USDC. A larger exit can instead leave assets below the fee and erase the recipient's fee entirely. These are static integer checks, not live integration tests.

**Fix (Option A — defer fee-bearing redemptions)**

```diff
--- a/src/vault/AlphaEngineUSDCVaultManager.sol
+++ b/src/vault/AlphaEngineUSDCVaultManager.sol
@@ -263,6 +263,9 @@

         _settleFinishedProfit();
         uint256 remainingProfit = remainingLockedProfit();
+        if (remainingProfit != 0 && pendingFeeAssets != 0) {
+            revert ProfitStillVesting(remainingProfit);
+        }
         if (request.shares == FUND_VAULT.totalSupply() && remainingProfit != 0) {
             revert FinalRedemptionWhileProfitLocked(remainingProfit);
         }
```

This unapplied containment delays fee-bearing redemption completion until vesting ends. Preserving early completion requires an owner-approved change to the canonical fee-pricing formula and corresponding previews; this audit does not silently replace that formula.

**Fix (Option B — reserve vested fees in prices)**

```diff
--- a/src/vault/AlphaEngineUSDCVaultManager.sol
+++ b/src/vault/AlphaEngineUSDCVaultManager.sol
@@ -384,7 +384,15 @@
     }

     function availableAssets() public view returns (uint256) {
-        return managedAssets - remainingLockedProfit();
+        uint256 remainingProfit = remainingLockedProfit();
+        uint256 recognizedAssets = managedAssets - remainingProfit;
+        if (remainingProfit == 0 || pendingFeeAssets == 0) return recognizedAssets;
+
+        uint256 remainingFeeable = remainingProfit - remainingLockedRecoveryProfit();
+        uint256 unvestedFeeAssets =
+            Math.mulDiv(remainingFeeable, pendingFeeBps, BPS, Math.Rounding.Ceil);
+        uint256 vestedFeeAssets = pendingFeeAssets - Math.min(pendingFeeAssets, unvestedFeeAssets);
+        return recognizedAssets - vestedFeeAssets;
     }

     function remainingLockedProfit() public view returns (uint256) {
```

This alternative changes the canonical availableAssets equation. It requires an owner-approved accounting decision and loss/recovery, preview, fee, and rounding tests before use. It is an unapplied proposal, not an EVM-validated repair. The fee-only containment does not address the separate zero-fee precision finding.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | Public cancellation accepts completed evaluations |
| 2 | [90] | Near-total redemptions make later deposits lose value |
| 3 | [90] | Early redemptions omit fees from share prices |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **A donation can block refunds at the wrapper supply limit** — `AlphaEngineConfidentialSwapEscrow.refundSwapIntent` · seen in 1/2 runs · NEW — Code smells: refunds must re-shield; mint limits use physical reserves that include donations. At rate one, a uint64-max refund plus one donated unit exceeds the reserve cap. No admitted asset with the required balance was established; do not remove the overflow guard. A safe repair requires an approved reserve-accounting or refund-interface design.
- **Public claims do not verify the recipient's token increase** — `AlphaEngineFHERC20ERC20Wrapper.claimUnshielded` · seen in 2/2 runs · NEW — Code smells: single and batch claims trust the transfer amount; escrow accepts earlier claims from its pooled balance. A short transfer on a public preclaim can shift a shortfall between escrow obligations. This requires an underlying token outside the approved exact-transfer restriction; fresh escrow claims already check their balance increase.
- **Direct shielding trusts the requested token amount** — `AlphaEngineFHERC20ERC20Wrapper.shield` · seen in 2/2 runs · NEW — Code smells: direct shielding and ERC1363 callbacks credit requested amounts without reserve checks. A token that transfers less can create underbacked confidential units through either ingress path. The approved exact-transfer asset restriction excludes that condition; no violating admitted asset was established.
- **Old NAV can affect deposit and redemption prices** — `AlphaEngineUSDCVaultManager.completeRedeem` · seen in 1/2 runs · NEW — Code smells: pricing lacks a report-age gate; monotonic reference blocks do not bound age. A depositor or redeemer can use an old NAV before a delayed report. The plan requires a maximum age, but the permitted age, external reporting response, loss scenario, and emergency-pause policy need verification before FundVault activation.
- **Some wrapper amounts exceed the pool's signed range** — `AlphaEngineV4SwapExecutor.executeExactInput` · seen in 1/2 runs · NEW — Code smells: uint256 input has no signed pool bound; settlement requires an exact int128 debit. A 25-decimal asset can produce an admitted uint64 confidential amount above the pool domain. No configured asset with that amount was established; refunds remain available, and material loss was not proved.
- **ERC4626 exits can omit spent shares from risk checks** — `AlphaEngineVaultExecutionManager._validateCalls` · seen in 2/2 runs · NEW — Code smells: approval checks cover spends; exits burn shares directly; balance checks inspect listed assets. An approved exit can omit its share token from the risk envelope. No active ERC4626 policy or unprivileged path to an incomplete evaluator-approved commitment was established.
- **The TaskManager accepts cast shapes its library never emits** — `TaskManager.createTask` · seen in 1/2 runs · NEW — Code smells: the cast permits zero or two plaintext inputs; return type can differ from cast type. A caller must pass the access list and operand ACL. Normal FHE.sol calls use the canonical shape; coprocessor behavior and an affected AlphaEngine recipient remain unverified. This vendor lead needs upstream clarification, not an unreviewed dependency patch.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
