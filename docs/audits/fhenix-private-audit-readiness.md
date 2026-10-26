# Fhenix Internal Review Readiness

- Status: Stage 16 implementation complete; admission-review documentation prepared
- Review type: Fhenix FHE-efficiency, behavior and basic-security review
- Designated reviewer: `@liorbond`
- Historical Fhenix review commit: `0595ef4`; dependency migration is a separate remediation commit
- Production claim: none; this is not a full external security audit

## 16 October internal source checkpoint

Commit `7ed4c49d2568bc8f89bf6b426b5c66321dbe3f5a` has a refreshed X-Ray,
requirements-to-existing-fuzz mapping and one Solidity Auditor pass with all
12 specialties at Max: zero confirmed findings and five unscored leads. The
[review record](internal-review-2026-10-16.md) preserves the exact scope,
dispositions, CI results and limits. This does not extend the historical
Fhenix review or close live-network/governance gates.

The confirmed October 16 Sepolia manifest records 24 explorer source records.
[Mainnet preparation](../engineering/mainnet-preparation-2026-10-16.md) now
records the user-broadcast Arbitrum One deployment and bootstrap handover:
17 deployment and 15 handover transactions succeeded; all 24 runtime hashes,
seven proxy pairs and five paused states match. All 24 contracts have
explorer-verified source and independently matched runtime hashes. Six ProxyAdmin
records reuse verified source through `SimilarMatch` pointers; these do not
represent missing verifications. Additional explicit submissions returned
`Already Verified`, and Sourcify independently reports six runtime matches.
Read-only checks on October 21 at Arbitrum One block 516939262 confirm all five
default-admin transfers accepted by `0xAcc08cBbeD784Ba9b5B07ADb5F0E299Cb0fD3d95`,
with no pending successor and all five lifecycle contracts still paused.
Operational-role migration, final governance and live CoFHE checks remain open.

On October 22, read-only checks at block 517195823 confirm CoFHE is enabled,
its access list is enabled, and all four deployed FHE caller proxies are listed.
The [competition setup plan](../engineering/mainnet-competition-activation-2026-10-22.md)
records eleven unsigned setup calls plus three old-bootstrap role removals;
all independently simulate successfully. The competition manager and
qualification registry remain paused. Admission is now confirmed; live
encrypted-operation checks, operational setup and final governance remain open.

Later on October 22, the user broadcast the
[competition setup](../../deployments/v2/arbitrum-mainnet-competition-2026-10-22-confirmed.json):
all seventeen receipts/calldata match and succeed. RPC at block 517207489
confirms role/operator migration, old-role removal, the exact active competition,
and both manager/registry unpaused. This supersedes the paused preparation above;
it adds no production source or dependency change. Mainnet encrypted-flow
integration checks and final governance handover remain outstanding.

## Historical Fhenix review and migration context

October 8–9 preparation changes the working dependency to CoFHE v1.0.0,
without broadcasting or changing the consumer ABI. Preserve the review SHAs
above as historical evidence; do not claim those reviews cover this new
dependency delta. See the
[rehearsal log](../engineering/deployment-rehearsal-2026-10-08.md) for local
validation and outstanding live-network/release checks.

The subsequent user-broadcast Arbitrum Sepolia deployment and local encrypted
submission/operator-evaluation checkpoint are recorded in the
[9 October deployment log](../engineering/deployment-arbitrum-sepolia-2026-10-09.md).
These do not extend the historical review scope or establish mainnet readiness.

The reviewer entry point is
[`FHENIX_REVIEW.md`](../../FHENIX_REVIEW.md). It contains the product map, exact
FHE operation inventory, per-call bounds, permission/decryption flow,
dependencies, known limitations and reproduction commands.

## Proposed repository scope

Fhenix may inspect the full sanitized contracts repository for unexpected
behavior. The FHE-specific performance scope is narrower:

- `AlphaEngineCompetitionStrategyManager`;
- `AlphaEngineCapitalStrategyManager`;
- `AlphaEngineConfidentialSwapController`;
- `AlphaEngineConfidentialSwapEscrow`;
- `AlphaEngineConfidentialAssetGateway`;
- `AlphaEngineFHERC20ERC20Wrapper`;
- the pinned `cofhe-contracts` and `fhenix-confidential-contracts`
  implementations reached by those contracts.

Qualification, USDC accounting, Merkle policy, decoder/sanitizer and FundVault
execution contracts remain useful to the behavior/basic-security review, but
they execute no FHE operations.

## Review questions

1. Are input verification, ACL grants, decrypt requests and inherited FHERC20
   operations compatible with the intended Fhenix mainnet package/network?
2. Are the encrypted operation types and explicit per-call bounds acceptable
   for expected production frequency?
3. Does the constant-time claim-ID adapter preserve the official v0.4 wrapper
   and shared-handle decryption/claim lifecycle?
4. Are permission grants and operator-rotation incident assumptions correct?
5. Does Fhenix require any additional allowlist identity, network address,
   compiler/EVM setting, integration test or monitoring control?

## Known limitations to disclose

- Foundry uses a repository-owned Task Manager compatibility harness. A real
  production-network permission/decryption test remains a release gate.
- Previous ciphertext access cannot be revoked when an FHE operator rotates.
- Competition public score decryption remains asynchronous: 24 handles per
  request, five seconds globally between requests and once-per-rank authorization.
  Initial swap and ordinary withdrawal budgets are provisional. Local tests do
  not establish network throughput; inherited holder disclosure remains outside
  these protocol admission budgets. See the
  [remediation contract](../engineering/fhenix-decrypt-pressure-remediation.md).
- Stage 17 pinned Pendle market enter/hold/exit fork integration is pending.
- The October 16 internal source pass is complete within its recorded scope.
  Its retained leads, remaining final-release/live-integration gates and
  independent external audit are not closed by that result.
- Deferred swap-hardening hypotheses remain tracked in the canonical plan and
  cannot be omitted from the later release review.

## Handoff checklist

- [x] Separate strategy, swap, custody and vault execution responsibilities.
- [x] Document every AlphaEngine-owned FHE entry point and bound.
- [x] Include inherited FHERC20 encrypted balance operations in review scope.
- [x] Record exact dependency commits in the reviewer guide.
- [x] Link contract-family guides, diagrams, tests and invariants.
- [x] State the local-mock/production-network gap.
- [x] Run tracked secret-path, private-key, `.env` and broadcast-artifact hygiene checks.
- [ ] Record the immutable review commit SHA and grant reviewer access.
- [ ] Confirm target Fhenix network/package/address matrix.
- [ ] Run the requested production Fhenix integration check.
- [x] Record findings against `0595ef4`; the first remediation targets dependency
  compatibility only, as detailed in `docs/engineering/cofhe-v020-migration.md`.

## Reproduce

PR CI runs `forge fmt --check` on changed Solidity files, leaving unrelated
baseline formatting out of the review. The release workflow retains its full check.

```bash
git submodule update --init --recursive
forge build --offline
forge test --offline
python3 script/reference/alphaengine_listener_surface.py --check
git diff --check
git submodule status --recursive
```

## Immutable-review protocol

- Review one exact commit SHA; do not force-push or rewrite it.
- Give each finding and remediation a traceable commit.
- Request explicit delta review for any post-review source change.
- Verify deployed bytecode against the final reviewed build before making any
  review or readiness claim.
