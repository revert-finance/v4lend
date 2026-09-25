# Verified Scan #1 follow-up fixes

These commits build on PR #40 at `0a8a81a976c5bc7b1a8d047af9fa845140b0b79e`.

## V4LE-57: isolate CI credentials from PR code

PR build/mock tests receive no RPC secret and disable FFI. Archive tests run only on `main`
(push or manual dispatch), in the `archive-rpc` environment, with the credential scoped to the
single test step. Missing credentials fail visibly instead of silently skipping fork coverage.

Before supplying a key, configure `archive-rpc` to permit deployments only from `main`, protect
that branch and add required environment reviewers as appropriate. Store `MAINNET_RPC_URL` only
in that environment: remove repository/inherited organization versions. A repository writer can
edit another workflow to reference repository secrets, so the environment boundary is essential.
Use a dedicated restricted, quota-limited RPC key. Do not use `pull_request_target` plus PR checkout.

V4LE-73 is an operational item: confirm historical key revocation/rotation in the provider's
activity log. No repository edit or history rewrite proves that the old key is invalid.

## V4LE-23: preserve the payout cap when the owner rejects surplus

Rejected owner proceeds are transferred to a dedicated vault-owned LiquidationEscrow. Only the
beneficiary can claim to an alternate address. These assets never enter vault cash/reserve accounting.
Failed claims preserve the credit; liquidator transfers match returned amounts and stay capped.

## V4LE-63: retain auction drips for a blocked owner

Uses the V4LE-23 escrow payout path. The dedicated regression adds a before-remove donation and
rejects transfers to the borrower, proving that even this newly credited surplus cannot increase
the liquidator's payment. No duplicate production path is needed.

## V4LE-77: governance-bounded collateral debt

Every increase checks an absolute per-token debt budget as well as the existing supply-relative
cap. Governance can set a token budget in asset units; zero selects the global debt limit times
the concentration factor (the full-limit sentinel inherits the global debt limit exactly).
Temporary deposits cannot increase either governance bound. Configure explicit budgets based on
the intended collateral exposure, especially when the global debt limit is much larger than TVL.
This is an admission bound: interest accrual, repayments, and lender withdrawals remain live.
