# Fhenix Internal Review Readiness

- Status: Stage 16 implementation complete; admission-review documentation prepared
- Review type: Fhenix FHE-efficiency, behavior and basic-security review
- Designated reviewer: `@liorbond`
- Review commit: `0595ef4`; dependency migration is a separate remediation commit
- Production claim: none; this is not a full external security audit

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
- Consolidated X-Ray, Solidity Auditor, remediation, final fuzzing and
  independent external audit are not complete.
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
