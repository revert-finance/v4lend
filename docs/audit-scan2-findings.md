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

## Informational

| ID | Disposition | Notes |
|---|---|---|
| V4LE-151 | Rejected (operational) | Already tracked as V4LE-73: provider-side revocation of the historical key is an operational action; no repository change can prove it. CI no longer uses any RPC credential (PR #43). |
