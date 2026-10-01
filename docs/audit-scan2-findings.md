# Cantina Scan #2 (2026-09-30) — findings and dispositions

Scan #2 reviewed `main` at `709638d156e1a74e798ee6c6182a9048ac523ea8` (the merge of PR #43) and
reported 37 findings: 3 High, 27 Medium, 3 Low, 4 Informational. This document records, per finding,
whether it was accepted and fixed on `fix/external-audit-scan2-2026-09`, or rejected and why. Fixes
carry the finding id in the commit subject; regression tests are named `testV4LE<id>_...`.

## High

| ID | Disposition | Notes |
|---|---|---|
| V4LE-97 | Fixed | `FlashloanLiquidator.liquidate` refuses the loan owner as caller, mirroring the vault's refusal of the owner as liquidator and recipient. The helper is the vault's caller and recipient and pays its own caller, so without this it was the documented bypass. Test: `test/vault/FlashloanLiquidatorSelfLiquidation.t.sol`. |
| V4LE-91 | Rejected | An address check cannot bind the final beneficiary through an arbitrary intermediary; that is accepted policy (V4LE-18). The reserve cost of a reserve-backed liquidation is `debt - liquidatorCost` for any liquidator, so a borrower liquidating through an intermediary costs reserves exactly what an independent liquidator costs. The check decides who collects the incentive; it is not a solvency boundary. Documented in `docs/audit-deferred-findings.md`. |
| V4LE-98 | Fixed (revised after V4LE-156) | The first fix bounded the live-price composition inside the valuation, which turned the same state into a valuation revert and therefore a liquidation lockout once the price drifted past the bound (V4LE-156). Now the valuation never bounds principal. Instead the oracle accepts only tokens whose total supply is below v4's int128 settlement limit (`_requireBoundedSupply`, constructor and `setTokenConfig`): a position cannot pay out more of a currency than exists, so no decrease and no take of an accepted position can ever exceed what v4 settles in one call, at any price and any liquidity, and nothing can drift after admission. Chunked removals, partial liquidation and a per-position worst-case payout bound were built and withdrawn (the last one rejects every wide-range position: at the range edge a full-range position's payout is astronomical for any liquidity). Tests: `test/oracle/V4OracleSettlementBound.t.sol` (supply bound at configuration; a position beyond v4's limit, built with dealt balances beyond the token's supply, stays valued and sizable while v4 rejects its decrease; one just below settles whole after its range is crossed), `test/vault/V4VaultSettlementBoundLiquidation.t.sol` (real oracle and vault: a loan whose payout grows to a large fraction of v4's limit after source and pool drift is liquidated whole in one transaction). |
| V4LE-156 | Fixed | Duplicate of V4LE-98 reported against the merged fix; see V4LE-98. |

## Medium

| ID | Disposition | Notes |
|---|---|---|
| V4LE-122 | Fixed | Supply-relative bounds are sized on `_settledLentAssets`: lent assets net of `dailyLendNetInflow` (deposits minus withdrawals since the last daily lend reset). A deposit widens the concentration cap only from the next UTC day; a withdrawal of settled supply shrinks it at once. Test: `test/vault/V4VaultTemporaryDepositCap.t.sol`. |
| V4LE-127 | Fixed | Same mechanism: `_calculateDailyLimit` sizes the daily debt quota on the settled supply, so a same-day deposit cannot widen the day's quota. Same test file. |
| V4LE-121 | Rejected | The v4 settlement bound (`toInt128`) is a hard limit; the window the finding needs is uncollected fees inside `[2^127 - drip, 2^127)`, i.e. about 1.7e38 raw fee units in one position (1.7e20 whole tokens at 18 decimals). No real pool produces that; a margin below the bound would only move the same window. Acknowledged, no change. |
| V4LE-129 | Fixed | `DeployBaseHookUpgrade` registers a fee quoter for `OLD_HOOK` (a `HookFeeController` bound to the old hook when it exposes the fee-state getters, else a reviewed `OLD_HOOK_FEE_QUOTER`), and refuses to run without one. Deployment checklist updated. |
| V4LE-134 | Fixed | Standalone `AutoExit` settles vault debt from both legs before the exit swap and before the reward, mirroring the hook's `_autoExitWithDebtRepayment`. `ExecuteParams` gained an operator-supplied repay route (`repayAmountIn`, `repayAmountOutMin`, `repaySwapData`, other leg to lend token) used only when the lend leg including its reserved reward is short. |
| V4LE-102 | Fixed | Same change: the reward reserved in the other leg is consumed last by the repay route and reduced by exactly the shortfall, so debt is senior to the reward in both legs (the V4LE-14 rule). |
| V4LE-96 | Fixed | `AutoLend.withdraw` redeems `min(recorded shares, vault.maxRedeem)` and keeps the residual lend state, custody and config until everything is redeemed; `forceExit` redeems what it can and transfers the residual vault shares to the NFT owner, so a withdrawal-limited ERC4626 vault can no longer strand principal. |
| V4LE-149 | Fixed | `AutoLeverageLib.landsWithinTolerance` / `improvesTowardTarget` treat a fully repaid loan (`debtAfter == 0`) as a valid zero-ratio landing; debt left against zero collateral is still rejected. |
| V4LE-117 | Fixed | Every `LeverageTransformer` entry that treats `msg.sender` as the vault (`leverageUp`, `leverageDown`, `leverageInTransform`) now requires `vaults[msg.sender]` before the generic caller check; an NFT-owning contract can no longer pose as a vault. |
| V4LE-115 | Fixed | `Automator._checkRemintClaim` (the V4Utils twin) binds a tagged RevertHook remint claim in forwarded hookData to the executed token in `AutoRange` (mint), `AutoLend.withdraw` (re-entry mint/increase) and `AutoLeverage` (increase); a claim naming another owner's drained position reverts. |
| V4LE-93 | Fixed | `AuctionArbExecutor` ownership is fixed at deployment: `transferOwnership` / `renounceOwnership` revert `OwnershipNotTransferable`, so an admitted instance cannot be handed to a public forwarder; a new operator needs a new admitted instance. The controllers' live denylist re-check is V4LE-105. |
| V4LE-139 | Fixed | `getLiquidityForValue` sizes the full liquidity when the floored principal value is zero while more value is needed (sub-Q96 leg plus carried obligation, or dust legs with a third-token quote), instead of a division-by-zero panic that blocked the liquidation. Charge-funding floors are sized on the live payout, and a charge the whole live payout cannot cover reverts `HookChargeUnfundable` (Codex, PR #45). |
| V4LE-104 | Fixed | `getLiquidityForValue` also returns the raw reference-token prices and the quote price; `V4Vault._sendPositionValue` values the received amounts as `mulDiv(received, price, quote)` with no Q96 rounding, so a leg whose normalized price floored to zero no longer escapes the payout cap. `IV4Oracle.getLiquidityForValue` now returns a 4-tuple. |
| V4LE-135 | Fixed | `_normalizeChainlinkPrice` forms the 512-bit product with `FullMath.mulDiv`; results are bit-identical where the old checked product did not overflow. |
| V4LE-113 | Fixed | `_feeObligation` rejects a hook-quoted obligation at or above `2^127` with `SettlementBoundExceeded`; the hook takes the whole obligation in the INCREASE(0) and narrows it with `toInt128`, so such an obligation could never be settled. |
| V4LE-112 | Fixed | Unverified single-source reads always run the reference-token decimals check and, when the reference price comes from the cache, re-check the reference feed's decimals; verified two-source reads still pay nothing. |
| V4LE-124 | Fixed | The external-route planner walks the route's ticks from spot exactly like `Pool.swap`: a zero-liquidity gap is crossed for free and the plan is sized against the liquidity that follows, instead of returning no swap. |
| V4LE-95 | Fixed | The external-route in-range plan is a bisection on the exact tick-walking quote (position price fixed), like the same-pool overload; a one-sided plan is capped at the input the quote actually consumed, so a truncated quote can never oversize the swap. Step bound raised to 64, ticks cached per plan. |
| V4LE-114 | Fixed | A same-pool bisection whose bracket closes on a step-bound-truncated quote reverts `Quote_Truncated` instead of returning the truncated input as if it were the root; the hook surfaces this as a caught, failed action. |
| V4LE-145 | Fixed | The floored Q96 required-ratio is gone: range balance is judged by comparing the liquidities the two amounts would fund (`L0` vs `L1`), which has no zero-flooring intermediate and saturates on overflow, so a near-`MIN_TICK` plan no longer divides by zero. |
| V4LE-146 | Fixed | Same change: the direction check uses the liquidity comparison, so a low-price token0 surplus is no longer truncated to zero and the rebalance is planned in the right direction. |
| V4LE-150 | Fixed | Both analytic solvers use a cancellation-free root form (`(b + sqrtD) / 2a` for `b >= 0`, `2c / (sqrtD + |b|)` for `b < 0`), which yields the linear root when `a == 0` and fixes the floored-discriminant cancellation for small `a`; roots are clamped to the current price and the range. |
| V4LE-99 | Rejected | The pending bucket releases `ceil(pace * min(elapsed, L) / L)` with `pace >= totalDrip` of the parking epoch, while the active path vests `totalDrip * elapsed / L`: for any outage inside one epoch the amount an in-range LP receives at recovery is the same (or larger) through the pending bucket, so routing the post-failure remainder there does not change the described JIT exposure. That exposure is the documented point-in-time tradeoff of donate-based distribution and is identical to an LP entering a throttle window of an untouched pool; cross-epoch remainders already go to pending via `_carryEpoch`. The lease controller is the same. No change. |
| V4LE-126 | Fixed | With `autoLendToleranceTick == 0` the deposit trigger and the re-armed withdrawal trigger sat on the same bucket and the strictly exclusive cursor search skipped the recovery. Zero tolerance now rests the withdrawal one spacing toward the range (`tickLower` / `tickUpper - spacing`), a one-spacing hysteresis; positive aligned tolerances never collided and are unchanged. |
| V4LE-105 | Fixed | Both controllers' `beforeSwap` re-check `!executorDenied[executor]` at discount time (after the `sender == executor` short-circuit), so governance can cut a mutated proxy off immediately; codehash admission cannot bind upgradeable code, documented on the registry. One cold SLOAD on the winner's swaps; gas snapshots regenerated. |
| V4LE-154 | Fixed | `_checkAndExecuteImmediate` requires the live tick inside `oracleTick +- maxTicksFromOracle` before dispatching any immediate action (first registration included), reverting `OutsideOracleWindow()`; refusing rather than skipping avoids arming a satisfied trigger behind the cursor. Oracle-bound helpers are shared with `_afterSwap`. |
| V4LE-131 | Fixed | `_validateTickAlignedConfig` rejects a negative `autoLendToleranceTick`, matching the standalone AutoLend. |

## Low

| ID | Disposition | Notes |
|---|---|---|
| V4LE-100 | Fixed | Same root cause and fix as V4LE-102. |
| V4LE-140 | Fixed | The bitmap walk forms the empty-word far edge in `int256` and clamps it to the tick domain; `_locateNextTick` stops at the bound, so a max-spacing route can no longer wrap into the domain and quote phantom depth. |
| V4LE-130 | Fixed | Range limits and relative exit offsets are applied in `int256` and saturate at the `int24` sentinels (a threshold past every tick is a disabled trigger) in `_computeTriggerTicksCore`, `_calculateRangeTriggerTicks` and `_calculateExitTick`, so a valid large offset no longer overflows on the remint and strips the replacement of its triggers. |

## Hook bytecode

The three hook fixes cost 282 bytes; room was made by moving `setSwapProtectionConfig`'s validation into the
migration sidecar (same external ABI). RevertHook is at 24,060 bytes (516 under the limit).

## Informational

| ID | Disposition | Notes |
|---|---|---|
| V4LE-151 | Rejected (operational) | Already tracked as V4LE-73: provider-side revocation of the historical key is an operational action; no repository change can prove it. CI no longer uses any RPC credential (PR #43). |
| V4LE-110 | Fixed | `leverageUp` resolves the native alias for a WETH-asset vault on a native pool (borrowed WETH unwrapped into the pool side, native leg wrapped for repayment in `leverageDown`) instead of treating the borrow as a third token, mirroring the previous round's `leverageIn` fix. |
| V4LE-147 | Fixed | `setTokenConfig` requires `twapTokenAlias.decimals() == token.decimals()` when the alias differs from the token (the raw-unit equivalence the TWAP leg assumes), and unverified TWAP reads re-check the alias against the cached exponent. No new config field. |
| V4LE-128 | Fixed | Same change as V4LE-95: the two-round effective-price refinement is replaced by the bisection on the exact quote, which converges to the balance root (reproduced the finding's numbers: 0.7424e18 vs the exact 0.7628e18 before the fix). |
