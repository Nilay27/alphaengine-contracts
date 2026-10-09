# CoFHE 0.2 / FHERC20 0.4 migration

Historical migration checkpoint: the current CoFHE dependency has since been
bumped to 1.0.0 with the consumer API unchanged. See the
[October 8 deployment rehearsal](deployment-rehearsal-2026-10-08.md) for the
address-book resolution, exact pin and manifest updates. Pins below describe
the original 0.2 migration.

Breaking input/claim API revision for the undeployed v2 family, following Fhenix's
review of `0595ef4`. [Decrypt-pressure controls](fhenix-decrypt-pressure-remediation.md)
apply on top of this migration.

## Dependencies and inputs

- Pins: CoFHE `be9ad566b09183230b64aa02d272aad4c07e9f83` (0.2.0), FHERC20
  `5138cb8644b19b24a75caf3f383a17457e823e16` (0.4.0), regular OpenZeppelin
  `acd4ff74de833399287ed6b31b4debf6b2b35527` (5.2.0, required for transient
  reentrancy protection). Upgradeable OpenZeppelin remains 5.0.2.
- Preserve one uint128 market, 1–16 uint128 components and three uint32 scores.
  Verify ordered `[market, ...components]` and three-score batches with one proof
  each; swaps verify one external uint64. Proofs bind sender, chain, consumer,
  types and order. Consumers need CoFHE 0.7 input encoding and regenerated ABIs;
  old `InEuint*` tuples are unsupported. Strategy hash domains are unchanged.

## Public results and token boundaries

- Score reveal uses `FHE.allowPublic`; getters read verified published results
  with per-score readiness. Current pacing/cursors are in the remediation notes.
- Transfers/shielding/unshielding use `sharedEuint64`; consume returned shares
  immediately and persist ACL access to any handles stored across transactions.
- Claim IDs differ from ciphertext handles. Gateway/escrow events expose both;
  decrypt the handle, then use the ID for `getClaim`/`claimUnshielded`. Escrow
  verifies the claim ID, recipient and ciphertext, including third-party preclaims.
- The wrapper retains `_createClaim`'s result for constant-time lookup immediately
  after unshielding. AlphaEngine maintainers own this adapter: review it on every
  FHERC20 upgrade and remove the lookup adaptation when upstream returns claim IDs.
  No calendar removal date is assumed; AlphaEngine admission controls remain.

## Cutover and validation

Use fresh wrappers/manifests; drain old claims and locks. Do not reinterpret
v0.3.1 wrapper claims as v0.4.0 claims. Existing proxy fields are preserved and
new state is appended. Coordinate SDK/listener migration using the checked-in
ABIs, event topics and [cutover checklist](../migrations/v2-listener-cutover.md).

Link `ERC20ConfidentialLib` before running `DeployAlphaEngineV2`; the manifest
records its address/code hash, package versions and `contractApiRevision:
v2-cofhe-0.2`. Local deployment tests check linkage and code presence. Before a
network deployment, verify the linked bytecode and recorded hash on that network.
Legacy deployment artifacts remain historical evidence.

The migration-only checkpoint passed 315 tests and 92.98% line coverage;
current combined results and mock/network limitations are in the
[remediation notes](fhenix-decrypt-pressure-remediation.md#validation).
