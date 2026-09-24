# Audit Handoff

This document is a concise protocol handoff for external auditors reviewing `v4lend`.

Target snapshot:
- commit: re-pin at merge of `fix/audit-readiness-2026-09` (findings from `docs/audit-readiness-review.md` fixed on that branch)
- branch: `main`

Validation at this snapshot:
- `forge test`
- `forge build --sizes`

Both were green at handoff time.

## Scope

Primary audit scope is first-party Solidity under [`src/`](/Users/kalinbas/Code/v4lend/src).

Main protocol components:
- [`src/vault/V4Vault.sol`](/Users/kalinbas/Code/v4lend/src/vault/V4Vault.sol)
- [`src/oracle/V4Oracle.sol`](/Users/kalinbas/Code/v4lend/src/oracle/V4Oracle.sol)
- [`src/RevertHook.sol`](/Users/kalinbas/Code/v4lend/src/RevertHook.sol) and [`src/hook/`](/Users/kalinbas/Code/v4lend/src/hook)
- [`src/automators/`](/Users/kalinbas/Code/v4lend/src/automators)
- [`src/vault/transformers/`](/Users/kalinbas/Code/v4lend/src/vault/transformers)
- shared math / planning / swap helpers under [`src/shared/`](/Users/kalinbas/Code/v4lend/src/shared)

Supporting tests, scripts, and docs are meant as context, not as primary protocol scope.

## System Summary

`v4lend` is a Uniswap v4-native lending and automation system built around LP NFTs.

The system supports:
- using Uniswap v4 LP NFTs as collateral in a single-asset ERC4626 vault
- valuing LP positions with Chainlink-backed oracle checks
- swap-triggered automation through a v4 hook
- operator-driven standalone automators
- vault-managed transforms for compounding, range changes, and leverage flows

High-level modules:
- `V4Vault`: lenders deposit one asset; borrowers post LP NFTs as collateral and borrow the vault asset
- `V4Oracle`: values LP collateral and fees in a common reference asset
- `RevertHook`: on-swap automation for LP positions
- automators: operator-driven one-shot execution contracts
- transformers: helpers used directly or via `V4Vault.transform(...)`

## Actors And Trust Model

Privileged actors:
- vault owner
- hook owner
- protocol owner / deployment owner in scripts
- approved automator operators
- approved vault transformers

User actors:
- LP/NFT owners
- lenders
- borrowers
- liquidators

External dependencies:
- Uniswap v4 `PoolManager`
- Uniswap v4 `PositionManager`
- Chainlink-style feeds
- ERC4626 vaults for auto-lend
- swap routers / calldata targets used by automators and transformers

Important trust assumptions:
- oracle token configs are correct and maintained
- hook fee and route controllers are configured by the intended hook owner
- automator operators are trusted to submit the intended quoted execution calldata
- approved transformers are trusted as part of the vault’s privileged surface

## Main Contracts

### V4Vault

File:
- [`src/vault/V4Vault.sol`](/Users/kalinbas/Code/v4lend/src/vault/V4Vault.sol)

Purpose:
- ERC4626 vault for one lend/borrow asset
- LP NFT collateral management
- borrow / repay / liquidate
- reserve accounting
- transform orchestration

Notes:
- `V4Vault` intentionally holds lender funds, reserves, and collateral NFTs
- unlike automators and hook helpers, it is not expected to end operations with zero balances

### V4Oracle

File:
- [`src/oracle/V4Oracle.sol`](/Users/kalinbas/Code/v4lend/src/oracle/V4Oracle.sol)

Purpose:
- LP valuation
- fee valuation
- Chainlink normalization
- oracle-vs-pool deviation checks
- L2 sequencer guard integration

Boundary behavior:
- the feed-derived sqrt price in `_loadPositionState` only splits liquidity into token amounts, which saturates beyond the position's range, so it is clamped to `TickMath.MIN_SQRT_PRICE..MAX_SQRT_PRICE` (exact, no value change). A pool at the price boundary with an honest feed ratio slightly above it therefore stays valuable and liquidatable instead of reverting in a `uint160` cast
- `getPoolSqrtPriceX96` is consumed numerically (swap floors, oracle ticks) and reverts with `SqrtPriceOutOfRange` for ratios outside the sqrt-price domain rather than overflowing above or returning zero below

### RevertHook

Files:
- [`src/RevertHook.sol`](/Users/kalinbas/Code/v4lend/src/RevertHook.sol)
- [`src/hook/`](/Users/kalinbas/Code/v4lend/src/hook)

Purpose:
- swap-triggered LP automation
- auto exit
- auto range
- auto collect
- auto lend
- auto leverage

Important implementation detail:
- the deployed hook delegates execution into sidecar contracts
- storage layout compatibility matters across the shared hook/action state spine

See also:
- [`docs/hook-hierarchy.md`](/Users/kalinbas/Code/v4lend/docs/hook-hierarchy.md)

### Standalone Automators

Files:
- [`src/automators/AutoCollect.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoCollect.sol)
- [`src/automators/AutoExit.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoExit.sol)
- [`src/automators/AutoLend.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoLend.sol)
- [`src/automators/AutoLeverage.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoLeverage.sol)
- [`src/automators/AutoRange.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoRange.sol)
- shared base: [`src/automators/Automator.sol`](/Users/kalinbas/Code/v4lend/src/automators/Automator.sol)

Purpose:
- operator-driven execution outside the hook path
- one strategy per contract

Important implementation detail:
- protocol fees are sent directly to `protocolFeeRecipient`
- automators no longer retain protocol fees or use a withdrawer model
- `AutoLeverage` operators supply swap routing, so every execution must land the debt ratio inside the owner's configured band (`AutoLeverageLib.landsWithinTolerance`): leverage-up may not overshoot `target + rebalanceThresholdBps`, and deleverage may not stop above it. A strict ratio decrease is not enough on deleverage because liquidity removal is sized for the full planned repayment; the band check is what bounds an operator that swaps only part of the removed tokens or routes part of the swap output elsewhere. The hook's own auto-leverage keeps the looser `improvesTowardTarget` rule since its swaps go through protocol-managed routes
- `maxSwapSlippageBps == 10000` still disables the oracle output floor per swap; in that mode the band check is the only on-chain bound on how far an execution may fall short of the plan

### Controllers

Files:
- [`src/hook/HookOwnedControllerBase.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookOwnedControllerBase.sol)
- [`src/hook/HookFeeController.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookFeeController.sol)
- [`src/hook/HookRouteController.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookRouteController.sol)
- [`src/hook/HookAuctionController.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookAuctionController.sol)
- [`src/hook/HookLeaseController.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookLeaseController.sol)
- [`src/automators/AuctionArbExecutor.sol`](/Users/kalinbas/Code/v4lend/src/automators/AuctionArbExecutor.sol)

Purpose:
- keep fee governance, swap routing, and the fee-discount market out of `RevertHook` storage
- `HookFeeController`: LP protocol fee, auto-lend gain fee, per-mode hook swap fee, protocol fee recipient
- `HookRouteController`: protocol-managed single-pool routes per ordered token pair
- `HookAuctionController`: per-epoch English auction selling a discounted-LP-fee executor slot; the winning bid minus a protocol fee is dripped to in-range LPs through `PoolManager.donate` over the following epoch
- `HookLeaseController`: Harberger-lease alternative with the same hook-facing interface; one lessee self-assesses a price, pays per-second rent on it, can be bought out at that price, and rent minus a protocol fee is dripped to in-range LPs
- `AuctionArbExecutor`: owner-operated executor a bidder registers as the discount recipient; the controllers recognise the executor as the address that calls `PoolManager.swap` directly
- `HookAuctionController` pending bucket: value that could not be donated (zero in-range liquidity, failed donates, carried epochs) aggregates in `pendingDonation` and releases gradually. Each release is paced by `pendingReleasePerEpoch`, the largest single epoch's `totalDrip` that fed the bucket, over `epochLengthSeconds`, never by a fraction of the aggregate: a dust LP that appears after several zero-liquidity epochs can capture at most one epoch's slice per `minDripSeconds`, the same exposure as the live epoch drip. A bucket of N epochs therefore takes about N epochs to drain; `sweepPendingDonation` remains the wind-down path
- `HookLeaseController` pending bucket: same shape. Parked rent releases at `pendingReleasePerHorizon`, one `dripHorizonSeconds` of rent at the lease price the value accrued at (largest among contributions), over the horizon, so a dust LP after a long gap gets at most the rent the lease would have paid over its holding interval

Auth model:
- all controllers are administered through `hook.owner()`
- they do not keep an independent mutable owner
- a deployment wires exactly one of the auction or lease controller as the hook's immutable auction controller

Known design points auditors should read first:
- the discount applies only when `sender == executor`; hook-internal swaps never receive it
- drips `sync`/`settle` inside the caller's unlock, which assumes integrators sync immediately before paying
- controllers hold bidder escrow and prepaid rent; refunds are pull-based

### Hook Protocol Fee Deferral

`PositionManager` derives principal as `callerDelta - feesAccrued` and casts it to `uint128` on removes, so a hook delta on a fee-only `DECREASE_LIQUIDITY(0)` would revert. The hook therefore caps the LP protocol fee at what the operation can absorb and carries any shortfall per position (`_pendingProtocolFees`, `ProtocolFeeDeferred`), settling it on later removes with principal or on the hook's own fee collection. The logic lives in `RevertHookAutoLendActions` via delegatecall. Accepted leak: dust withdrawals after long fee-only collecting escape part of the carried fee, and a carried fee larger than the final principal is stranded on the burned token. A hook-driven deleverage whose partial removal is consumed entirely by the carried fee (no credit left in either currency) reverts with `RemovalConsumedByFees` and is rolled back by the caught vault transform, so a failed action can never commit lower collateral against unchanged debt; the owner settles the carried fee with a larger removal first.

### Remint Migration

When a vault transform replaces the collateral NFT, `V4Vault.transform` calls `migrateVaultPosition(oldTokenId, newTokenId)` on the allowlisted pool hook so trigger state, swap protection, and the carried protocol fee follow the loan. Automation follows only inside the same pool; a move to a pool this hook does not serve retires the old token's automation. Non-vault range changes through `V4Utils` do not migrate (`AUDIT-ACCEPTED-NONVAULT-REMINT-AUTOMATION-LOSS`).

## Accounting Model

This section is intentionally explicit because it is a recurring source of review comments.

### Whole-Balance Sweep Model

The following helper/execution layers intentionally use a whole-balance accounting model:
- hook action helpers in [`src/hook/RevertHookActionBase.sol`](/Users/kalinbas/Code/v4lend/src/hook/RevertHookActionBase.sol)
- vault transformer helpers in [`src/vault/transformers/V4Utils.sol`](/Users/kalinbas/Code/v4lend/src/vault/transformers/V4Utils.sol)
- leverage transformer logic in [`src/vault/transformers/LeverageTransformer.sol`](/Users/kalinbas/Code/v4lend/src/vault/transformers/LeverageTransformer.sol)
- automators in [`src/automators/`](/Users/kalinbas/Code/v4lend/src/automators)

Intended behavior:
- these execution helpers are expected to finish a successful call with no unintended leftover underlying balances
- they may read or sweep whole self-balances during execution
- any residual balance present at the start of a successful call is treated as part of the next sweep by design

This is intentional and not considered a bug by itself.

### Flat-After-Success Expectation

For successful executions:
- `RevertHook` helper paths are expected to end flat in the relevant pool tokens / ETH
- automators are expected to end flat in the relevant pool tokens / ETH
- transformer helper contracts are expected to end flat in the relevant working assets / ETH

Exception:
- [`src/automators/AutoLend.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoLend.sol) intentionally holds ERC4626 vault shares while a position is in its lent state
- “empty after execution” for `AutoLend` means no stray underlying tokens or ETH remain, not that ERC4626 share balances are always zero

### Components That Intentionally Hold Balances

These contracts are not expected to end flat:
- [`src/vault/V4Vault.sol`](/Users/kalinbas/Code/v4lend/src/vault/V4Vault.sol)
- ERC4626 lend vaults used by `AutoLend`

`V4Vault` intentionally holds:
- lender asset liquidity
- reserves
- loan state
- collateral NFTs

## Fee Model

### Hook Fees

Hook fee governance is in:
- [`src/hook/HookFeeController.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookFeeController.sol)

Fee types:
- LP protocol fee
- auto-lend gain fee
- hook swap fee

Hook swap-fee behavior:
- charged only on hook-internal swaps
- charged on actual output, not input
- only for swap-bearing modes
- routed directly to `protocolFeeRecipient`
- not retained in the hook

### Hook Swap Routing

Hook routing is protocol-managed through:
- [`src/hook/HookRouteController.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookRouteController.sol)

Current routing model:
- single-pool route per ordered `(tokenIn, tokenOut)`
- direction-specific routing
- fallback to the source pool when no route is configured
- no retry-on-source if a configured alternate route fails

Important constraint:
- dynamic-fee routes are intentionally rejected
- only static-fee routes are supported by the current planning logic

### Automator Fees

Automators:
- send protocol fees directly to `protocolFeeRecipient`
- do not retain protocol fees in-contract
- do not use a withdrawer escrow model anymore

Automators intentionally do not have a separate onchain swap-fee schedule like the hook because their swap paths are composed offchain through quoted calldata.

## Position / Config Model

### Hook

Per-position config still exists for:
- mode activation
- trigger configuration
- swap protection / price impact limits

Routing is no longer per-position.

Per-position route choice was removed in favor of protocol-level routing via `HookRouteController`.

### Vault

Vault operation depends on admin configuration for:
- token collateral factors and value caps
- hook allowlist
- transformer allowlist
- global and daily debt / lend limits
- minimum loan size

### Oracle

Oracle coverage is mandatory for:
- vault valuation / health checks
- hook oracle guardrails
- slippage checks when they are not explicitly disabled

## Important Non-Upgradeable / Deployment Notes

The current architecture is effectively redeploy-oriented rather than upgrade-in-place:
- hook controllers are standalone deployed contracts
- hook action sidecars store controller references as immutables
- the deployed hook stores sidecar addresses as immutables
- the hook address is part of hooked pool identity

Practical consequence:
- changing the live hook stack typically means a new hook deployment and new hooked pools, not just swapping one helper contract

## Intended Security Invariants

Auditors should expect the protocol to maintain these invariants:

Vault:
- only authorized borrowers can modify their loan state
- debt, collateral value, and liquidation conditions stay coherent
- reserve accounting never creates or destroys lender claims incorrectly

Hook:
- no unauthorized action execution
- trigger bookkeeping remains internally consistent
- one action failure should not corrupt unrelated trigger state
- delegatecall sidecars must remain storage-layout compatible with the shared state spine

Automators:
- only approved operators can execute
- protocol fees are sent directly to the recipient
- successful executions should not strand unintended underlying balances

Oracle:
- price normalization and feed selection stay coherent
- pool/oracle deviation checks gate unsafe valuations

## Tests Most Relevant To Audit

Core suites:
- [`test/vault/V4Vault.t.sol`](/Users/kalinbas/Code/v4lend/test/vault/V4Vault.t.sol)
- [`test/hook/RevertHook.t.sol`](/Users/kalinbas/Code/v4lend/test/hook/RevertHook.t.sol)
- [`test/hook/RevertHookNativeAutoLend.t.sol`](/Users/kalinbas/Code/v4lend/test/hook/RevertHookNativeAutoLend.t.sol)
- [`test/vault/V4VaultHook.t.sol`](/Users/kalinbas/Code/v4lend/test/vault/V4VaultHook.t.sol)
- [`test/automators/`](/Users/kalinbas/Code/v4lend/test/automators)
- [`test/oracle/V4OracleTest.t.sol`](/Users/kalinbas/Code/v4lend/test/oracle/V4OracleTest.t.sol)

Invariant suites:
- [`test/hook/invariants/`](/Users/kalinbas/Code/v4lend/test/hook/invariants)
- [`test/vault/invariants/`](/Users/kalinbas/Code/v4lend/test/vault/invariants)

Recent tests of note:
- automator contracts finishing empty after successful operations
- protocol fees sent directly to the fee recipient
- hook route-controller behavior
- hook swap-fee behavior
- third-token `AutoLeverage` deleverage sizing

## Suggested Audit Focus

Highest-value review areas:
- `V4Vault` borrow / repay / liquidation / transform flows (liquidation sizing uses full-precision `Math.mulDiv` for the penalty interpolation and the liquidity fraction, so positions whose debt and value each approach 2^144 stay computable and liquidatable)
- `RevertHook` delegatecall safety and trigger accounting
- `HookFeeController` and `HookRouteController` trust boundaries
- `AutoLeverage` leverage-down / third-token paths
- `V4Oracle` valuation assumptions and stale / deviating price behavior
- `LiquidityCalculator.calculateSamePool` input domain: a 100% total swap fee is rejected with `Invalid_Fee` (the analytic branches divide by `1 - fee`), matching `calculateSimple`
- shared swap helpers and native ETH handling

## Things We Intentionally Want Auditors To Know Up Front

- whole-balance accounting in hook/helpers/transformers/automators is intentional; where an operation compares its own amounts against a whole balance (the leverage transformer's added-amount checks) the subtraction saturates, so unsolicited dust pushed into a transformer can only end up with the recipient, never revert the operation
- `AutoLend` intentionally holds ERC4626 shares while a position is lent
- the vault records the token a transform started with in transient storage (`transformOriginTokenId`); the hook's `migrateVaultPosition` accepts only that token as the retired one, so borrower-chosen transform calldata cannot point the migration at another position of the same owner
- the hook's `_custodiedShares` reserve is honored on every balance the running action may spend, including the zero-share-deposit guard and the liquidity restore that follows it: a pool whose currency is another auto-lend vault's share token can never have another position's shares consumed by a rebuild
- hook swap routing is protocol-managed, not user-managed
- hook swap fees are direct-send, not retained
- dynamic-fee hook routes are intentionally unsupported
- controllers are governed by `hook.owner()`
- hook automation migrates across a position remint for vault-held positions (vault notification) and for direct range changes whose mint `hookData` carries the tagged old token id (`REMINT_MIGRATION_TAG`), checked against the minter's ERC721 authority over it; a direct range change without that opt-in intentionally leaves the replacement without automation (`AUDIT-ACCEPTED-NONVAULT-REMINT-AUTOMATION-LOSS`) ; a tagged mint that cannot be honoured reverts the mint, including while the pool's trigger cursor lags the live price (`TriggerCursorStale`)
- hook-managed swaps intentionally have no default `amountOutMin` floor. What bounds them is that no hook action starts while the pool price is outside the oracle window: `_afterSwap` dispatches no trigger while the live tick is outside `oracleTick +- maxTicksFromOracle`, re-checks after every executed action and requeues the rest of a tick when an action's own swap leaves the window (triggers stay armed for a later in-window swap); when an action's swap reverses the walk's direction while still inside the window, the entries left at the fired tick (requeued, or never popped under the per-swap cap) stay reachable because the cursor rests one bucket short of that tick rather than on it, and the continued walk consumes them in the same swap if the price is still past the tick; while dispatch is deferred the trigger cursor lags the live price and new trigger registrations revert with `TriggerCursorStale` so none can be placed where the resumed walk would miss it (operationally: `setPositionConfig` with triggers, and vault remints that carry automation, are unavailable in a pool while its price sits more than `maxTicksFromOracle` from the oracle, until a swap ends back inside the window); the hook's action entry points are reachable from a vault only during a transform the hook itself started; the permissionless `autoCollect` path and configured external routes are price-checked immediately before their swap. Per-position price limits remain available opt-in (`AUDIT-ACCEPTED-HOOK-SWAP-NO-SLIPPAGE-FLOOR` states the assumed parameters and worst case)
- the hook custodies ERC4626 shares for auto-lend positions and tracks them per share token (`_custodiedShares`); every whole-balance read that feeds a payout subtracts that amount, so a pool whose currency is a share token cannot pay another position's shares out. `AutoLend` (standalone) does the same with `custodiedShares` and additionally refuses to execute on share-token pools

