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
- **V4LE-57 deployment:** configure the archive-rpc environment to allow protected main only and
  store its dedicated credential there; repository/inherited organization RPC secrets must be removed.

## Disputed or accepted policy findings

- **V4LE-18:** an address check cannot prevent a borrower using another address for liquidation.
  The verified mechanism does not itself prove a profitable attack. Retain or reconsider the subsidy
  and self-liquidation policy explicitly; do not describe the address check as Sybil resistance.
- **V4LE-55:** the reference-token Q96 identity is correct. The tested denominator skew cancels when
  numerator and quote share the same Chainlink denominator; independent TWAP verification rejects it.
  Treat missing fallback coverage as a deployment configuration question, not an identity-price bug.
- **V4LE-87:** debt can drift above an admission cap as interest accrues. New borrowing is checked;
  blocking interest accrual or lender withdrawals is not the proposed fix. V4LE-77 adds independent
  governance debt budgets for active admission without changing this policy.
