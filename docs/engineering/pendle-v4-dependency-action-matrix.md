# Pendle RouterV4 dependency and action matrix

Status: Stage 14 implementation evidence, recorded 2026-08-31.

This document pins the external ABI and live dispatch boundary used by
`AlphaEnginePendleV4PtDecoderAndSanitizer`. It does not approve a production
market, PT, input token, position size, or Merkle root.

## Primary-source evidence

- Official repository: `pendle-finance/pendle-core-v2-public`.
- Pinned source revision:
  `0fcebf79fa7d9eced3137c8d09829e315ed50b3c`.
- Official deployment file: `deployments/42161-core.json`.
- Chain: Arbitrum One, chain ID `42161`.
- Fixed verification block: `500310277`.
- RouterV4 address: `0x888888888889758F76e7103c6CbF23ABbF58F946`.
- RouterV4 runtime code hash at the fixed block:
  `0x6e7e96418259651300fbc9b9035c0613bfefc601ddbd840ab39a068ab3ee4293`.
- PT action facet: `0xd8D200d9A713A1c71cF1e7F694B14E5F1D948b15`.
- PT facet runtime code hash at the fixed block:
  `0x5e98f3973c2fdabae1168b4afe928c16d4ca9d71803efeacd978fc3bb3898063`.
- Both permitted selectors resolved to that facet through
  `selectorToFacet(bytes4)` at the fixed block.

Source SHA-256 evidence at the pinned revision:

| Official source | SHA-256 |
|---|---|
| `contracts/interfaces/IPActionSwapPTV3.sol` | `88e16b8549721dab301ffcfdf75b549d0f9b50db933f4acc5a7c199012614474` |
| `contracts/interfaces/IPAllActionTypeV3.sol` | `cce777cc4a48fd1bddfe378931405cc020c3f12a1eecd17622ee85e5e953664d` |
| `contracts/router/swap-aggregator/IPSwapAggregator.sol` | `34d4414e8d1fd015ca8c24999412961d627314391e8291c2379541d938c883c6` |
| `contracts/interfaces/IPLimitRouter.sol` | `087e1c1dfb554b9f8934de776d70e9a246faa4414ba8f50eef43d762a58e623a` |
| `deployments/42161-core.json` | `0f63f3ef1bd033137494c604cbf1096389425449862b87a3fdd5052ced9b36e4` |

The AlphaEngine-owned minimal interface ABI is independently declared from the
public function ABI rather than copied from the Veda POC. The sorted JSON ABI
SHA-256 is `f24c719c87ce0d97ae301b690fc2ab8605d52e7be9e2711442964cf088b8d469`;
the two-action subset SHA-256 is
`3bea1f49355d3ba3a5a1143599749573c7a1770dd7020995c33833ce6743e5d3`.

Primary references:

- <https://docs.pendle.finance/pendle-v2-dev/Deployments>
- <https://docs.pendle.finance/pendle-v2-dev/Contracts/PendleRouter/PendleRouterOverview>
- <https://docs.pendle.finance/pendle-v2-dev/Contracts/PendleRouter/ContractIntegrationGuide>
- <https://github.com/pendle-finance/pendle-core-v2-public/tree/0fcebf79fa7d9eced3137c8d09829e315ed50b3c>

## Why the facet is part of the trust boundary

Pendle RouterV4 is a selector-to-facet proxy. Its owner can remap a selector
without changing the router runtime bytecode. A Merkle leaf that checks only
the router address and router code hash therefore cannot detect every semantic
upgrade.

The Pendle decoder constructor snapshots the expected router and PT-facet code
hashes. Its deployed immutable bytecode binds those values, and every sanitize
call rechecks:

1. router runtime code hash;
2. expected PT-facet runtime code hash; and
3. the live `selectorToFacet` result for the requested PT action.

Any drift fails closed. Stage 16 must invoke the decoder before every vault
call and must bind the decoder runtime code hash in the policy leaf.

## Permitted action matrix

| Decoder | Selector | Policy-bound arguments | Runtime restrictions |
|---|---|---|---|
| ERC20 | `approve(address,uint256)` | Spender | Zero is allowed for reset; unlimited approval is prohibited; amount remains bound by exact calldata and execution risk checks |
| ERC4626 | `deposit(uint256,address)` | FundVault receiver | Nonzero amount; receiver must equal the immutable FundVault |
| ERC4626 | `mint(uint256,address)` | FundVault receiver | Nonzero amount; receiver must equal the immutable FundVault; Stage 16 max-spend checks remain mandatory |
| ERC4626 | `withdraw(uint256,address,address)` | FundVault receiver and owner | Nonzero amount; receiver and owner must both equal the FundVault |
| ERC4626 | `redeem(uint256,address,address)` | FundVault receiver and owner | Nonzero amount; receiver and owner must both equal the FundVault |
| Pendle RouterV4 | `swapExactTokenForPt(...)` (`0xc81f847a`) | FundVault receiver, market, input token | Nonzero exact input/minimum PT; token must be a direct SY input; no aggregator, scaling, limit order, callback, or native value; bounded approximation |
| Pendle RouterV4 | `swapExactPtForToken(...)` (`0x594a88cc`) | FundVault receiver, market, output token | Nonzero exact PT/minimum output; token must be a direct SY output; no aggregator, scaling, limit order, callback, or native value |

All amounts and complete calldata remain bound by the capital execution
commitment. The Merkle policy constrains the target/code hash, selector,
decoder/code hash, and sanitized address arguments; it does not replace spend,
minimum-receive, expiry, or rolling-cap checks.

## Explicitly unsupported

- ERC20 `transfer` and `transferFrom` through the managed-call boundary;
- unlimited or persistent approvals;
- arbitrary ERC4626 receivers or owners;
- Pendle YT or LP actions;
- Pendle aggregators, `pendleSwap`, external router calldata, scaling, and limit
  orders;
- generic routers, callbacks, native value, leverage, borrowing, flash loans,
  and bridges.

The ERC4626 decoder is reusable code, not permission to call every ERC4626
vault. No ERC4626 target belongs in a production root until its asset, runtime
code hash, upgrade model, accounting behavior, and risk limits are separately
reviewed.

## Remaining deployment input

Stage 14 verifies the current RouterV4 ABI and dispatch dependency. Stage 17
must select and pin the exact production Pendle market, PT, direct USDC/SY
route, and deployment block, then exercise the real entry and unwind path.
Until then, no production Pendle or ERC4626 policy root may be activated.
