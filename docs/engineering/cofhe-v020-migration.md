# CoFHE v0.2.0 / FHERC20 v0.4.0 migration

Scope: first remediation commit for Fhenix's review of `0595ef4`. The owner
authorized the dependency/API migration before the separate decrypt-pressure
and rate-limiter changes. No external deployment is authorized by this change.

## Pins and input contract

- `cofhe-contracts`: v0.2.0, `be9ad566b09183230b64aa02d272aad4c07e9f83`.
- `fhenix-confidential-contracts`: v0.4.0,
  `5138cb8644b19b24a75caf3f383a17457e823e16` (pins CoFHE 0.2.0).
- `openzeppelin-contracts`: v5.2.0,
  `acd4ff74de833399287ed6b31b4debf6b2b35527`, the minimum regular OpenZeppelin
  version declared by FHERC20 0.4.0, providing its transient reentrancy guard.
  AlphaEngine's upgradeable OpenZeppelin dependency remains pinned at v5.0.2.
- Preserve one encrypted uint128 market, 1–16 encrypted uint128 components,
  and three encrypted uint32 evaluation scores. Only their input/proof encoding
  changes; persisted canonical handles and strategy hash domains are unchanged.
- Submissions verify the ordered `[market, ...components]` batch with one
  proof. Evaluations verify `[realSister, perturbationP25, stressP25]` with one
  proof. Swap submissions verify one external uint64 with its batch-of-one
  proof. Proofs bind sender, chain, consuming contract, input types and order.
- Contract consumers must regenerate their ABIs and use the CoFHE 0.7 input
  format: external handles followed by a batch proof, with the consuming
  contract specified during encryption. Old `InEuint*` tuples are unsupported.

## Public results and confidential custody

- Score reveal calls `FHE.allowPublic` on the same three finalized score
  handles. The existing readiness-aware getter reads published, verified
  results. This change retains the existing 32-submission batch and repeatable
  rank pagination; pacing and replay controls are a later remediation commit.
- FHERC20 transfers, shielding and unshielding use the official `sharedEuint64`
  argument/return protocol. Callers consume returned shares immediately and
  retain persistent access to handles stored across transactions.
- Wrapper claim IDs are distinct from burned ciphertext handles. The wrapper
  adapter exposes the latest created claim ID per recipient in constant time,
  using the official `_createClaim` return value. Gateway and escrow read it
  immediately after unshielding. The escrow appends the claim ID to its lock
  record and verifies ID, recipient and ciphertext before claiming/reconciling.
- Decrypt proofs continue to bind the ciphertext handle; wrapper `getClaim`
  and `claimUnshielded` take the unique claim ID. Consumers must not use one
  identifier in place of the other. Gateway/escrow request events expose both.
- The official `ERC20ConfidentialLib` must be linked into wrapper creation.
  Deployment evidence must identify the linked library and its runtime code.

### Claim lookup adapter ownership

Owner: AlphaEngine contracts maintainers. The adapter duplicates only the
upstream `_unshield` hook to capture `_createClaim`'s return value, preserving
its validation, burn, public permission and event behavior. Remove this hook
and the per-recipient lookup in the dependency-upgrade phase where upstream
unshield exposes its created claim ID directly. Review upstream hook changes
on every FHERC20 upgrade; no calendar removal date is assumed.

## Compatibility and deployment

This is a breaking contract-input and wrapper-claim API migration, documented
as the CoFHE 0.2 revision of the undeployed v2 contract family. Regenerated v2
ABIs and selector/topic snapshots are authoritative. Legacy artifacts remain
historical evidence. Backend/SDK consumers require coordinated updates before
cutover; this commit is confined to the contracts repository.

Use fresh wrappers and fresh deployment manifests. Existing v0.3.1 wrappers
and their pending claims cannot be reinterpreted as v0.4.0 claims. An escrow
with outstanding old-wrapper locks must finish them before any cutover.
Existing proxy fields and hash domains are preserved; new storage is appended.

The Foundry v1.7.1 deployment flow must resolve `ERC20ConfidentialLib` links
before running `DeployAlphaEngineV2`. Its configuration validation checks that
the resolved address has code; the new manifest records that address, code
hash, both Fhenix package versions and `contractApiRevision: v2-cofhe-0.2`.
Local deployment tests exercise Foundry's automatic library deployment/linking.
Before any network deployment, inspect the linked library deployment and
wrapper bytecode in the simulation output, then verify the recorded code hash
on the target network. No network broadcast was performed for this commit.

The migration does not add minimum amounts, pending-request restrictions,
rolling intent caps, score-reveal cursors, or changes to scoring/qualification.
Those review findings remain open. Local mocks test integration semantics,
not the production encryption service or threshold network.
