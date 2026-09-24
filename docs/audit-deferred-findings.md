# Cantina Scan #1 — findings not fixed in code, and decisions to review

Companion to `docs/audit-handoff.md` for the fix branch `fix/external-audit-2026-09` (2026-09-24).
Everything else in the scan (51 of 56 findings) has a commit on that branch with a regression test.

## Policy items handed back to the team

- **V4LE-1 — permissionless custom executors turn an auction win into pool-wide discounted routing.**
  Bidding is intentionally permissionless and the executor denylist is documented as defense in depth.
  Options: (a) require executors to be contracts registered by the owner (allowlist, opt-in already
  exists but is off), (b) bind the discount to `tx.origin == bidder` or to an executor that exposes an
  enforceable caller policy (the shipped `AuctionArbExecutor` is owner-gated; the controller could
  require executors to implement `IAuctionExecutor.authorizedCaller()` and check it), (c) accept the
  economic self-limitation stated in the code. Decision needed before mainnet launch parameters.
- **V4LE-57 — `MAINNET_RPC_URL` secret reaches pull-request Foundry runs.** Move the fork suite to a
  workflow that only runs on `push` to protected branches or with `pull_request_target` gated on a
  label, keep `ffi = true` out of the PR job (or run PR jobs with `--no-ffi`), and scope the key to a
  read-only archive endpoint. Repository/CI change, not contract code.
- **V4LE-73 — an Alchemy key is recoverable from git history.** Rotate/revoke the key at the provider;
  history rewriting is optional once the key is dead.
- **V4LE-77 / V4LE-87 — per-token collateral concentration cap is checked only at debt increase,
  against the momentary lender supply, and never against accrued interest.** The cap is a risk limit,
  not a solvency invariant; the two auditor-suggested tightenings both have costs: re-checking on
  lender withdrawals lets borrowers block withdrawals, and re-checking on interest accrual makes
  routine operations revert. Proposal: (1) evaluate the cap against `min(currentSupply, supply at the
  start of the UTC day)` (reuse the daily-limit snapshot machinery) so a same-day transient deposit
  cannot expand it, and (2) treat the cap as a soft limit for accrued interest (no new borrows on the
  token while over the cap, existing debt untouched). Wants a product decision on the numbers.

## Deferred with a concrete proposal (agent reports)

- **V4LE-55 — reference-token Q96 shortcut.** Under the current config semantics the recommended check
  compares Q96 with Q96 (the reference token's TWAP alias is itself). Proposal: when the reference
  token has a two-source mode, run the two-source path of its configured verification counterpart
  (WETH in the deploy scripts) and discard the result, or keep `maxFeedAge` tight on the reference feed
  and document the single-source trust.
- **V4LE-37 — post-restart oracle freshness.** Requiring a feed round newer than
  `sequencerStartedAt` freezes borrowing for up to the feed heartbeat (25h on Arbitrum) after every
  restart. Proposal: per-token owner flag `requirePostRestartRound` for short-heartbeat feeds and/or a
  restart grace of `max(600, twapSeconds)`.
- **V4LE-11 — oracle values gross LP fees while the hook skims a protocol fee.** Needs a hook quote:
  hook view `quoteProtocolFee(tokenId, fees0, fees1)` plus an oracle-side registry of fee quoters, or
  the simpler vault-side haircut `feeValue * (10000 - maxLpFeeBps) / 10000` for allowlisted hooks.
- **V4LE-72 — remint outside the hook's scope abandons the carried protocol fee.** The fee is an
  amount owed, not funds held, and an out-of-scope remint gives the hook no operation to settle it on.
  Proposal: owner-callable `settlePendingProtocolFee(tokenId)` pulling the owed currencies from the
  owner (about 50 hook bytes as a passthrough), and refusing `migrateVaultPosition` out of scope while
  a fee is pending.
- **V4LE-21 (same-pool half) — planner ignores the hook output fee.** The external-route half is fixed.
  Proposal: `outputFeePips` parameter on `calculateSamePool`, folded into the analytic solvers'
  output terms; `_buildSwapPlan` already has the mode and fee controller at hand.

## Semantic choices made while fixing, worth a reviewer's eye

- V4LE-18: both `msg.sender` and `recipient` equal to the loan owner are refused; a second address of
  the borrower remains possible (inherent to the subsidy design).
- V4LE-65: a zero-effect `repay` returns `(0, 0)` and no longer emits `Repay`.
- V4LE-23/63: the liquidator's payout is capped at the oracle-priced liquidation value; an ERC20
  remainder the owner cannot receive falls back to the liquidator for liveness.
- V4LE-22: prepaid lease runway is bounded by `MAX_PREPAID_RUNWAY_SECONDS = 365 days` (one constant).
- V4LE-85: on exact equality at a range bound the quadratic still runs when the held amount is
  nonzero; only `a == 0` / `c == 0` return a no-swap plan.
- V4LE-71: zero-sized leverage adjustments now report failure (trigger not re-centred) rather than
  rounding the removal up.
- V4LE-9: `REMINT_MIGRATION_TAG` is duplicated in `V4Utils`; centralising it in `shared/Constants.sol`
  is a follow-up.
