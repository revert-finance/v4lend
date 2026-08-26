# Deployment Checklist

This checklist captures deployment gates that should be completed before a production broadcast.

## Oracle

- Configure every lendable or collateralizable token with `V4Oracle.setTokenConfig(...)`.
- Use `CHAINLINK_TWAP_VERIFY` for normal production tokens.
- Use `TWAP_CHAINLINK_VERIFY`, `CHAINLINK`, or `TWAP` only as an explicit emergency or non-production decision.
- Set `twapSeconds = 30 minutes` for production TWAPs. `0` uses v3 pool spot price and should be limited to explicit emergency or non-production use.
- Use a Chainlink-compatible feed with a nonzero `maxFeedAge` and verify feed decimals.
- Use a Uniswap v3 TWAP pool that contains the oracle `referenceToken` and the configured token alias.
- Use WETH as `twapTokenAlias` for native ETH.
- Set source deviation to `200` unless the token needs a stricter bound.
- Keep v4 pool spot deviation at `MAX_POOL_PRICE_DIFFERENCE = 200` unless governance has an explicit runbook for a different value.
- Configure the L2 sequencer uptime feed where the chain requires it.
- On Unichain, Chainlink does not currently publish a sequencer uptime feed; deploy with `ALLOW_MISSING_SEQUENCER_FEED=true` only after explicitly accepting that launch risk.
- Run fork validation for `getPoolSqrtPriceX96`, `getValue`, borrowing, withdrawing collateral, and liquidation before enabling vault collateral.
- On Unichain, do not enable WBTC collateral until a nonzero-liquidity WBTC/USDC v3 pool with usable TWAP history is available.

## Vault

- Enable `V4Vault.setTokenConfig(...)` only after the token's oracle configuration is healthy.
- Confirm collateral factors, per-token value limits, global limits, daily limits, and minimum loan size match the launch risk parameters.
- Confirm every allowlisted hook and transformer is intended for the deployment chain.

## Hook And Automators

- Confirm `maxTicksFromOracle`, minimum position value, route controller entries, and fee controller parameters.
- Confirm automation routes have slippage protection and that any `10000` slippage bypass is intentional for that specific flow.
- Confirm `MAX_EXECUTIONS_PER_SWAP` is acceptable for the target chain gas budget and expected trigger density.

## Arbitrage Auction

- Auctioned pools must be initialized with `LPFeeLibrary.DYNAMIC_FEE_FLAG`; a dynamic-fee pool on the hook charges 0% LP fee until `HookAuctionController.configurePool(...)` mirrors the baseline, so configure before advertising the pool.
- Configure per-pool parameters from the backtest recommendations: Base ~4h epochs at 25-50% `feeDiscountPpm`, Arbitrum ~1d epochs at 50%; opening reserve around $25 in the auction currency; `minBidBumpPpm = 50_000` (5%); `minDripSeconds` small (~12-60s).
- The auction currency must be an ERC20 side of the pool (use `currency1` for native pools) and should be a reputable token - a currency that later blocks transfers from the controller pauses dripping (isolated, never blocking swaps or liquidations) until wind-down + `sweepPendingDonation`.
- Deploy scripts seed the executor denylist with the chain's UniversalRouter; extend it with every other shared router/aggregator with meaningful flow on the chain (`setExecutorDenied`). Bidders' executors must call `PoolManager.swap` directly.
- Fee changes (`setNormalLpFee`) only work while no bid is active or queued; plan them between epochs.
- Wind-down runbook: `setBiddingEnabled(pool, false)` stops new bids and refunds the queued bid; the running epoch is honored; after it ends and dripping finishes, `sweepPendingDonation` (credits the refund escrow) clears any stuck remainder and unblocks `configurePool`.
- Monitor `DonateFailed` (drip problems), `EpochMaterialized`/`EpochDripped` (auction health), and bid activity per epoch; run a floor bidder via `AuctionArbExecutor` on flagship pools at launch.
- Mechanism choice: `HookLeaseController` (continuous Harberger lease) is a drop-in alternative implementing the same `IHookAuctionController` interface. The hook takes exactly ONE controller at deploy time - decide the mechanism per chain BEFORE mining the hook address (the controller address is a constructor arg and part of the CREATE2 mining). The deploy scripts wire the epoch auction by default; to use the lease instead, deploy `HookLeaseController` at the sidecar nonce and pass it to the hook. Lease-specific wind-down: `setLeasingEnabled(pool, false)`, wait for rent insolvency (or lessee exit), `evictLease` if needed, then `sweepPendingDonation`.

## Emergency Runbook

- Set `emergencyAdmin` to the intended operational signer or multisig.
- Document who may switch a token into `CHAINLINK`, `TWAP`, or `TWAP_CHAINLINK_VERIFY`, why, and how it is switched back.
- Do not leave production collateral in a single-source mode after the source incident is resolved.
