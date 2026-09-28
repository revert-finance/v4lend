# Deployment Checklist

This checklist captures deployment gates that should be completed before a production broadcast.

## Oracle

- Configure every lendable or collateralizable token with `V4Oracle.setTokenConfig(...)`.
- Use `CHAINLINK_TWAP_VERIFY` for normal production tokens.
- Use `TWAP_CHAINLINK_VERIFY`, `CHAINLINK`, or `TWAP` only as an explicit emergency or non-production decision.
- Set `twapSeconds = 30 minutes` for production TWAPs. `0` uses v3 pool spot price and should be limited to explicit emergency or non-production use.
- Use a Chainlink-compatible feed with a nonzero `maxFeedAge` and verify feed decimals.
- Verify each Chainlink (or RedStone) feed's heartbeat on the provider's feed page and set that token's `maxFeedAge >= heartbeat + margin` (25 hours for the usual 86400 s stablecoin feeds, 2 hours for a 3600 s feed). A too-low value makes borrow, transform AND liquidate revert on every valuation as soon as the price has not moved enough to publish a new round. Each deploy script carries per-feed `*_MAX_FEED_AGE` constants with the verified heartbeat, deviation and source in a comment (verified 2026-09-22: Chainlink reference data directory for Arbitrum and mainnet, RedStone's `unichainMultiFeed.json` relayer manifest for Unichain). Providers change these, so re-check them before every broadcast. Chainlink's machine-readable list is `https://reference-data-directory.vercel.app/feeds-<network>.json`; RedStone's per-feed `updateTriggers` live in the relayer manifests of `redstone-finance/redstone-oracles-monorepo`.
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
- Hook upgrade: de-allowlist the old hook (`setHookAllowList(old, false)` and `setTransformer(old, false)`) and every old transformer it replaces (old V4Utils, LeverageTransformer, ...) in the same batch that allowlists the new ones. The hook stack is redeploy-oriented: a new hook address means new hooked pools, and a remint on a still-allowlisted old hook reverts mid-transform because it does not implement `migrateVaultPosition`. `DeployBaseHookUpgrade` requires `OLD_HOOK` / `OLD_V4UTILS` and retires them itself; a manual upgrade must do the same.
- Only `DeployBase` / `DeployBaseHookUpgrade` configure `HookRouteController` routes (ETH/USDC and WETH/USDC). Arbitrum, Mainnet and Unichain deploy an empty route controller, so hook action swaps there fall back to the hooked pool itself. Configure routes with `script/configure-route.sh` once a deep hookless pool exists, or accept the hooked-pool fallback explicitly per chain.

## Arbitrage Auction

- Auctioned pools must be initialized with `LPFeeLibrary.DYNAMIC_FEE_FLAG`; a dynamic-fee pool on the hook charges 0% LP fee until `HookAuctionController.configurePool(...)` mirrors the baseline, so configure before advertising the pool.
- Recommended launch sequence per flagship pool: initialize the pool and `configurePool` with `biddingEnabled: false` in the same script (the pool then trades at `normalLpFee` like a normal pool, no bids accepted), and `setBiddingEnabled(true)` once the floor bidder / bidder ecosystem is ready. The lease controller stages identically via `leasingEnabled: false`.
- Configure per-pool parameters from the backtest recommendations: Base ~4h epochs at 25-50% `feeDiscountPpm`, Arbitrum ~1d epochs at 50%; opening reserve around $25 in the auction currency; `minBidBumpPpm = 50_000` (5%); `minDripSeconds` small (~12-60s).
- The auction currency must be an ERC20 side of the pool (use `currency1` for native pools) and should be a reputable token - a currency that later blocks transfers from the controller pauses dripping (isolated, never blocking swaps or liquidations) until wind-down + `sweepPendingDonation`.
- Deploy scripts seed the executor denylist with the chain's UniversalRouter; extend it with every other shared router/aggregator with meaningful flow on the chain (`setExecutorDenied`). Bidders' executors must call `PoolManager.swap` directly.
- Fee changes (`setNormalLpFee`) only work while no bid is active or queued; plan them between epochs.
- Wind-down runbook: `setBiddingEnabled(pool, false)` stops new bids and refunds the queued bid; the running epoch is honored; after it ends and dripping finishes, `sweepPendingDonation` (credits the refund escrow) clears any stuck remainder and unblocks `configurePool`.
- Monitor `DonateFailed` (drip problems), `EpochMaterialized`/`EpochDripped` (auction health), and bid activity per epoch; run a floor bidder via `AuctionArbExecutor` on flagship pools at launch.
- Mechanism choice: `HookLeaseController` (continuous Harberger lease) is a drop-in alternative implementing the same `IHookAuctionController` interface. The hook takes exactly ONE controller at deploy time - decide the mechanism per chain BEFORE mining the hook address (the controller address is a constructor arg and part of the CREATE2 mining). The deploy scripts wire the epoch auction by default; to use the lease instead, deploy `HookLeaseController` at the sidecar nonce and pass it to the hook. Lease-specific wind-down: `setLeasingEnabled(pool, false)`, wait for rent insolvency (or lessee exit), `evictLease` if needed, then `sweepPendingDonation`.
- Lease pricing: `minRentDepositSeconds` is a nonrefundable minimum rent commitment at the entry price, not merely a refundable deposit requirement. Confirm the tax rate and minimum duration together. Early exits, buyouts, and evictions settle any unpaid commitment before refunds; normal elapsed rent counts toward it. `minimumRentRemaining(poolId)` exposes the outstanding commitment included in the reported rent balance.

## Emergency Runbook

- Set `emergencyAdmin` to the intended operational signer or multisig. No deploy script does this; it is a manual post-deploy call on both `V4Vault.setEmergencyAdmin` and `V4Oracle.setEmergencyAdmin`.
- Ownership handoff is manual. No deploy script transfers ownership: the deployer EOA owns the oracle, vault, hook, controllers and transformers, and is the fee recipient. `V4Vault` and `V4Oracle` are `Ownable2Step`, so the handoff is `transferOwnership(newOwner)` from the deployer followed by `acceptOwnership()` from the new owner; check the other contracts' ownership model before the same handoff. Do this in the launch batch, not later.
- Document who may switch a token into `CHAINLINK`, `TWAP`, or `TWAP_CHAINLINK_VERIFY`, why, and how it is switched back.
- Do not leave production collateral in a single-source mode after the source incident is resolved.

## Known Deployments

Addresses recorded in `broadcast/` (`transactions[].contractAddress` for `contractName == "V4Utils"`). `DeployV4Utils*` only deploys the contract; `setVault` / `setTransformer` wiring is a separate owner call.

| Chain | Contract | Address | Source |
| --- | --- | --- | --- |
| Base (8453) | V4Utils | `0xb23f54B586a5C02F350d37A696894FdBbA7C1067` | `broadcast/DeployV4UtilsBase.s.sol/8453/run-latest.json` |
| Arbitrum One (42161) | V4Utils | `0xb541D37B6F328EF93908f80e5983B8F989A5FCe8` | `broadcast/DeployV4UtilsArbitrum.s.sol/42161/run-latest.json` |
| Base (8453) | V4Oracle (existing) | `0x94C9bDeDB05358A98d95520205879d438419AB41` | `DeployBaseHookUpgrade.DEFAULT_ORACLE` |
| Base (8453) | V4Vault (existing, USDC) | `0xaf98803a1f43afC14335360e089F6B12947924ED` | `DeployBaseHookUpgrade.DEFAULT_VAULT` |

The full-stack `Deploy{Base,Arbitrum,Mainnet,Unichain}` broadcasts in the repo are dry runs only.

## PR #40 follow-up deployment requirements

- Deploy the updated vault, oracle, hook, fee controller, and action helpers as a compatible set.
  Existing immutable vaults/oracles cannot receive these fixes through a hook-only upgrade. The
  Base hook-upgrade script checks for the new API generation before broadcasting.
- Register each hooked pool's trusted fee quoter on the oracle before admitting its collateral.
- Review and admit only restricted, non-upgradeable executors before enabling bids/leases.
- Set explicit token debt budgets where the global debt limit times concentration factor exceeds
  the intended exposure. Deposits do not change these governance budgets.
- Direct PositionManager clients must support fee-paying INCREASE(0) collection before removal.
- Configure archive-rpc environment restrictions and verify historical key revocation with the provider.
