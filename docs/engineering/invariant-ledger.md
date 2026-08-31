# Invariant Ledger

## Purpose

This document is the living invariant ledger for `alphaengine-contracts`.

It must be updated whenever a contract state machine, custody boundary, intent family, or accounting model changes. Unit tests can prove individual examples. Fuzz tests can prove bounded input properties. Invariant tests must prove that core state relationships remain true across random stateful action sequences.

The historical implementation had two stateful domains:
- `AlphaEngineIntentController`: strategy and swap-intent lifecycle.
- `AlphaEngineConfidentialVault`: FHERC20 wrapper registry, deposit/shield, unshield delegation, and swap-intent escrow locks.

Those legacy handlers and tests were retired from the active tree at Stage 9
after the replacement strategy and swap paths became complete. Their manifest,
ABI, layouts, historical source, and earlier validation evidence remain in Git.
Exact-input swap settlement through the fresh controller/escrow/executor path
is implemented. Its active invariant harnesses include execute-time actions
through a two-wrapper mock-settlement model, while deterministic unit and
PoolManager integration tests prove the higher-decimal output rule: `total
output == shielded units * wrapper rate + dust returned to the trader`.

The replacement architecture now also has three stateful domains:

- `AlphaEngineTraderQualificationRegistry`;
- `AlphaEngineCompetitionStrategyManager`; and
- `AlphaEngineCapitalStrategyManager`.

Their handler invariants supplement fixed hash vectors and exhaustive
field-mutation tests. They do not share state-bearing inheritance or nonce,
pause, lifecycle, ABI, or event domains.

Stage 7 adds a separate confidential-asset and swap-custody boundary:

- `AlphaEngineConfidentialAssetRegistry` owns only append-only wrapper
  associations;
- `AlphaEngineConfidentialAssetGateway` has no mutable business configuration
  and must retain no underlying token; and
- `AlphaEngineConfidentialSwapEscrow` owns only temporary live locks,
  unshield-request handles, settlement, and refunds.

`test/invariant/AlphaEngineConfidentialSwapEscrow.invariant.t.sol` randomizes
deposits, valid locks, above-balance encrypted-zero locks, permissionless
preclaims, deliberately under-minimum settlements, successful settlements, and
refunds. At the PR profile it proves:

- registry mappings plus gateway/escrow dependency pointers remain stable;
- `liveSwapLockCount` equals the number of tracked `UnshieldRequested` locks;
- stored locked and unshield handles retain their exact mock values;
- gateway and executor retain zero underlying, while escrow input underlying
  equals only the amount attributable to live permissionlessly preclaimed
  locks; wrapper approvals return to zero;
- for each user, input confidential balance plus live input units plus consumed
  input units equals all successfully deposited input units;
- output confidential balances independently equal measured settlement credits
  under a deliberately non-1:1 quote;
- wrapper underlying reserves equal confidential supply plus unclaimed pending
  units for input wrappers and confidential supply for output wrappers;
- initialized encrypted-zero locks retain a terminal verified refund path;
- terminal locks have claimed their input, preclaimed live locks remain
  reconcilable, and failed settlements roll back claim and lifecycle state
  atomically; and
- deterministic seeding plus action counters prevent vacuous campaigns.

Stage 8 adds the fresh `AlphaEngineConfidentialSwapController` as a fourth
replacement state domain. Its combined controller/escrow handler proves:

- each trader nonce equals successful fresh swap submissions exactly;
- every record retains its domain-separated identifier, payload hash, escrow,
  executor, wrappers, route key, execution-data hash, salted minimum-output
  commitment, canonical handles, and deadline;
- `Active/UnshieldRequested`, `Executed/Consumed`, and `Refunded/Refunded`
  remain exact controller/escrow state pairs;
- the escrow live-lock counter equals fresh active controller records;
- calldata, minimum-output, and replay attacks fail with exact selectors and no
  coupled-state change; and
- controller and executor underlying balances remain zero after every
  successful action.
- for outputs whose underlying decimals exceed confidential precision, the
  representable six-decimal amount is shielded, the exact remainder is returned
  directly to the original trader, and the escrow retains zero output;
- minimum output is enforced against total measured PoolManager output before
  the encrypted-output/dust split.

The Competition Manager handler also exercises randomized, repeated score
reveal batches. It asserts that a score reveal can only be observed after the
competition is finalized, that all three component handles for a submission
receive the same number of decrypt requests, and that the manager is the CoFHE
requestor. Plaintext results remain asynchronous and are not duplicated in
manager storage.

The approved second-pass fund design has three stateful domains that must not be
collapsed: `AlphaEngineFundVault` for custody and shares,
`AlphaEngineUSDCVaultManager` for USDC deposit/withdrawal and NAV accounting,
and `AlphaEngineVaultExecutionManager` for Merkle-verified fund deployment.

## USDC FundVault accounting invariants

- Only the USDC manager can invoke FundVault entry/exit settlement; only the
  execution manager can invoke `manage`.
- Total share supply equals user balances plus shares escrowed by pending
  withdrawals.
- Manager-accounted assets equal cumulative deposits plus reported profit minus
  completed redemptions and reported loss.
- Physical USDC across vault and modeled strategy equals cumulative deposits
  plus donations minus completed redemption payouts.
- Positive P&L cannot become fully redeemable before the configured vest ends;
  remaining locked profit rounds up until the exact unlock timestamp. Confirmed
  loss immediately consumes unvested gain before recognized NAV.
- Immediate deposits and completion-time redemptions do not dilute the
  recognized price of remaining shares beyond deterministic floor-rounding
  residue.
- Deposits receive no already-recognized historical profit. They can participate
  only in the remaining locked gain, the accepted vesting tradeoff.
- Performance-fee shares equal the independently calculated share entitlement,
  redeem for no more than the snapshotted fee assets, and do not change preview
  pricing when virtual matured supply becomes actual supply. Fee rates stay
  within the cap and recovered losses are not charged twice.
- A loss reduces fee entitlement only for cancelled unvested feeable profit. If
  it consumes the final locked unit, the surviving fee on already vested profit
  is crystallized atomically rather than waived.
- An independent shadow model reproduces managed assets, locked and recovery
  profit, pending fee assets/rate, loss recovery, vesting timestamps, actual and
  effective supply, available assets, and deposit/redemption previews after
  every randomized action.
- Deposits leave the pre-existing aggregate `lossToRecover` unchanged;
  completed redemptions scale it to the remaining supply with upward rounding,
  and a full exit clears it.
- Illiquid redemption completion reverts atomically; a zero-value redemption
  with zero minimum retains a terminal share-burn path.
- Neither manager retains assets outside an atomic operation.
- No unproved, stale, mismatched, expired, or replayed capital bundle reaches a
  FundVault external call.
- A failed external execution restores every replay flag atomically, and a
  pending redemption completes only after enough USDC returns to the vault.

## V2 replay-critical hash invariants

- Competition, competition-submission, capital-intent, and swap-intent IDs use
  distinct typehashes and bind chain plus the owning contract address.
- Competition, capital, and swap nonce domains remain independent in their
  eventual owning contracts.
- Encrypted component arrays are order-sensitive through
  `keccak256(abi.encode(componentHandles))`.
- Competition and capital payload hashes bind every stable submission field and
  exclude operator snapshots, creation timestamps, transaction hashes, and log
  indices.
- Call bundles are nonempty, capped at 16, order-sensitive, and bind index,
  decoder, target, zero native value, and the exact calldata hash.
- Risk assets are nonzero, strictly ascending, unique, capped at 16, and bind
  max-spend/min-receive values at their exact indices.
- Execution commitments bind every authority, version, time window, replay
  nonce, policy root, call/risk hash, submission payload, and evaluation
  evidence field.
- Changing any bound field changes the resulting commitment.
- The dependency-free reference generator and Solidity implementation must
  reproduce `test/vectors/alphaengine-hash-v1.json` exactly.

## Implemented Capital Manager invariants

`test/invariant/AlphaEngineCapitalStrategyManager.invariant.t.sol` exercises
submit, cancel, reject, approve, consume, deliberately reverting downstream
consume, expiry, qualification revocation/requalification, and invalid stale
qualification progress. At the PR profile, each property runs 64 sequences at
depth 32 with zero handler reverts.

- The trader nonce equals exactly the number of successful capital submissions.
- Stored identity, payload hash, component count, and component array remain
  internally consistent for every tracked intent.
- Cancelled, rejected, consumed, revoked, and expired states are terminal.
- Approved commitments never change, and authorization nonces identify at most
  one intent.
- Consumed status, commitment replay state, and authorization-nonce replay state
  remain in parity. A downstream revert restores all three atomically.
- Revoked/expired qualification versions cannot approve or consume their old
  intents after requalification at a newer version.
- The Capital Manager retains no native asset and exposes no token or arbitrary
  target-call path.

## Notation

Use this notation in tests and future invariant docs:

- `C`: `AlphaEngineIntentController`.
- `V`: `AlphaEngineConfidentialVault`.
- `W`: a registered FHERC20 wrapper.
- `U`: an underlying ERC20 token.
- `A`, `B`: tracked users.
- `O`: owner.
- `L`: listener operator.
- `id`: intent id.
- `S[id]`: strategy intent record returned by `C.getIntent(id)`.
- `SH[id]`: strategy component handles returned by `C.getIntentComponentHandles(id)`.
- `X[id]`: swap intent record returned by `C.getSwapIntent(id)`.
- `VL[v][id]`: swap lock record returned by `V.getSwapIntentLock(id)` for vault `v`.
- `nonce(a)`: `C.submitterNonces(a)`.
- `rate(W)`: `IFHERC20ERC20Wrapper(W).rate()`.
- `units(W, amount)`: `amount / rate(W)`, only valid when `amount % rate(W) == 0`.
- `handleValue(h)`: `mockStorage(uint256(h))` for a raw `bytes32` handle.
- `evalue(e)`: `mockStorage(uint256(euint64.unwrap(e)))` for an `euint64`.
- `cbal(W, a)`: `evalue(IERC7984(W).confidentialBalanceOf(a))`.
- `ctotal(W)`: `evalue(IERC7984(W).confidentialTotalSupply())`.
- `underlyingBalance(U, a)`: `IERC20(U).balanceOf(a)`.

The mock harness intentionally stores the clear value behind a ciphertext handle. In invariant tests we assume the cryptography works and assert contract accounting over `handleValue(...)` and `evalue(...)`.

## Currently Implemented Invariants

These are implemented in:
- `test/invariant/AlphaEngineIntentController.invariant.t.sol`
- `test/invariant/AlphaEngineConfidentialVault.invariant.t.sol`

### Strategy Cancellation Monotonicity

Once a tracked strategy intent is cancelled, it must never become active again.

Expression:

```text
if observedCancelledStrategy[id] == true:
    uint8(S[id].status) == uint8(IntentStatus.Cancelled)
```

Current scope:
- strategy intents only
- submitter A
- submitter B
- owner cancellation
- submitter cancellation
- mixed controller handler with swap submissions, swap executions, listener rotation, and vault rotation

### Strategy Handle Count Parity

The stored strategy component-handle array length must always match the stored component count.

Expression:

```text
len(SH[id]) == S[id].componentCount
```

Current scope:
- strategy intents only
- random component count bounded to `[1, 16]`
- cross-checked against stored strategy snapshots while swap intents are also being submitted and executed

### Shared Nonce Tracking

The controller nonce for each tracked submitter must match the handler's count of successful submissions across all implemented intent families.

Expression:

```text
nonce(A) == successfulStrategySubmits(A) + successfulSwapSubmits(A)
nonce(B) == successfulStrategySubmits(B) + successfulSwapSubmits(B)
```

Current scope:
- strategy submissions
- swap submissions
- strategy cancellation and swap execution
- listener-operator rotation
- configured-vault rotation

### Listener Operator Non-Zero

The listener operator must remain non-zero after successful initialization.

Expression:

```text
C.listenerOperator() != address(0)
```

Current scope:
- listener-operator rotations between two non-zero operators are part of the controller invariant handler

### Mixed Controller / Vault Parity

Known swap intents must remain internally consistent with the vault lock recorded at submission time, including after vault rotation.

Implemented checks:
- swap record payload hash determinism
- non-zero swap submitter, vault, wrapper, route key, lock handle, and future deadline
- controller requested-input handle access for the controller and recorded vault
- vault lock account, wrapper, locked handle, and status parity with the controller swap record
- active swap records map to `UnshieldRequested` vault locks
- executed swap records map to `Consumed` vault locks
- refunded swap records map to `Refunded` vault locks
- vault rotation affects future swap submissions only because historical swap records keep their recorded vault

### Cross-Family Isolation

Known strategy and swap intent ids must remain unique and family-scoped across mixed submissions.

Implemented checks:
- each known id belongs to exactly one implemented family
- strategy component handles are not reused as known swap locked-amount handles
- known swap locked-amount handles are not reused as strategy component handles
- executing a swap leaves known strategy records and component handles unchanged in fuzz coverage
- cancelling a strategy leaves known swap records and vault locks unchanged in fuzz coverage

### Vault Lifecycle and Accounting

The vault invariant handler now covers two registered wrappers, two tracked users, and stateful deposit, lock, settle, dust-settle, unshield-request, and unshield-claim actions.

Implemented checks:
- wrapper registry stability and wrapper/underlying/rate parity for both input and output wrappers
- lock identity immutability and status monotonicity for tracked locks
- per-user unit conservation across input confidential balances, output confidential balances, pending input unshield units, and claimed input withdrawals
- confidential total supply equals tracked user balances plus vault balance for each wrapper independently
- each wrapper underlying reserve equals confidential supply plus pending unshield units for that wrapper
- consumed locks always imply their unshield request was claimed exactly once in the handler model
- consumed locks record exact output wrapper, output underlying amount, and output confidential units
- output confidential balances equal the handler's tracked settlement credits
- dust settlement attempts revert atomically without partially consuming the input lock or minting output
- vault and mock executor retain zero residual underlying after successful settlement
- vault owner and intent-controller authority remain stable in the vault-specific handler

## Controller Invariants

### Shared Nonce Exactness

`submitterNonces` is intentionally shared by all intent families. It must equal the total number of successful submissions by that submitter across every implemented family.

Expression:

```text
nonce(a) == successfulStrategySubmits(a) + successfulSwapSubmits(a)
```

Implemented coverage:
- submit strategy
- submit swap
- cancel strategy
- execute swap
- vault rotation before and after swap submission
- listener-operator rotation before and after strategy submission

### Intent Id Uniqueness Across Families

Intent ids use a single nonce stream. A strategy intent and a swap intent from the same submitter must not collide.

Expression:

```text
id(a, n) = keccak256(abi.encode(address(C), block.chainid, a, n))

for all tracked ids i != j:
    id_i != id_j
```

The expected next id for a submitter is always computed from the current shared nonce:

```text
nextId(a) == keccak256(abi.encode(address(C), block.chainid, a, nonce(a)))
```

### Strategy Payload Hash Determinism

A strategy record's payload hash must remain recomputable from stable record fields and stored component handles.

Expression:

```text
S[id].payloadHash == keccak256(
    abi.encode(
        S[id].marketIdHandle,
        S[id].timeframeKey,
        S[id].deadline,
        SH[id]
    )
)
```

The hash must exclude ephemeral fields:
- `createdAt`
- block timestamp except through explicit `deadline`
- listener/operator address
- transaction hash
- log index

### Swap Payload Hash Determinism

A swap record's payload hash must remain recomputable from stable record fields.

Expression:

```text
X[id].payloadHash == keccak256(
    abi.encode(
        X[id].confidentialVault,
        X[id].inputWrapper,
        X[id].routeKey,
        X[id].deadline,
        X[id].lockedAmountHandle,
        X[id].unshieldRequestHandle
    )
)
```

The hash must exclude ephemeral fields:
- `createdAt`
- block timestamp except through explicit `deadline`
- transaction hash
- log index
- current configured vault after the intent was submitted

### Deadline Creation Consistency

Successful submit calls must produce records whose deadline is strictly after creation time.

Expressions:

```text
S[id].deadline > S[id].createdAt
X[id].deadline > X[id].createdAt
```

### Strategy Component Bounds

Strategy component counts must remain in the protocol-supported range.

Expression:

```text
1 <= S[id].componentCount <= C.MAX_COMPONENT_COUNT()
len(SH[id]) == S[id].componentCount
```

Unknown strategy intents may return zero/default fields, but no known successful strategy intent may have:

```text
S[id].submitter == address(0)
S[id].timeframeKey == bytes32(0)
S[id].marketIdHandle == bytes32(0)
```

### Swap Record Validity

Known successful swap intents must have non-zero stable references.

Expressions:

```text
X[id].submitter != address(0)
X[id].confidentialVault != address(0)
X[id].inputWrapper != address(0)
X[id].routeKey != bytes32(0)
X[id].lockedAmountHandle != bytes32(0)
X[id].unshieldRequestHandle != bytes32(0)
X[id].deadline > X[id].createdAt
```

`routeKey` is currently opaque. Invariants must only treat it as a non-zero committed field until route/execution-template semantics are finalized.

### Status Monotonicity

Strategy status transitions:

```text
Unset -> Active -> Cancelled
```

Swap status transitions currently implemented:

```text
Unset -> Active -> Executed
Unset -> Active -> Refunded
```

Forbidden transitions:

```text
Executed -> Active
Executed -> Unset
Refunded -> Active
Refunded -> Unset
Active -> Unset
```

Do not overload `Cancelled` to mean settled or refunded. Strategy intents use `Cancelled`; swap intents use `Executed` or `Refunded`.

## Cross-Family Isolation Invariants

These are mandatory now that one controller handles more than one intent family.

### Submission Isolation

Submitting a strategy intent must not mutate existing swap intent records.

Expression:

```text
after submitStrategyIntent(...):
    for all known swap ids x:
        X[x] == snapshotBefore.X[x]
        VL[X[x].confidentialVault][x] == snapshotBefore.VL[X[x].confidentialVault][x]
```

Submitting a swap intent must not mutate existing strategy intent records.

Expression:

```text
after submitSwapIntent(...):
    for all known strategy ids s:
        S[s] == snapshotBefore.S[s]
        SH[s] == snapshotBefore.SH[s]
```

The only intentionally shared state changed by either submit path is:

```text
nonce(msg.sender)' == nonce(msg.sender) + 1
```

### Cancellation Isolation

Cancelling a strategy intent must not mutate swap records or vault locks.

Expression:

```text
after cancelStrategyIntent(s):
    for all known swap ids x:
        X[x] == snapshotBefore.X[x]
        VL[X[x].confidentialVault][x] == snapshotBefore.VL[X[x].confidentialVault][x]
```

Swap intents are final after submit in the current implementation. There is no `cancelSwapIntent(...)` path.

### Handle Namespace Isolation

Strategy component handles and swap locked-amount handles have different semantics and must not be reused accidentally by controller logic.

Required invariant check for tracked ids:

```text
for all strategy ids s, swap ids x, component index i:
    SH[s][i] != X[x].lockedAmountHandle
```

This is a safety check against accidental handle reuse in tests and mocks. It is not a cryptographic uniqueness proof.

### Rotation Isolation

Listener operator rotation must affect future strategy submissions only.

Expressions:

```text
after setListenerOperator(L2):
    for all existing strategy ids s:
        S[s] == snapshotBefore.S[s]
        SH[s] == snapshotBefore.SH[s]

    for all existing swap ids x:
        X[x] == snapshotBefore.X[x]
        VL[X[x].confidentialVault][x] == snapshotBefore.VL[X[x].confidentialVault][x]
```

Vault rotation must affect future swap submissions only.

Expressions:

```text
after setConfidentialVault(V2):
    for all existing swap ids x:
        X[x].confidentialVault == snapshotBefore.X[x].confidentialVault
        VL[X[x].confidentialVault][x] == snapshotBefore.VL[X[x].confidentialVault][x]

    for all existing strategy ids s:
        S[s] == snapshotBefore.S[s]
        SH[s] == snapshotBefore.SH[s]
```

### Pause Isolation

Pause must block new submissions for every implemented family, while implemented cancellation paths remain available.

Expressions:

```text
C.paused() == true:
    submitStrategyIntent(...) reverts
    submitSwapIntent(...) reverts
    cancelStrategyIntent(activeStrategyId) may succeed
```

## Vault Registry Invariants

### Wrapper Registry Bijection

For every registered underlying/wrapper pair:

```text
V.wrapperForUnderlying(U) == W
V.underlyingForWrapper(W) == U
W != address(0)
U != address(0)
IFHERC20ERC20Wrapper(W).underlying() == U
rate(W) > 0
```

No wrapper may be registered to more than one underlying, and no underlying may be registered to more than one wrapper.

Expressions:

```text
V.wrapperForUnderlying(U1) == W and V.wrapperForUnderlying(U2) == W -> U1 == U2
V.underlyingForWrapper(W1) == U and V.underlyingForWrapper(W2) == U -> W1 == W2
```

### Registry Stability

Once a wrapper is registered, the mapping must not change.

Expressions:

```text
snapshot.wrapperForUnderlying(U) == W != address(0):
    V.wrapperForUnderlying(U) == W

snapshot.underlyingForWrapper(W) == U != address(0):
    V.underlyingForWrapper(W) == U
```

This invariant is important because a wrapper change would reinterpret all historical balances and locks.

## Deposit and Unshield Accounting Invariants

These invariants use the mock CoFHE harness value store. They assume cryptographic operations are correct and verify AlphaEngine's accounting logic.

### Deposit/Shield Exactness

For a successful deposit:

Inputs:

```text
amount > 0
amount % rate(W) == 0
W == V.wrapperForUnderlying(U)
recipient != address(0)
```

Expected state deltas:

```text
shieldedUnits = amount / rate(W)

underlyingBalance(U, depositor)' == underlyingBalance(U, depositor) - amount
underlyingBalance(U, address(V))' == underlyingBalance(U, address(V))
underlyingBalance(U, W)' == underlyingBalance(U, W) + amount
cbal(W, recipient)' == cbal(W, recipient) + shieldedUnits
ctotal(W)' == ctotal(W) + shieldedUnits
```

The vault's underlying balance must be unchanged at the end of the transaction because the vault only stages the ERC20 before approving and shielding through the wrapper.

### Deposit Failure Atomicity

Any failed deposit must leave tracked balances unchanged.

Expression:

```text
if depositAndShield(...) reverts:
    underlyingBalance(U, depositor)' == underlyingBalance(U, depositor)
    underlyingBalance(U, address(V))' == underlyingBalance(U, address(V))
    underlyingBalance(U, W)' == underlyingBalance(U, W)
    cbal(W, recipient)' == cbal(W, recipient)
    ctotal(W)' == ctotal(W)
```

Failure cases:
- unregistered underlying
- zero amount
- zero recipient
- amount not divisible by `rate(W)`
- amount exceeds FHERC20 `uint64` precision after rate conversion
- fee-on-transfer or other balance-drift behavior

### Unshield Request Accounting

For a successful unshield request:

Inputs:

```text
amount > 0
W is registered
recipient != address(0)
caller is account or valid operator
```

Expected state deltas:

```text
cbal(W, account)' == cbal(W, account) - amount
ctotal(W)' == ctotal(W) - amount
pendingUnshieldUnits(W)' == pendingUnshieldUnits(W) + amount
underlyingBalance(U, W)' == underlyingBalance(U, W)
underlyingBalance(U, recipient)' == underlyingBalance(U, recipient)
```

The unshield request burns confidential units and creates a pending claim. It does not transfer underlying ERC20 until `claimUnshielded(...)`.

### Unshield Claim Accounting

For a successful claim:

Inputs:

```text
claim amount == decryptedAmount
U == V.underlyingForWrapper(W)
```

Expected state deltas:

```text
underlyingOut = decryptedAmount * rate(W)

underlyingBalance(U, W)' == underlyingBalance(U, W) - underlyingOut
underlyingBalance(U, recipient)' == underlyingBalance(U, recipient) + underlyingOut
pendingUnshieldUnits(W)' == pendingUnshieldUnits(W) - decryptedAmount
```

The wrapper's documented `inferredTotalSupply()` can be greater than confidential total supply while unshield claims are pending:

```text
underlyingBalance(U, W) / rate(W) == ctotal(W) + pendingUnshieldUnits(W)
```

In a controlled handler with no direct underlying transfers into the wrapper, this equality should hold. If a future test deliberately sends underlying directly to the wrapper, the invariant must be weakened to:

```text
underlyingBalance(U, W) / rate(W) >= ctotal(W) + pendingUnshieldUnits(W)
```

## Vault Swap Lock Invariants

### Lock Lifecycle Monotonicity

Vault lock state transitions currently allowed:

```text
Unset -> Locked -> UnshieldRequested
UnshieldRequested -> Consumed
UnshieldRequested -> Refunded
```

Forbidden transitions:

```text
Locked -> Unset
Locked -> Consumed
UnshieldRequested -> Locked
UnshieldRequested -> Unset
Consumed -> Locked
Consumed -> UnshieldRequested
Consumed -> Unset
Refunded -> Locked
Refunded -> UnshieldRequested
Refunded -> Unset
```

### Lock Field Immutability

Once a lock is created, its identity fields must never change.

Expression:

```text
if VL[V][id].status != Unset:
    VL[V][id].account == originalLockAccount[id]
    VL[V][id].wrapper == originalLockWrapper[id]
    euint64.unwrap(VL[V][id].lockedAmount) == originalLockHandle[id]
```

### Lock Exactness

For a successful lock:

```text
lockedValue = evalue(VL[V][id].lockedAmount)

cbal(W, account)' == cbal(W, account) - lockedValue
cbal(W, address(V))' == 0
VL[V][id].status' == SwapIntentLockStatus.UnshieldRequested
```

The stored lock amount must be the FHERC20-returned actual transferred amount, not merely the requested encrypted input. The vault immediately requests unshield on that locked amount in the same transaction, so the vault does not retain confidential escrow balance after submit.

Expression:

```text
X[id].lockedAmountHandle == euint64.unwrap(VL[X[id].confidentialVault][id].lockedAmount)
X[id].unshieldRequestHandle == euint64.unwrap(VL[X[id].confidentialVault][id].unshieldRequestHandle)
```

### Settlement Consume Exactness

For the current implementation, `settleSwapIntent(...)` and `refundSwapIntent(...)` are the only terminal paths for an already-unshield-requested lock.

Expression:

```text
status(VL[V][id]) == UnshieldRequested
-> after settleSwapIntent(...)
status(VL[V][id])' == Consumed

status(VL[V][id]) == UnshieldRequested
-> after refundSwapIntent(...)
status(VL[V][id])' == Refunded
```

Current unit-tested settlement path also enforces:

```text
claimedUnderlying == decryptedInputAmount * rate(inputWrapper)
shieldedOutputUnits == outputUnderlyingAmount / rate(outputWrapper)
```

### Swap Unshield Request Handle

For a successful swap unshield request:

```text
status(VL[V][id]) == Locked
lockedAmount(VL[V][id]) == L
```

After:

```text
status(VL[V][id])' == UnshieldRequested
unshieldRequestHandle(VL[V][id])' == U
euint64.unwrap(U) != bytes32(0)
evalue(U) == actualBurnedUnits
```

For the controlled happy path where the vault still owns the full locked amount:

```text
actualBurnedUnits == evalue(L)
```

The finalize path must verify `U`, not the original requested encrypted input. If `actualBurnedUnits == 0`, settlement must not execute a swap.

### Double Spend Prevention

No lock may be unlocked or consumed more than once.

Expressions:

```text
status(id) == Consumed -> settleSwapIntent(id, ...) reverts
status(id) == Refunded -> refundSwapIntent(id, ...) reverts
```

### Vault Escrow Balance Conservation

For each tracked wrapper:

```text
cbal(W, address(V)) == freeVaultBalance(W)
                    + sum(activeLockedValue(id) for tracked locks in W)
                    + sum(consumedLockedValue(id) for tracked locks in W)
```

For the current handler, `freeVaultBalance(W)` should normally be `0` because the vault should not receive confidential balances except through locks. If future flows intentionally mint or transfer FHERC20 directly to the vault, the handler must track that free balance explicitly.

### Per-User Confidential Balance Conservation

For each tracked user and wrapper, excluding unshield flows:

```text
cbal(W, user)
+ sum(activeLockedValue(id) for locks owned by user in W)
+ sum(consumedLockedValue(id) for locks owned by user in W)
== shieldedDepositsToUser(W, user)
```

Including unshield requests:

```text
cbal(W, user)
+ sum(activeLockedValue(id) for locks owned by user in W)
+ sum(consumedLockedValue(id) for locks owned by user in W)
+ unshieldRequestedUnits(W, user)
== shieldedDepositsToUser(W, user)
```

After successful unshield claim, `unshieldRequestedUnits(W, user)` remains part of the user's historical accounting, while underlying ERC20 has moved to the unshield recipient.

### Wrapper-Level Confidential Supply Conservation

For each tracked wrapper in a controlled handler with no external direct wrapper transfers:

```text
ctotal(W) == sum(cbal(W, account) for all tracked FHERC20 holders)
```

The tracked holder set must include:
- each depositor/recipient
- the vault
- any future settlement/executor recipient if added

If the handler allows untracked recipients, this invariant must not be used until the handler tracks them.

### Underlying Reserve Conservation

For each registered wrapper in a controlled handler:

```text
underlyingBalance(U, W) / rate(W) == ctotal(W) + pendingUnshieldUnits(W)
```

If direct underlying transfers into `W` are allowed in the test sequence, use the weaker reserve lower bound:

```text
underlyingBalance(U, W) / rate(W) >= ctotal(W) + pendingUnshieldUnits(W)
```

The vault should not retain staged ERC20 after successful deposit/shield:

```text
underlyingBalance(U, address(V)) == expectedVaultUnderlyingDust(U)
```

For current controlled tests:

```text
expectedVaultUnderlyingDust(U) == 0
```

## Controller/Vault Parity Invariants

### Active Swap Parity

For each known active swap intent:

```text
uint8(X[id].status) == uint8(IntentStatus.Active)
uint8(VL[X[id].confidentialVault][id].status) == uint8(SwapIntentLockStatus.UnshieldRequested)
VL[X[id].confidentialVault][id].account == X[id].submitter
VL[X[id].confidentialVault][id].wrapper == X[id].inputWrapper
euint64.unwrap(VL[X[id].confidentialVault][id].lockedAmount) == X[id].lockedAmountHandle
euint64.unwrap(VL[X[id].confidentialVault][id].unshieldRequestHandle) == X[id].unshieldRequestHandle
```

Swap intents are final after submit in both the legacy and fresh implementations. There is no cancelled-swap parity state.
Expired or paused swap intents may instead end in refunded parity:

```text
uint8(X[id].status) == uint8(IntentStatus.Refunded)
uint8(VL[X[id].confidentialVault][id].status) == uint8(SwapIntentLockStatus.Refunded)
```

## Access and Permission Invariants

Where observable in the mock task manager:

### Strategy Access

For each successful strategy submission:

```text
isAllowed(S[id].marketIdHandle, address(C)) == true
isAllowed(S[id].marketIdHandle, listenerOperatorAtSubmit) == true

for each handle h in SH[id]:
    isAllowed(h, address(C)) == true
    isAllowed(h, listenerOperatorAtSubmit) == true
```

Listener-operator rotation must not retroactively permission old handles to the new operator.

### Swap Access

For each successful legacy swap submission:

```text
isAllowed(requestedInputHandle, address(C)) == true
isAllowed(requestedInputHandle, X[id].confidentialVault) == true
```

For each vault lock where observable:

```text
isAllowed(X[id].lockedAmountHandle, address(V)) == true
```

If upstream FHERC20 permission behavior changes, update this section before changing tests.

For each successful fresh swap submission, the controller retains permission
to the internalized requested handle and the recorded escrow is granted access
before locking. The escrow-returned handle remains canonical in controller and
escrow state.

## Admin and Pause Invariants

### Non-Zero Critical Config

After initialization:

```text
C.listenerOperator() != address(0)
```

After vault configuration:

```text
C.confidentialVault() != address(0)
AlphaEngineConfidentialVault(C.confidentialVault()).intentController() == address(C)
```

After vault initialization:

```text
V.intentController() != address(0)
V.owner() != address(0)
```

### Authorization

Only owner may:
- set listener operator
- set confidential vault
- pause/unpause controller
- set vault intent controller
- pause/unpause vault
- create/register wrappers

Only the configured intent controller may:
- lock for swap intent
- settle swap intent

Invariant handlers should include unauthorized calls where possible and assert no state mutation after reverts.

### Vault Intent Controller Rotation Safety

The vault's `intentController` pointer is the authority for lock and settle. Rotating it while active locks exist can strand historical locks unless the old controller is restored.

Required design invariant before randomizing `setIntentController(...)` in stateful handlers:

```text
setIntentController(newController) may happen only if:
    activeLockCount(V) == 0
or:
    all active historical locks remain unlockable/consumable by an authorized controller path
```

Current implementation now tracks `liveSwapLockCount(V)` on-chain and forbids `setIntentController(...)` while the count is non-zero. Therefore, random invariant handlers still should not rotate the vault controller while locks exist, but the safety rule is now enforced by contract state rather than by convention only.

## Event/State Parity Properties

These are usually better as unit/fuzz tests than stateful invariants, but they remain release-gate properties.

### Strategy Submit Event

For every `StrategyIntentSubmitted` event:

```text
event.intentId == id
event.submitter == S[id].submitter
event.marketIdHandle == S[id].marketIdHandle
event.timeframeKey == S[id].timeframeKey
event.componentHandles == SH[id]
event.deadline == S[id].deadline
event.payloadHash == S[id].payloadHash
event.submitterNonce == S[id].submitterNonce
```

### Legacy Swap Submit Event

For every `SwapIntentSubmitted` event:

```text
event.intentId == id
event.submitter == X[id].submitter
event.inputWrapper == X[id].inputWrapper
event.confidentialVault == X[id].confidentialVault
event.routeKey == X[id].routeKey
event.lockedAmountHandle == X[id].lockedAmountHandle
event.unshieldRequestHandle == X[id].unshieldRequestHandle
event.deadline == X[id].deadline
event.payloadHash == X[id].payloadHash
event.submitterNonce == X[id].submitterNonce
```

### Fresh Confidential Swap Submit Events

For every `ConfidentialSwapSubmitted` and matching
`ConfidentialSwapExecutionCommitted` pair, all event fields equal the fresh
record getter. In particular, the indexed commitment event must equal the
stored `executionDataHash` and `minimumOutputCommitment`; neither value may be
accepted from the operator at execution without recomputation.

### Vault Lock Events

For every `SwapIntentLocked` event:

```text
event.intentId == id
event.account == VL[V][id].account
event.wrapper == VL[V][id].wrapper
euint64.unwrap(event.lockedAmount) == euint64.unwrap(VL[V][id].lockedAmount)
```

For every `SwapIntentUnshieldRequested` event:

```text
event.intentId == id
event.account == VL[V][id].account
event.inputWrapper == VL[V][id].wrapper
euint64.unwrap(event.unshieldRequestHandle) == euint64.unwrap(VL[V][id].unshieldRequestHandle)
```

For every `SwapIntentLockConsumed` event:

```text
event.intentId == id
event.account == originalLockAccount[id]
event.wrapper == originalLockWrapper[id]
euint64.unwrap(event.consumedAmount) == originalLockHandle[id]
```

## Future Settlement Invariants

These are now implemented for a two-wrapper mock-settlement path with explicit output-rate
handling. Higher-decimal dust decomposition is covered by deterministic unit and real
PoolManager tests because the current stateful output fixture deliberately emits exact wrapper
multiples. Concrete route-specific output pricing belongs in deterministic
reference/integration tests rather than stateful invariant handlers.

### Settlement Status

Do not use `Cancelled` to mean settled. The legacy implementation uses
`IntentStatus.Executed/Refunded`; the fresh controller uses
`SwapIntentStatus.Executed/Refunded`; both pair with escrow
`SwapIntentLockStatus.Consumed/Refunded`.

Current implemented swap state machine:

```text
Unset -> Active submit
Active submit -> UnshieldRequested lock
UnshieldRequested lock -> Executed/Consumed
UnshieldRequested lock -> Refunded/Refunded
```

### Settlement Accounting

For exact-input settlement, implemented and required execute invariants specify:

```text
inputLockedUnits == inputConsumedUnits
underlyingInputDelta == inputConsumedUnits * rate(inputWrapper)
underlyingOutputDelta >= minOutput
outputConfidentialMintedUnits == outputUnderlyingDeposited / rate(outputWrapper)
```

For batching, future invariants must specify:

```text
sum(userInputConsumed) == batchInputConsumed
sum(userOutputCredited) <= batchOutputReceivedAfterFees
```

No batching invariant may be asserted until the corresponding contracts exist. Concrete PoolManager price/output parity is enforced through deterministic twin-pool reference tests, not by random stateful invariant selectors.

## Implementation Status and Next Test Step

Implemented as of 2026-04-14:

1. The controller invariant handler covers strategy submit/cancel, swap submit/execute/refund, listener rotation, and vault rotation.
2. Cross-family id and handle isolation is asserted for known strategy and swap ids.
3. Vault rotation is included in the controller invariant handler; historical swap records remain tied to their recorded vault.
4. A vault invariant handler covers two registered wrappers, two tracked users, deposits, locks, unshield requests, unshield claims, cross-wrapper settlement, and dust-settle attempts through a mock executor.
5. Vault accounting conservation checks use `mockStorage` values from the local CoFHE test harness.
6. Pending unshield units are tracked explicitly and included in wrapper reserve conservation.

Next invariant work:

1. Keep `routeKey` metadata-only in invariants until/if a canonical on-chain route registry exists.
2. Add batch-level conservation invariants only when batching exists.
3. Extend the two-wrapper settlement model to more than one output wrapper only when the protocol introduces multiple approved confidential output assets in the same invariant run.
4. Do not randomize vault `setIntentController(...)` while active locks exist unless the contract later gains an explicit unlockability-preserving rotation design beyond the current `liveSwapLockCount == 0` gate.
