# AlphaEngine v2 listener cutover

## Purpose

AlphaEngine v2 replaces the mixed legacy intent controller and confidential vault with independent competition, capital, confidential-swap, and asset components. Consumers must treat each deployed address and ABI family as a separate event domain.

The canonical function selectors, typed-error selectors, and event topics are checked in at `ABI/v2/listener-surface.json`. The source ABIs remain authoritative and CI regenerates the listener surface from them.

## CoFHE 0.2 API revision

Manifests identify `contractApiRevision: v2-cofhe-0.2`. Regenerate clients from
the corresponding ABIs: strategy inputs are external handles with one ordered
batch proof; swap inputs include a batch-of-one proof. Proof generation must
specify the consuming manager/controller. FHERC20 callers must use the 0.4
shared-handle protocol and compatible CoFHE 0.7 client encoding.

`UnshieldRequested` and `SwapIntentUnshieldRequested` now include
`unshieldClaimId` in addition to the ciphertext handle. Decrypt the handle,
then call `claimUnshielded` with the ID. Indexers reconcile against the stored
escrow lock and the wrapper's canonical `getClaim(id)`. The controller's existing
swap payload still binds the returned handles; its identifier/hash domain is unchanged.
Fresh wrappers are mandatory. Preserve existing deployment evidence and drain
all old-wrapper claims/locks before cutover. See [migration notes](../engineering/cofhe-v020-migration.md).

## Decrypt-pressure revision

Regenerate consumers from the updated ABI set before cutover. Each new wrapper
pins an explicit registry constructor argument; external registration rejects a
mismatched binding. After creation/registration, the owner must call
`setWrapperMinimums` with separate positive swap and partial-exit thresholds in
confidential units. Unconfigured assets reject those new requests. Production
registry ownership must sit behind a timelock; configure and record per-asset
policies and the ordinary withdrawal budget before activation.

Index `WrapperMinimumsUpdated`, `UnshieldRateLimitsUpdated`,
`UnshieldAdmissionConsumed`, `UnshieldCooldownStarted`, `SwapCooldownStarted`
and `FullBalanceUnshieldRequested`. Reconcile source/trader identity and cooldown
getters; a third-party claimant or recipient is not necessarily the source.
`unshieldAll(recipient)` is a direct caller-owned wrapper action; its event gives
the unique claim ID. A cleared zero claim does not permit immediate retry.
Clients should surface typed limit errors and their next-available timestamps.

For score authorization, read `scoreRevealedThrough(id)` and `nextScoreRevealAt`,
then request ranks from cursor + 1 in batches of 1–8. The five-second interval
spans competitions. Publication retries use the already authorized handles;
never replay or rewind rank authorization. Qualification need not wait for
public score readiness. See the
[remediation contract](../engineering/fhenix-decrypt-pressure-remediation.md).

## Required listener behavior

1. Allowlist the exact chain, manifest schema, contract address, and ABI family before decoding a log. Unknown addresses or schema versions fail closed.
2. Start each v2 listener at the deployment block recorded in the v2 manifest. Record the final indexed block for the legacy contracts separately.
3. During cutover, dual-read legacy and v2 logs only for the documented bounded overlap. Deduplicate exclusively by `(chainId, contractAddress, transactionHash, logIndex)`.
4. Persist logs only after the configured confirmation depth and roll back orphaned logs on reorganization.
5. Reconcile every state-changing event against the corresponding contract getter. An event is evidence of a transition, not a substitute for current state.
6. Never interpret trader qualification as capital approval. Every capital intent has its own evaluation, commitment, expiry, revocation, and consumption state.
7. Competition score revelation is asynchronous. `CompetitionScoreRevealRequested` indicates only a pending request; consume revealed plaintext components only after verified result publication and the getter readiness flags agree.
8. For swaps, retain both confidential settlement and `SwapSettlementDustReturned`. Total user output is the encryptable wrapper amount plus any directly returned underlying dust.
9. Indexer replay must be deterministic: the same manifest, block range, confirmation policy, and ABI snapshot must reproduce the same state.

## Cutover checklist

- Verify runtime code hashes, proxy implementation/admin slots, roles, reciprocal swap links, and paused state against the manifest.
- Execute the manifest-bound governance action bundle and verify its `adminActionsHash` before unpausing any domain.
- The final bundle action binds the trusted swap escrow in the asset registry; it must be executed by `assetRegistryOwner` after the default-admin controller configuration actions.
- Drain and pause any old swap controller before moving submissions to the fresh controller and wrappers. An in-place upgrade with live intents would leave the new active-by-trader mapping unpopulated and is unsupported.
- Unpause qualification/competition, capital, escrow, and swap controller independently; capital execution stays disabled until an audited vault execution manager is configured.
- Stop new legacy submissions, but retain the legacy refund/rescue path until all recorded live locks are resolved.
- Preserve `deployments/arbitrum-sepolia-latest.json`, legacy ABIs, layouts, deployment addresses, and the final indexed block as historical evidence.

No Stage 9 or Stage 10 command broadcasts to a public network. Deployment-script tests and rehearsals run against Foundry's local ephemeral EVM only.
