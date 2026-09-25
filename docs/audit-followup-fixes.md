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

## V4LE-1: restrict executor admission

Auction and lease registration require an owner-admitted deployed code hash, in addition to the
denylist. An arbitrary bidder cannot admit a new public forwarder. Governance must review caller
authorization and admit only non-upgradeable executors with an appropriately restricted caller
policy (for example AuctionArbExecutor). Admission removal blocks new registrations; purchased
epochs/leases retain their agreed bounded terms. Code hashes do not prove authorization policy.

## V4LE-51: validate automation when admitting debt

Debt-bearing health checks ask the allowlisted hook to validate compatibility with the vault asset,
including at the end of transforms. Configuring AUTO_EXIT before transferring an NFT to a third-asset
vault can no longer bypass validation. Zero-debt exits remain available and native/WETH matches
remain supported. Every allowlisted hook must implement validateVaultPosition as well as migration.

## V4LE-21: size same-pool swaps after automation fees

The same-pool planner now receives the effective per-mode output fee. For nonzero fees it solves
the balance condition using net output and the ending price from a bounded tick-walking quote,
including pool LP/protocol fees. Zero-fee plans retain the analytic path. The AUTO_RANGE regression
checks the actual remint leftovers at the maximum supported automation fee.

## V4LE-37: source-specific post-restart risk admission

After the common sequencer grace period, new borrowing and collateral withdrawals additionally
require post-restart Chainlink rounds (including the reference denominator) and a complete fresh
TWAP window for every used TWAP source. Governance can add per-token recovery delays. Transforms
that worsen debt per unit of position value use the same guard; deleveraging that improves
that ratio, repayments, and liquidations retain the ordinary oracle availability rules. L1 is a no-op.

## V4LE-71: observable, bounded leverage recovery

A failed or zero-sized leverage action sets autoLeverageNeedsAttention. The owner can repair the
loan (for example repay the small excess) and submit setPositionConfig again for a single explicit
retry/rearm. Success clears the marker; another failure leaves it set. No rounding-up liquidation
or automatic swap-loop retry is introduced. The regression exercises failure, manual repair, and
successful rearming at the current tick.

## V4LE-72: settle fees before withdrawals

Liquidity operations cannot create unpaid protocol-fee receivables. A removal that cannot settle
the whole fee reverts. INCREASE_LIQUIDITY(0), with explicit max inputs and currency settlement,
can collect net fees or pay an existing liability. Vault, hook, Swapper/V4Utils, and leverage-down
paths prepend this collection before removing principal in the same unlock. Direct PositionManager
clients must use that batch when a DECREASE cannot absorb the fee; DECREASE(0) alone is intentionally
unsupported when a protocol fee is due. No governance write-off or voluntary-only debt is relied on.
