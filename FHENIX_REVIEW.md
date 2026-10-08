# Fhenix Engineering Review Guide

This guide is the shortest path through AlphaEngine's contract repository for
Fhenix engineering. It supports the permissioned-mainnet admission review
discussed with the Fhenix team:

- confirm that encrypted operations are bounded and economically reasonable;
- understand where Fhenix is used and how often those paths may execute;
- perform a basic contract-security and unexpected-behavior check.

This is **not** a substitute for AlphaEngine's later full internal and
independent external security audits.

## Dependency migration following review of `0595ef4`

The dependency/API blocker was addressed in the first commit using released
CoFHE v0.2.0 and FHERC20 v0.4.0. The complete remediation adds per-wrapper
minimums, verified-zero cooldowns, independent swap/withdrawal admission budgets,
a full-balance dust exit and paced, once-per-rank score authorization. See the
[migration contract](docs/engineering/cofhe-v020-migration.md) and
[remediation contract](docs/engineering/fhenix-decrypt-pressure-remediation.md)
for consumer, configuration and fresh-deployment requirements. Live network
capacity and real CoFHE integration remain release gates.

The October 8–9 deployment preparation subsequently pins CoFHE v1.0.0
(`0f5ded4f2847ee227f9be0b07a392238f75b656c`) with the consumer API unchanged.
Its address-book adaptation and no-broadcast validation are recorded in the
[rehearsal log](docs/engineering/deployment-rehearsal-2026-10-08.md).
The dependency table below preserves the 0.2.0 remediation checkpoint; it is
not the new working-tree lock. Earlier review evidence does not automatically
cover this dependency delta or establish live-network readiness.

## Product in one diagram

```mermaid
flowchart TB
    subgraph FHE[Confidential boundary]
        Competition[Competition submissions + scores]
        Capital[Fresh capital intents]
        Swap[Optional confidential swap amounts]
    end

    Competition --> Qualification[Public trader qualification]
    Qualification --> Capital
    Capital --> Authorization[Exact, expiring execution authorization]

    subgraph Plain[Ordinary Solidity boundary]
        Authorization --> Policy[Merkle policy + decoder + risk checks]
        Policy --> Vault[USDC FundVault]
        Vault --> Protocols[Approved public protocol execution]
    end

    Swap --> PublicDEX[Public DEX settlement]
```

AlphaEngine protects strategy information while it is submitted and evaluated.
Qualification applies to the trader—not to a reusable strategy—and never moves
capital automatically. Final vault execution is public and auditable.

Confidential swap is an independent user-facing feature: users may swap an
FHERC20 amount confidentially even if they do not participate in the strategy
or FundVault lifecycle.

## Review routes

| Area | Guide | Primary source |
|---|---|---|
| Competition, qualification, capital | [Strategy README](src/strategy/README.md) | [`src/strategy/`](src/strategy/) |
| Confidential assets and swaps | [Swap README](src/swap/README.md) | [`src/swap/`](src/swap/), [`src/fherc20/`](src/fherc20/) |
| USDC vault and execution policy | [Vault README](src/vault/README.md) | [`src/vault/`](src/vault/), [`src/decoders/`](src/decoders/) |
| Security properties | [Invariant ledger](docs/engineering/invariant-ledger.md) | [`test/invariant/`](test/invariant/) |
| Current limitations and gates | [Audit readiness](docs/audits/fhenix-private-audit-readiness.md) | [Implementation plan](docs/engineering/strategy-manager-fund-vault-implementation-plan.md) |

## FHE operation inventory

### AlphaEngine-owned calls

| Action | Encrypted type | Bounded work in the AlphaEngine contract |
|---|---|---|
| Competition submission with `n` components | `1 + n` × `externalEuint128`, `1 <= n <= 16` | One batch verification over `1 + n` inputs; contract and operator ACL grants for each handle; no encrypted arithmetic |
| Competition evaluation | 3 × `externalEuint32` | One batch verification over 3 inputs; contract and trader ACL grants; no encrypted arithmetic |
| Public score reveal after finalization | 3 × `euint32` per submission | 3 public ACL grants per submission; at most 8 submissions, therefore 24 handles made publicly decryptable per call; forward cursor and global five-second interval |
| Capital-intent submission | `1 + n` × `externalEuint128`, `1 <= n <= 16` | Same input verification and ACL pattern as competition; no encrypted arithmetic |
| Capital evaluation | 3 × `externalEuint32` | Same verification and ACL pattern as competition evaluation; no public-decrypt path |
| Confidential-swap submission | 1 × `externalEuint64` | 1 batch-of-one verification; `gte`/`select` minimum masking and trivial constants; contract and recorded escrow ACL grants on the effective input |
| Vault deposit, accounting, Merkle proof, risk check, execution | None | No FHE operations |

`FHE.asEuint128s(inputs, proof)`, `FHE.asEuint32s(inputs, proof)`, and
`FHE.asEuint64(input, proof)` are input-verification calls in the pinned CoFHE
package. They bind the ordered inputs to the sender, chain and consuming contract, validate type, security zone and verifier signature, append
metadata, and create transient ACL authority. They do **not** call
`createTask` or perform homomorphic arithmetic. This input proof is the pinned
package's signed-input verification flow; it should not be described as an
AlphaEngine ZK-proof circuit.

The strategy managers contain no FHE add, subtract, multiply, divide, compare,
or select operations. In particular, loading a 128-bit encrypted strategy
field is not a 128-bit encrypted division.

### Inherited FHERC20 work

The swap path uses the official
`fhenix-confidential-contracts@v0.4.0` FHERC20 implementation. A lock, shield,
unshield, settlement, or refund can therefore execute the dependency's bounded
`euint64` balance logic:

- encrypted comparisons (`gte`/`eq`), `select`, addition, and subtraction;
- trivial encryption of constants or shielded plaintext amounts;
- ACL grants and public authorization of the unshield result;
- verification of the published decryption result before underlying transfer.

These operation sequences are branch-dependent—for example, a first mint into
an uninitialized balance differs from a transfer between existing balances.
There is no encrypted division in the reviewed swap path. Wrapper conversion
using `amount / rate` and `amount % rate` is ordinary plaintext Solidity before
or after FHERC20 accounting.

Fhenix should review both AlphaEngine's wrapper extension and the pinned
upstream FHERC20 implementation because the dependency owns the encrypted
balance arithmetic.

## Load and frequency bounds

| Boundary | On-chain bound |
|---|---|
| Encrypted components per strategy submission | 16 |
| Active submissions per competition | 256 |
| Public score-reveal batch | 8 submissions / 24 handles; five seconds globally between batches; once per rank |
| New swap intents | Initially 120 per trailing minute, two tokens refilled per second, 24-request burst, one active per trader |
| Ordinary unshield | Explicit per-wrapper partial minimum; one pending/source/wrapper; five-minute cooldown after verified zero; shared budget initially 1/s, burst 8 |
| Full-balance unshield | Caller-only dust exception; same pending/budget gates; five-minute cooldown from admission |
| Zero swap refund | Verified zero starts five-minute recorded-trader cooldown |
| Capital execution authorization | Maximum 1 hour |
| FundVault calls per batch | 16 |
| Asset limits per vault execution | 16 |
| Nonzero policy-root activation delay | Minimum 48 hours |

Competition and capital submission frequency remains product-dependent. The
swap budget is global to this controller and configurable by delayed governance
only while paused. Its initial values are provisional; production CoFHE task
capacity and completion latency remain to be measured. Encrypted comparison and
selection enforce minimum spend policy without revealing an eligibility bit;
they cannot reject zero/insufficient-balance requests before the first decrypt.
Ordinary encrypted partial unshield adds the same `gte`/`select` masking.
All three scores remain: a full competition authorizes 768 handles once across
32 batches, taking at least 155 seconds from first to last batch.

These budgets cover AlphaEngine claim creation and manager score authorization.
Inherited shielding, confidential transfers, `requestDiscloseEncryptedAmount`
and holder calls to Task Manager `allowGlobal` remain part of the wider FHE load
inventory. They are not bounded by these admission controls. Repeated public ACL
grants alone do not establish repeated network computation for a cached result.

## Permissions and decryption

```mermaid
sequenceDiagram
    participant User
    participant Manager as Strategy Manager
    participant TM as Fhenix Task Manager
    participant Operator as FHE Operator
    participant Evaluator

    User->>Manager: submit signed encrypted inputs
    Manager->>TM: batchVerifyInputs for market + components
    Manager->>TM: allowThis + allow(operator)
    Operator-->>Operator: decrypt authorized strategy data
    Evaluator->>Manager: submit 3 encrypted scores
    Manager->>TM: batchVerifyInputs + allowThis + allow(trader)
    Note over Manager,TM: Competition only: after finalization,
    Note over Manager,TM: revealer grants public access to bounded score handles
```

- Operator access is captured at submission; rotating the configured operator
  affects future submissions only.
- Previously granted ciphertext access cannot be cryptographically revoked.
  A compromised operator requires pause, invalidation/cancellation where
  available, rotation, and fresh encrypted submission.
- Competition scores remain encrypted during the competition. After
  finalization, a dedicated role requests asynchronous public decryption of all
  three components. The getter exposes independent readiness flags.
- Capital scores remain available only to the contract and submitting trader.
- The swap operator receives the decrypted input needed for public DEX
  execution; confidential swap protects the user-facing amount before this
  execution boundary, not public settlement effects.

## Custody and execution boundaries

- Strategy managers hold no ERC20 or FHERC20 custody and cannot call arbitrary
  targets.
- Swap escrow holds FHERC20 only for a live intent. The V4 executor is callable
  only by the authorized escrow and must end with no residual underlying.
- `AlphaEngineFundVault` holds pooled USDC and position assets. It contains no
  FHE code.
- Vault calls require an exact Capital Manager commitment plus an active
  per-executor policy root, per-call Merkle proofs, fail-closed decoders, live
  target/decoder code hashes, replay checks, expiry, and spend/receipt limits.
- An executor is a keeper/automation identity that relays an approved bundle;
  it is not automatically the trader and cannot choose uncommitted calls.

## Basic security checkpoints

Reviewers may validate that:

- implementations disable initializers and fresh proxies initialize paused;
- competition, capital, and swap domains have independent roles, storage,
  nonces, pauses, events, and ABIs;
- encrypted handles are internalized and permissioned before storage/use;
- ranks are unique, finalization requires all active submissions to be
  evaluated, and only eligible traders can be qualified;
- capital commitments and swap routes cannot be modified at execution;
- replay markers are written before external vault execution and roll back
  atomically on failure;
- FundVault control-plane addresses cannot be batch targets;
- proofs, decoder results, code hashes, approvals, deltas, and rolling limits
  are checked before execution is accepted;
- refund and emergency paths remain available under their documented pause and
  expiry conditions.

## Dependencies

The migration pins these exact submodule SHAs:

| Dependency | Commit | Version/reference |
|---|---|---|
| `cofhe-contracts` | `be9ad566b09183230b64aa02d272aad4c07e9f83` | `v0.2.0` |
| `fhenix-confidential-contracts` | `5138cb8644b19b24a75caf3f383a17457e823e16` | `v0.4.0` |
| OpenZeppelin Contracts | `acd4ff74de833399287ed6b31b4debf6b2b35527` | `v5.2.0` |
| OpenZeppelin Upgradeable | `723f8cab09cdae1aca9ec9cc1cfa040c2d4b06c1` | `v5.0.2` |
| Uniswap v4 core | `e50237c43811bd9b526eff40f26772152a42daba` | `v4.0.0` |

## Known review limitations

- Foundry tests use a repository-owned Task Manager compatibility harness.
  Production Fhenix-network permission/decryption behavior remains a release
  gate.
- Encrypted unshield and single-use `sharedEuint64` transfers use the official
  wrapper. AlphaEngine's `_unshield` override retains the official claim ID in
  a constant-time per-recipient view because upstream returns only the burned
  share. This adapter is covered by the migration tests and disclosure.
- Wrapper bytecode links the official `ERC20ConfidentialLib`; the deployment
  manifest records its address and runtime code hash.
- Stage 17 real-market Pendle enter/hold/exit fork integration is pending.
- Consolidated X-Ray, Solidity Auditor, final fuzzing/remediation, and external
  audit have not yet been completed.
- Deferred confidential-swap hardening hypotheses are tracked in the
  [canonical plan](docs/engineering/strategy-manager-fund-vault-implementation-plan.md#deferred-confidential-swap-hardening-todos)
  and must be resolved or explicitly constrained before release.

## Reproduce the current state

PR CI runs `forge fmt --check` on changed Solidity files, leaving unrelated
baseline formatting out of the review. The release workflow retains its full check.

```bash
git submodule update --init --recursive
forge --version
forge build --offline
forge test --offline
python3 script/reference/alphaengine_listener_surface.py --check
git diff --check
git submodule status --recursive
```

At handoff, record the exact Git SHA reviewed. Findings and remediation should
reference that immutable SHA; any subsequent code change requires explicit
delta review.

For broader product context, see
[AlphaEngine overview](https://docs.alphaengine.trade/overview/alphaengine.md),
[private strategy evaluation](https://docs.alphaengine.trade/architecture/private-strategy-evaluation-flow.md),
and [public settlement](https://docs.alphaengine.trade/trust/public-settlement.md).
