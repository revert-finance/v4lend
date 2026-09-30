# Cantina Scan #1 — remaining decisions after PR #40 follow-up

The implementation and regression details are in [audit-followup-fixes.md](audit-followup-fixes.md).
The earlier statement that 51 of 56 findings were fixed overstated the original PR's coverage.

## Implemented follow-ups

V4LE-1, 11, 21, 23, 37, 51, 57, 63, 71, 72, and 77 have individual follow-up commits.
V4LE-23 and V4LE-63 share the liquidation-surplus escrow; V4LE-63 has its own donation regression.
Fee settlement, net valuation, source recovery, and debt admission must be deployed together.

## Operational action

- **V4LE-73:** confirm provider-side revocation/rotation of the historically published RPC key.
  A repository edit cannot prove revocation. No request was made using the historical key.
- **V4LE-57:** CI runs no fork suites and holds no RPC credential (the `main`-only fork job was
  removed in PR #43; fork suites run locally). Keep repository/inherited organization RPC secrets
  removed, and run the fork suites locally before merging changes to the forked code paths.

## Disputed or accepted policy findings

- **V4LE-18 / V4LE-91 (Scan #2):** an address check cannot prevent a borrower using another address
  or an intermediary contract for liquidation. The reserve cost of a reserve-backed liquidation is
  `debt - liquidatorCost` whoever the liquidator is, so a borrower liquidating their own loan through an
  intermediary costs reserves exactly what an independent liquidator would; the check only decides who
  collects the incentive, it is not a solvency boundary. The subsidy stays as designed. The repository's
  own `FlashloanLiquidator` mirrors the vault's refusal (V4LE-97) so the documented helper is not the
  bypass; do not describe the address check as Sybil resistance.
- **V4LE-55:** the reference-token Q96 identity is correct. The tested denominator skew cancels when
  numerator and quote share the same Chainlink denominator; independent TWAP verification rejects it.
  Treat missing fallback coverage as a deployment configuration question, not an identity-price bug.
- **V4LE-87:** debt can drift above an admission cap as interest accrues. New borrowing is checked;
  blocking interest accrual or lender withdrawals is not the proposed fix. V4LE-77 adds independent
  governance debt budgets for active admission without changing this policy.
