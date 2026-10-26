# Mainnet competition role and transaction plan — 22 October 2026

Status: **user-broadcast setup confirmed; competition active, both contracts unpaused**.

The [confirmation record](../../deployments/v2/arbitrum-mainnet-competition-2026-10-22-confirmed.json)
reconciles all seventeen successful transactions in blocks 517207185–517207243.
RPC at block 517207489 confirms roles, old-role removals, intended admins/FHE
operator, exact active competition configuration and both unpaused states.
Total execution cost: `0.000017315496365318 ETH`; all call values zero.
Creation transaction:
[`0x46def456…f98abde5`](https://arbiscan.io/tx/0x46def456385798d226d4fd8a22aea7901ac1f75603f8d8788e1e4402f98abde5).
The user signed/broadcast. Instructions below retain the reviewed preparation;
frontend/backend integration and a real encrypted-flow check remain next.

## Current user-run script: roles and competition start

The owner requests a created competition accepting submissions. The
[`SetupMainnetCompetition`](../../script/SetupMainnetCompetition.s.sol) sequence is:

1. Ten role grants: seven manager roles and two registry roles to the mainnet
   deployer, plus registry issuer authority to the manager contract.
2. Set the manager's future-submission FHE operator to the same mainnet deployer.
3. Revoke the old bootstrap's three observed manager/registry roles.
4. Unpause the qualification registry.
5. Unpause the competition manager.
6. Create the competition with the approved fixed configuration.

That is **seventeen transactions** from the observed starting state. There is no
pause transaction. Final simulated state must be `paused false` for both
contracts, `competitionNonce 1`, and a matching active competition. This
supersedes the earlier paused-creation and deferred-creation proposals.

The script validates chain/sender, pinned implementations, accepted admins/no
pending successors, registry binding, admission, submission limits, schedule,
nonce, all operational permissions and the FHE operator. Already-completed
steps are skipped; a matching existing active competition is checked without
creating a duplicate. An unpaused manager with the wrong operator fails
explicitly because rotation requires pause. No hidden pause or recovery path.

The [public configuration](../../deployments/v2/arbitrum-mainnet-first-competition-2026-10-22.json)
uses the approved Sepolia relative settings: fourteen days for submissions,
one more day for evaluation, fifteen more days of qualification validity and one
qualification slot. These are fixed timestamps from an October 22, 16:00 IST
anchor; they do not move between script runs:

| Setting | Fixed value |
|---|---|
| Submission deadline | 5 November 2026, 16:00 IST (`1793874600`) |
| Evaluation deadline | 6 November 2026, 16:00 IST (`1793961000`) |
| Qualification expiry | 21 November 2026, 16:00 IST (`1795257000`) |
| Expected creation nonce | `0` |
| Predicted competition ID | `0xfdb35917be05418b47908b8f046d23815fb50c02375323c39d9cf94b9bb46618` |

Qualification expiry controls capital-intent eligibility, not leaderboard
visibility or scheduling another competition. Competitions may overlap.

Simulation only, with `ARBITRUM_MAINNET_RPC_URL` loaded in the user's own shell:

```sh
FOUNDRY_PROFILE=create2 forge script \
  script/SetupMainnetCompetition.s.sol:SetupMainnetCompetition \
  --rpc-url "$ARBITRUM_MAINNET_RPC_URL" \
  --sender 0xAcc08cBbeD784Ba9b5B07ADb5F0E299Cb0fD3d95 \
  --slow --offline -vv
```

This needs no account/keystore or signature. Review the ID, new scope/configuration
hash, readable role logs, seventeen transaction count, active competition and
**both pause values false**. The previous hash/output with a paused registry is
superseded. All script success logs describe simulation, even when preparing a
later broadcast. Actual live state requires receipts and fresh RPC checks.

After reviewing the revised simulation, the user adds
`--account alphaengine-mainnet-deployer --broadcast` to the same command. Foundry
prompts once for that invocation. Do not embed passwords/keys in commands,
files or scripts. `--slow` waits for each transaction to succeed before sending
the next. Earlier confirmed transactions remain applied after an interruption;
reconcile live state before a fresh simulation rather than blind `--resume` or
skipping simulation. Competition creation is the final transaction; ensure its
receipt succeeds rather than treating simulated logs as confirmation.

All sixteen focused tests pass. The current public-RPC simulation at block
517206640 prepares seventeen zero-value calls, with zero receipts, and
confirms the final active/unpaused/unpaused state. Estimated cost at that
checkpoint is `0.000047180038711383 ETH`; fees can change. The earlier
paused-creation rehearsal remains historical in the configuration record. This
script deploys no on-chain helper or implementation and moves no protocol funds.

## Read-only checkpoint

Arbitrum One (`42161`), block `517195823`, observed at
`2026-10-22T10:19:49.312Z`:

- Intended temporary admin/signer: `0xAcc08cBbeD784Ba9b5B07ADb5F0E299Cb0fD3d95`
  (`alphaengine-mainnet-deployer`). Both default-admin handovers are complete;
  there is no pending successor or additional 48-hour wait for these role grants.
- Competition manager: `0x7fFcDa0A08401AcF1d114C83B32cE439C48c3681`.
- Trader qualification registry: `0xF7017f2e11E22094ef5E3952eA86768eD302C98D`.
- Both proxy implementation slots and implementation runtime hashes match the
  confirmed deployment at source commit `7ed4c49d2568bc8f89bf6b426b5c66321dbe3f5a`.
  The two current source files are unchanged from that commit.
- None of the nine EOA operational grants below is present. The manager also
  lacks the registry's issuer permission. `fheOperator` is still the previous
  bootstrap address, `0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d`.
- `competitionNonce = 0`: no competition has been created on this manager.
  Submission limits are already three per wallet per rolling 300 seconds.
- CoFHE TaskManager `0x52E7a0cAF234b266bCFAa6aA933a412FDe58432A` reports
  `isEnabled = true`, `accessListEnabled = true`, and all four deployed
  competition/capital/swap-controller/swap-escrow proxies listed. Admission is
  confirmed; a complete mainnet encryption/decryption flow remains to be tested.

The [unsigned transaction plan](../../deployments/v2/arbitrum-mainnet-competition-role-setup-2026-10-22-prepared.json)
contains exact role hashes, targets, recipients, calldata and block evidence.
All fourteen proposed calls pass **independent read-only `eth_call` simulation**
from the public admin address at that block. This is not sequential execution,
a broadcast receipt, or a mainnet lifecycle integration test.

## Setup while paused: eleven transactions

Every transaction is sent by `alphaengine-mainnet-deployer` on chain `42161`,
with zero ETH value. Calls target the proxies above, not implementations.

| Step | Target | Call | Recipient / value | Purpose |
|---|---|---|---|---|
| 1 | Competition manager | `grantRole(COMPETITION_CREATOR_ROLE, admin)` | Intended admin | Create competitions |
| 2 | Competition manager | `grantRole(COMPETITION_CANCELLER_ROLE, admin)` | Intended admin | Cancel active/evaluating or expired competitions |
| 3 | Competition manager | `grantRole(EVALUATOR_ROLE, admin)` | Intended admin | Post encrypted evaluation scores, rank and evidence |
| 4 | Competition manager | `grantRole(FINALIZER_ROLE, admin)` | Intended admin | Finalize after every active submission is evaluated |
| 5 | Competition manager | `grantRole(QUALIFIER_ROLE, admin)` | Intended admin | Publish eligible traders' qualifications through the manager |
| 6 | Competition manager | `grantRole(SCORE_REVEALER_ROLE, admin)` | Intended admin | Request paced public score reveals |
| 7 | Competition manager | `grantRole(PAUSER_ROLE, admin)` | Intended admin | Emergency pause; unpause remains default-admin-only |
| 8 | Qualification registry | `grantRole(QUALIFICATION_REVOKER_ROLE, admin)` | Intended admin | Revoke trader qualifications |
| 9 | Qualification registry | `grantRole(PAUSER_ROLE, admin)` | Intended admin | Emergency pause of qualification issuance |
| 10 | Qualification registry | `grantRole(QUALIFICATION_ISSUER_ROLE, manager)` | Competition manager proxy | Allow the manager's internal `qualifyTrader` call |
| 11 | Competition manager | `updateFheOperator(admin)` | Intended admin | Give future submission handles to the intended decrypting identity |

The registry issuer role belongs to the **manager contract** for this workflow.
The admin uses `QUALIFIER_ROLE` on the manager; giving issuer authority directly
to the EOA is unnecessary and would permit issuing qualifications outside the
competition eligibility checks. `DEFAULT_ADMIN_ROLE` is already held by the
intended admin and must not be granted through ordinary `grantRole`.

Step 11 must execute while paused. Its setting applies to **future** submission
handle permissions; it does not retroactively transfer access to old handles.
The mainnet backend must use that matching decrypting identity before accepting
submissions. Do not copy any wallet material into this plan or repository.

## Retire the previous competition/registry permissions: three transactions

After verifying steps 1–11 and the new pause/revocation grants:

| Step | Target | Call |
|---|---|---|
| 12 | Competition manager | `revokeRole(PAUSER_ROLE, previousBootstrap)` |
| 13 | Qualification registry | `revokeRole(QUALIFICATION_REVOKER_ROLE, previousBootstrap)` |
| 14 | Qualification registry | `revokeRole(PAUSER_ROLE, previousBootstrap)` |

These are the old bootstrap's observed grants in these two contracts. This
does not assert that its permissions in deferred capital/swap contracts have
been retired. Re-read `hasRole`, `fheOperator`, both `defaultAdmin` values and
both `paused()` values after the user executes the setup.

## Frontend/backend integration after confirmed broadcast

After the user's broadcast, freshly verify all roles, the FHE operator, both
unpaused values and the exact active competition/configuration from RPC. The
frontend/backend must bind chain `42161`, the manager proxy and the confirmed
competition ID. An unpaused manager alone is insufficient without the created
active competition.

Establish a separate mainnet listener/checkpoint namespace and matching FHE
operator identity; preserve live Sepolia state. The current listener decrypts,
simulates/evaluates and persists BFF results; it does not automatically submit
the on-chain lifecycle calls below. Existing testnet faucet funding does not
fund users' Arbitrum One gas.

Prove a user-signed mainnet submission, SDK proof acceptance, authorized operator
decryption, evaluation and BFF/UI visibility before announcing the frontend
launch. The owner authorizes this temporary-admin competition start; final
Safe/timelock governance remains a separate outstanding handover.

## Later competition lifecycle transactions

After the submission deadline, call `beginEvaluation(competitionId)` (public,
no dedicated role). Before the evaluation deadline, call `recordEvaluation`
once per active submission with encrypted scores/proof, a unique valid rank
and nonzero evidence hash. Then call `finalizeCompetition` after all active
submissions are evaluated.

After finalization, request public score reveals in cursor order with batches
of at most eight submissions and at least five seconds between reveal calls.
Public decrypt availability is asynchronous. Separately call
`publishTraderQualification(submissionId)` for each eligible qualifying trader
while qualification expiry is still in the future and both contracts are
unpaused. Qualification publication does not require public score reveal to
finish first. The off-chain evidence leaderboard and these on-chain lifecycle
transitions are distinct.
