# Invariant Ledger

## Purpose

This document is the living invariant ledger for `alphaengine-contracts`.

It must be updated whenever a contract state machine, custody boundary, intent family, or accounting model changes. Unit tests can prove individual examples. Fuzz tests can prove bounded input properties. Invariant tests must prove that core state relationships remain true across random stateful action sequences.

The current implementation has two stateful domains:
- `AlphaEngineIntentController`: strategy and swap-intent lifecycle.
- `AlphaEngineConfidentialVault`: FHERC20 wrapper registry, deposit/shield, unshield delegation, and swap-intent escrow locks.

PoolManager swap execution, batching, output minting, leverage/UEI families, and settlement result posting are not implemented yet. Their invariants are listed as future sections so they are not forgotten, but they must not be asserted until the corresponding production code exists.

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
- mixed controller handler with swap submissions, swap cancellations, listener rotation, and vault rotation

### Strategy Handle Count Parity

The stored strategy component-handle array length must always match the stored component count.

Expression:

```text
len(SH[id]) == S[id].componentCount
```

Current scope:
- strategy intents only
- random component count bounded to `[1, 16]`
- cross-checked against stored strategy snapshots while swap intents are also being submitted and cancelled

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
- strategy and swap cancellations
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
- cancelled swap records map to `Unlocked` vault locks
- vault rotation affects future swap submissions only because historical swap records keep their recorded vault

### Cross-Family Isolation

Known strategy and swap intent ids must remain unique and family-scoped across mixed submissions.

Implemented checks:
- each known id belongs to exactly one implemented family
- strategy component handles are not reused as known swap locked-amount handles
- known swap locked-amount handles are not reused as strategy component handles
- cancelling a swap leaves known strategy records and component handles unchanged in fuzz coverage
- cancelling a strategy leaves known swap records and vault locks unchanged in fuzz coverage

### Vault Lifecycle and Accounting

The vault invariant handler now covers one registered wrapper, two tracked users, and stateful deposit, lock, unlock, consume, unshield-request, and unshield-claim actions.

Implemented checks:
- wrapper registry stability and wrapper/underlying/rate parity
- lock identity immutability and status monotonicity for tracked locks
- vault confidential escrow balance equals active plus consumed tracked locks
- per-user confidential balance conservation including active locks, consumed locks, and historical unshield requests
- confidential total supply equals tracked user balances plus vault balance
- wrapper underlying reserve equals confidential supply plus pending unshield units in the controlled handler
- vault staged underlying ERC20 balance remains zero after successful deposit/shield
- unshield claim snapshots remain tied to tracked users and non-zero amounts
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
- cancel swap
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
        X[id].lockedAmountHandle
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
Unset -> Active -> Cancelled
```

Forbidden transitions:

```text
Cancelled -> Active
Cancelled -> Unset
Active -> Unset
```

Future settlement will require a richer status enum or a separate settlement record. Do not overload `Cancelled` to mean settled or consumed.

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

Cancelling a swap intent must not mutate strategy records.

Expression:

```text
after cancelSwapIntent(x):
    for all known strategy ids s:
        S[s] == snapshotBefore.S[s]
        SH[s] == snapshotBefore.SH[s]
```

The expected mutation for swap cancellation is limited to:

```text
X[x].status' == IntentStatus.Cancelled
VL[X[x].confidentialVault][x].status' == SwapIntentLockStatus.Unlocked
```

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

Pause must block new submissions for every implemented family, but cancellation must remain available.

Expressions:

```text
C.paused() == true:
    submitStrategyIntent(...) reverts
    submitSwapIntent(...) reverts
    cancelStrategyIntent(activeStrategyId) may succeed
    cancelSwapIntent(activeSwapId) may succeed
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
Unset -> Locked -> Unlocked
Unset -> Locked -> Consumed
```

Forbidden transitions:

```text
Unlocked -> Locked
Unlocked -> Consumed
Unlocked -> Unset
Consumed -> Locked
Consumed -> Unlocked
Consumed -> Unset
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
cbal(W, address(V))' == cbal(W, address(V)) + lockedValue
VL[V][id].status' == SwapIntentLockStatus.Locked
```

The stored lock amount must be the FHERC20-returned actual transferred amount, not merely the requested encrypted input.

Expression:

```text
X[id].lockedAmountHandle == euint64.unwrap(VL[X[id].confidentialVault][id].lockedAmount)
```

### Unlock Exactness

For a successful unlock:

```text
lockedValue = evalue(VL[V][id].lockedAmount)

cbal(W, VL[V][id].account)' == cbal(W, VL[V][id].account) + lockedValue
cbal(W, address(V))' == cbal(W, address(V)) - lockedValue
VL[V][id].status' == SwapIntentLockStatus.Unlocked
```

Unlock must refund the original lock account, not `msg.sender`, owner, listener, or current vault.

### Consume Exactness

For the current implementation, consume only marks the escrow lock as non-refundable. It does not burn or unshield.

Expression:

```text
cbal(W, address(V))' == cbal(W, address(V))
VL[V][id].status' == SwapIntentLockStatus.Consumed
```

Future settlement may replace this with burn/unshield/output-credit accounting. That change must update this ledger before implementation.

### Double Spend Prevention

No lock may be unlocked or consumed more than once.

Expressions:

```text
status(id) == Unlocked -> unlockSwapIntent(id) reverts
status(id) == Unlocked -> consumeSwapIntentLock(id) reverts
status(id) == Consumed -> unlockSwapIntent(id) reverts
status(id) == Consumed -> consumeSwapIntentLock(id) reverts
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
uint8(VL[X[id].confidentialVault][id].status) == uint8(SwapIntentLockStatus.Locked)
VL[X[id].confidentialVault][id].account == X[id].submitter
VL[X[id].confidentialVault][id].wrapper == X[id].inputWrapper
euint64.unwrap(VL[X[id].confidentialVault][id].lockedAmount) == X[id].lockedAmountHandle
```

### Cancelled Swap Parity

For each known cancelled swap intent:

```text
uint8(X[id].status) == uint8(IntentStatus.Cancelled)
uint8(VL[X[id].confidentialVault][id].status) == uint8(SwapIntentLockStatus.Unlocked)
```

This remains true because current cancellation always unlocks/refunds. If future settlement adds a settled status, do not allow `Cancelled` to represent settled/consumed locks.

### Historical Vault Parity

Swap cancellation must use the vault recorded on the intent, not the currently configured vault.

Expression:

```text
cancelSwapIntent(id):
    mutates VL[X[id].confidentialVault][id]
    does not mutate VL[C.confidentialVault()][id] unless C.confidentialVault() == X[id].confidentialVault
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

For each successful swap submission:

```text
isAllowed(requestedInputHandle, address(C)) == true
isAllowed(requestedInputHandle, X[id].confidentialVault) == true
```

For each vault lock where observable:

```text
isAllowed(X[id].lockedAmountHandle, address(V)) == true
```

If upstream FHERC20 permission behavior changes, update this section before changing tests.

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
- unlock swap intent
- consume swap intent lock

Invariant handlers should include unauthorized calls where possible and assert no state mutation after reverts.

### Vault Intent Controller Rotation Safety

The vault's `intentController` pointer is the authority for lock, unlock, and consume. Rotating it while active locks exist can strand historical locks unless the old controller is restored.

Required design invariant before randomizing `setIntentController(...)` in stateful handlers:

```text
setIntentController(newController) may happen only if:
    activeLockCount(V) == 0
or:
    all active historical locks remain unlockable/consumable by an authorized controller path
```

Current implementation does not track `activeLockCount(V)` on-chain and does not maintain per-lock controller authority. Therefore, next invariant handlers must not randomly call `setIntentController(...)` after locks exist unless the contract is first changed to preserve unlockability.

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

### Swap Submit Event

For every `SwapIntentSubmitted` event:

```text
event.intentId == id
event.submitter == X[id].submitter
event.inputWrapper == X[id].inputWrapper
event.confidentialVault == X[id].confidentialVault
event.routeKey == X[id].routeKey
event.lockedAmountHandle == X[id].lockedAmountHandle
event.deadline == X[id].deadline
event.payloadHash == X[id].payloadHash
event.submitterNonce == X[id].submitterNonce
```

### Vault Lock Events

For every `SwapIntentLocked` event:

```text
event.intentId == id
event.account == VL[V][id].account
event.wrapper == VL[V][id].wrapper
euint64.unwrap(event.lockedAmount) == euint64.unwrap(VL[V][id].lockedAmount)
```

For every `SwapIntentUnlocked` event:

```text
event.intentId == id
event.account == originalLockAccount[id]
event.wrapper == originalLockWrapper[id]
euint64.unwrap(event.refundedAmount) != bytes32(0)
```

For every `SwapIntentLockConsumed` event:

```text
event.intentId == id
event.account == originalLockAccount[id]
event.wrapper == originalLockWrapper[id]
euint64.unwrap(event.consumedAmount) == originalLockHandle[id]
```

## Future Settlement Invariants

These must be finalized before adding PoolManager execution or output minting.

### Settlement Status

Do not use `Cancelled` to mean settled. Add an explicit settlement state or settlement record.

Required future state machine:

```text
Unset -> Locked -> Cancelled/Unlocked
Unset -> Locked -> Settled/Consumed
```

### Settlement Accounting

For exact-input settlement, future invariants must specify:

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

No batching or PoolManager invariant may be asserted until the corresponding contracts exist.

## Implementation Status and Next Test Step

Implemented as of 2026-04-10:

1. The controller invariant handler covers both strategy and swap submissions/cancellations.
2. Cross-family id and handle isolation is asserted for known strategy and swap ids.
3. Vault rotation is included in the controller invariant handler; historical swap records remain tied to their recorded vault.
4. A vault invariant handler covers one registered wrapper, two tracked users, deposits, locks, unlocks, consume, unshield requests, and unshield claims.
5. Vault accounting conservation checks use `mockStorage` values from the local CoFHE test harness.
6. Pending unshield units are tracked explicitly and included in wrapper reserve conservation.

Next invariant work:

1. Add route/settlement invariants only after `routeKey` is replaced by finalized execution-template semantics.
2. Add output-mint and burn/unshield invariants only when settlement code exists.
3. Add batch-level conservation invariants only when batching exists.
4. Do not randomize vault `setIntentController(...)` while active locks exist unless the contract first gains an explicit unlockability-preserving rotation design.
