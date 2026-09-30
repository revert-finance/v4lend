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
| V4LE-98 | see oracle section | |

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

## Low

| ID | Disposition | Notes |
|---|---|---|
| V4LE-100 | Fixed | Same root cause and fix as V4LE-102. |

## Informational

| ID | Disposition | Notes |
|---|---|---|
| V4LE-151 | Rejected (operational) | Already tracked as V4LE-73: provider-side revocation of the historical key is an operational action; no repository change can prove it. CI no longer uses any RPC credential (PR #43). |
| V4LE-110 | Fixed | `leverageUp` resolves the native alias for a WETH-asset vault on a native pool (borrowed WETH unwrapped into the pool side, native leg wrapped for repayment in `leverageDown`) instead of treating the borrow as a third token, mirroring the previous round's `leverageIn` fix. |
