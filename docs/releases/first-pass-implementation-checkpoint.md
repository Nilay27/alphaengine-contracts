# First-pass implementation checkpoint

Date: 2026-08-27

Implementation commit: `365b3e668217b1f1ca4caede9e6b8fb60526d430`

Baseline commit: `49d96e8a80d6903d1d30affc6f836bcc0ac13800`

Stage 9 deployment/migration commit: `e627c75`

## Status

The commit above is the immutable traceability point for AlphaEngine's first-pass StrategyManager and confidential-swap implementation. It passed the complete Stage 10 local integration gate documented in `stage-10-first-pass-integration-validation.md`.

This checkpoint is not a public deployment, audit freeze, tag, external-audit candidate, or production-readiness claim. Second-pass FundVault work and the consolidated security-review cadence remain pending. This Stage 11 documentation commit intentionally follows the implementation SHA; it does not alter the checkpointed production or test code.

## Production source scope at the checkpoint

- `src/strategy/AlphaEngineTraderQualificationRegistry.sol`
- `src/strategy/AlphaEngineCompetitionStrategyManager.sol`
- `src/strategy/AlphaEngineCapitalStrategyManager.sol`
- `src/swap/AlphaEngineConfidentialSwapController.sol`
- `src/swap/AlphaEngineConfidentialSwapEscrow.sol`
- `src/fherc20/AlphaEngineConfidentialAssetRegistry.sol`
- `src/fherc20/AlphaEngineConfidentialAssetGateway.sol`
- `src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol`
- `src/executors/AlphaEngineV4SwapExecutor.sol`
- `src/libraries/AlphaEngineStrategyHashLib.sol`
- `src/libraries/AlphaEngineExecutionHashLib.sol`
- First-pass interfaces under `src/interfaces/`; the FundVault and vault-execution interfaces are forward boundary definitions only and have no implementation at this checkpoint.

## Operational and consumer scope

- `script/DeployAlphaEngineV2.s.sol`
- `deployments/v2/manifest.schema.json`
- checked-in v2 ABIs, storage layouts, listener selectors/topics, and hash vectors;
- v2 listener cutover requirements;
- unit, fuzz, invariant, integration, deployment, and artifact-parity tests needed to establish first-pass behavior.

The deployment script creates fresh contracts paused and unfunded on Foundry's local EVM. It does not migrate legacy storage or grant hidden authority to the deployment signer. Post-verification governance actions are explicit and hash-bound.

## Historical evidence

The legacy mixed controller and confidential vault are absent from the active source/test/script tree. Preserve permanently:

- `deployments/arbitrum-sepolia-latest.json` at SHA-256 `e35253ff1c1aaa16e67cf6543942332031ac1691392bb578a07ca6fa2c5aa7e2`;
- legacy checked-in ABIs and storage layouts;
- legacy addresses and final indexed block when cutover occurs; and
- Git history containing the former source, scripts, and tests.

## Known limitations and residual risk

- Local CoFHE mocks establish contract logic and permissions but do not prove production Fhenix cryptography or network configuration.
- The encrypted-amount unshield wrapper overload remains a temporary integration extension requiring Fhenix review and a documented removal trigger.
- Evaluator and FHE-operator trust is reduced by role separation, exact commitments, expiries, and replay protection but not eliminated.
- The FundVault, public USDC share/accounting manager, Merkle execution policy, decoders, risk caps, and Pendle integration are not implemented.
- No X-Ray, Solidity Auditor, Fizz, or independent external audit has been performed against this checkpoint under the owner-approved consolidated cadence.

## Mutation rule

Any later change to first-pass source, interfaces, ABIs, storage layouts, events, deployment behavior, or replay-critical hashes must explicitly identify this SHA as its base and document the delta. The eventual external-audit candidate will be a new frozen SHA after second-pass implementation, internal security remediation, production Fhenix validation, and release rehearsal.
