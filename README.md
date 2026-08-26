# Revert v4lend

`v4lend` is a Uniswap v4-native lending and automation codebase.

It includes:

- a lending vault that accepts Uniswap v4 LP NFTs as collateral,
- a two-source oracle for valuing LP positions with Chainlink-compatible feeds and Uniswap v3 TWAP verification,
- a Uniswap v4 hook for on-swap automation,
- standalone automators for operator-driven execution,
- transformers for vault-managed position changes,
- liquidation helpers and shared planning / swap utilities.

The system is designed around Uniswap v4 positions as the core primitive: positions can be valued, financed, transformed, and automatically managed.

## Hookathon demo

This repo includes a working end-to-end hook demo for judges in [script/demo](script/demo).

Quick start:

```sh
git clone https://github.com/revert-finance/v4lend.git
cd v4lend
forge build
forge test
forge script script/demo/UnichainForkHookathonE2E.s.sol:UnichainForkHookathonE2E -vv
```

The fork-only end-to-end demo in [UnichainForkHookathonE2E.s.sol](script/demo/UnichainForkHookathonE2E.s.sol) does the following:

- deploys the full local demo stack on top of a Unichain fork,
- deploys and wires the oracle, hook, vault, and transformer contracts,
- initializes a hooked demo pool,
- mints one wide ambient liquidity position so the pool stays swappable,
- mints one narrow hooked position and moves it into the vault with zero debt,
- configures `MODE_AUTO_RANGE | MODE_AUTO_LEVERAGE | MODE_AUTO_EXIT`,
- verifies that configuration itself immediately triggers `AUTO_LEVERAGE` from zero debt,
- pushes price upward until `AUTO_RANGE` remints the position into a new range,
- then swaps price back down until the reminted position is fully unwound by `AUTO_EXIT`.

Notes:

- this script is a local fork demo, not a broadcast deployment flow,
- it uses mock ERC20s and demo-only single-source Chainlink-style feeds for the demo pool while still using live Unichain v4 infrastructure,
- a successful run logs the immediate config-time leverage rebalance from zero debt, then the `AUTO_RANGE` remint, and finally the lower-side `AUTO_EXIT` unwind.

### Partner integrations

This project was built for use with Unichain.

## Main modules

### `V4Vault`

[src/vault/V4Vault.sol](src/vault/V4Vault.sol)

An ERC4626 lending vault for a single borrow/lend asset. Users deposit the vault asset to lend, and borrowers post Uniswap v4 LP positions as collateral.

Main responsibilities:

- ERC4626 deposits, mints, withdrawals, and redeems
- borrowing and repayment against LP collateral
- liquidation and reserve accounting
- transformer-based atomic collateral management
- hook allowlisting and collateral token configuration

### `V4Oracle`

[src/oracle/V4Oracle.sol](src/oracle/V4Oracle.sol)

Values Uniswap v4 LP positions using Chainlink-compatible feeds plus Uniswap v3 TWAP verification. The normal production mode is `CHAINLINK_TWAP_VERIFY`: Chainlink-compatible prices are used for valuation, Uniswap v3 TWAPs verify that source, and the live v4 pool spot price is still checked against the derived oracle price.

Main responsibilities:

- price normalization into a common reference asset
- Chainlink-compatible and Uniswap v3 TWAP source-deviation checks
- LP value and fee valuation
- pool price vs oracle price deviation checks
- emergency oracle source-mode switching
- L2 sequencer uptime guard support

### `RevertHook`

[src/RevertHook.sol](src/RevertHook.sol)

A Uniswap v4 hook that automates LP management from swap callbacks.

The public hook entrypoint lives at the top level, while the hook implementation is split under [src/hook](src/hook):

- views and admin/config logic
- callback flow
- trigger bookkeeping
- immediate execution logic
- execution delegates for position, auto-lend, and auto-leverage actions

Supported hook-side automation modes include:

- auto exit
- auto range
- auto collect
- auto lend
- auto leverage

### Arbitrage auction (`HookAuctionController`)

[src/hook/HookAuctionController.sol](src/hook/HookAuctionController.sol)

A per-pool auction that converts arbitrage value (LVR) into LP income on dynamic-fee pools using `RevertHook`:

- Searchers bid during epoch N (English auction, timestamp-based epochs) for a discounted-LP-fee executor slot in epoch N + 1.
- The winner is the contract that calls `PoolManager.swap` directly (its registered executor); it pays `normalLpFee` reduced by `feeDiscountPpm`, everyone else pays the baseline.
- The winning bid, minus a protocol fee, is dripped to in-range LPs via `PoolManager.donate()`, vested linearly over the epoch with throttled anti-JIT release.
- Outbid and refunded bids are escrowed pull-based (`claimRefund`). A bid is consumed once its epoch starts: the discount right is self-serve under lazy sync (the winner's first swap promotes and discounts), so a no-show winner's bid drips to LPs deterministically - never dependent on third-party touches. Only wind-down refunds a queued, not-yet-started bid.
- Per-pool wind-down via `setBiddingEnabled(false)`: new bids stop, the running epoch is honored, vested proceeds finish dripping.
- Staged launch: `configurePool` with `biddingEnabled: false` mirrors the baseline fee without opening bidding - a dynamic-fee pool otherwise trades at the v4 default of 0% LP fee until configured. Create the pool, configure it staged (ideally in the same script), and flip `setBiddingEnabled(true)` when the bidder ecosystem is ready. (`HookLeaseController` supports the same via `leasingEnabled: false`.)
- Bidding is permissionless; an owner-managed executor denylist (`setExecutorDenied`) blocks shared routers so a bidder cannot hand the discount to all router traffic.

Auctioned pools must be created with `LPFeeLibrary.DYNAMIC_FEE_FLAG`. The hook calls the controller directly from `beforeSwap` / `beforeAddLiquidity` / `beforeRemoveLiquidity`; the controller's hook entrypoints are non-reverting by construction, and a misbehaving auction currency (blacklist, fee-on-transfer) only pauses dripping - it cannot block swaps, liquidity changes, or liquidations.

### Harberger lease (`HookLeaseController`) - alternative mechanism

[src/hook/HookLeaseController.sol](src/hook/HookLeaseController.sol)

An alternative to the epoch auction that sells the same discounted-fee executor slot as a continuous Harberger lease instead of per-epoch bids:

- One lessee holds the slot at a time. They self-assess a price (escrowed as a deposit) and pay rent on it continuously at a per-second tax rate; the rent, minus a protocol fee, drips to in-range LPs with the same throttled anti-JIT release.
- Anyone can take the slot at any time by buying it out at the self-assessed price plus `minBuyoutBumpPpm`; the old lessee's deposit and unused rent go to pull-refund escrow. Self-assessing low invites a cheap buyout, self-assessing high costs more rent - the classic Harberger honesty incentive.
- The discount is active only while the prepaid rent covers the current time; when it runs out the discount stops automatically (no eviction needed for correctness).
- Per-pool wind-down via `setLeasingEnabled(false)`: no new leases, buyouts, rent top-ups or price raises; the running lease is honored while its prepaid rent lasts, and `evictLease` can clear a rent-insolvent lease whose lessee never exits.

Both controllers implement the same hook-facing `IHookAuctionController` interface with the same safety construction (non-reverting entrypoints, isolated donate leg, exact-transfer checks, executor denylist). A deployment chooses the mechanism by wiring ONE of the two as the hook's immutable auction controller; the deploy scripts wire the epoch auction by default.

### Standalone automators

[src/automators](src/automators)

Operator-driven contracts that execute one automation strategy at a time:

- [AutoCollect.sol](src/automators/AutoCollect.sol)
- [AutoExit.sol](src/automators/AutoExit.sol)
- [AutoLend.sol](src/automators/AutoLend.sol)
- [AutoLeverage.sol](src/automators/AutoLeverage.sol)
- [AutoRange.sol](src/automators/AutoRange.sol)
- [AuctionArbExecutor.sol](src/automators/AuctionArbExecutor.sol) - an owner-operated arbitrage router intended to be registered as an auction winner's executor

These are useful when automation should be triggered by operators or keepers instead of fully inside the hook path.

### Vault transformers

[src/vault/transformers](src/vault/transformers)

Atomic position-management helpers used directly or through `V4Vault.transform(...)`:

- [V4Utils.sol](src/vault/transformers/V4Utils.sol) for range changes, compounding, swaps, and mint/increase flows
- [LeverageTransformer.sol](src/vault/transformers/LeverageTransformer.sol) for leverage up/down and leveraged entry

### Liquidation helper

[src/vault/liquidation/FlashloanLiquidator.sol](src/vault/liquidation/FlashloanLiquidator.sol)

A helper that uses a flash loan to liquidate vault loans and route the seized collateral through swaps.

## Repository layout

```text
src/
  RevertHook.sol
  automators/
  hook/
    interfaces/
    lib/
  oracle/
    interfaces/
  shared/
    math/
    planning/
    swap/
  vault/
    interfaces/
    liquidation/
    transformers/

test/
  automators/
    utils/
  hook/
    invariants/
    lib/
  oracle/
  shared/
    math/
    planning/
  utils/
    libraries/
  vault/
    invariants/
    support/
    transformers/
```

A few useful conventions in the current tree:

- `src/hook/` contains hook internals; only `RevertHook.sol` stays at top level.
- `src/shared/` contains reusable math, planning, and swap helpers.
- `src/vault/` contains the lending system, its interfaces, transformers, and liquidation helpers.
- the test tree mirrors the source tree closely.

## Development setup

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- git

### Clone and install

```sh
git clone https://github.com/revert-finance/v4lend.git
cd v4lend
forge build
```

On a fresh clone, the first `forge build` will automatically fetch the missing dependencies.

If you want to prefetch them yourself instead:

```sh
git submodule update --init --recursive
forge build
```

## Testing

A large part of the suite runs against a mainnet fork.

Fork tests read `MAINNET_RPC_URL` and fall back to `https://ethereum-rpc.publicnode.com`:

```sh
MAINNET_RPC_URL=<your archive RPC URL> forge test
```

Run the full suite:

```sh
forge test
```

Run with traces:

```sh
forge test -vvv
```

Useful targeted suites:

```sh
forge test --match-path test/hook/RevertHook.t.sol
forge test --match-path test/vault/V4Vault.t.sol
forge test --match-path test/oracle/V4OracleTest.t.sol
forge test --match-path test/automators/AutoRange.t.sol
```

Invariant-heavy areas also have dedicated suites under:

- [test/hook/invariants](test/hook/invariants)
- [test/vault/invariants](test/vault/invariants)

Check contract sizes:

```sh
forge build --sizes
```

## Deployment scripts

Deployment scripts live in [script/](script).

Main entrypoints:

- [DeployBase.s.sol](script/DeployBase.s.sol): full Base deployment for oracle, vault, hook, and related contracts
- [DeployArbitrum.s.sol](script/DeployArbitrum.s.sol): full Arbitrum deployment for oracle, vault, hook, and related contracts
- [DeployUnichain.s.sol](script/DeployUnichain.s.sol): full Unichain deployment for oracle, vault, hook, and related contracts
- [DeployMainnet.s.sol](script/DeployMainnet.s.sol): full Ethereum mainnet deployment for oracle, vault, hook, and related contracts
- [DeployV4Utils.s.sol](script/DeployV4Utils.s.sol): standalone deployment for `V4Utils`

Example pattern:

```sh
forge script script/DeployBase.s.sol:DeployBase \
  --rpc-url <RPC_URL> \
  --chain-id <CHAIN_ID> \
  --broadcast
```

The hook deployment scripts mine a CREATE2 salt so the deployed hook address has the required Uniswap v4 hook flags.

Production deployment scripts configure two-source oracle mode for lendable/collateralizable tokens. Unichain uses USDC-referenced v3 TWAP pools for its USDC vault deployment and skips WBTC collateral in production until a suitable WBTC/USDC TWAP pool exists. `ALLOW_SINGLE_SOURCE_ORACLE=true` is reserved for explicit non-production or emergency deployments.

See [docs/deployment-checklist.md](docs/deployment-checklist.md) for the deployment checklist.

## Configuration model

Token and feature support is configuration-dependent.

### Oracle configuration is required for

- vault loan valuation and health checks,
- hook value checks and oracle-distance guardrails,
- automator slippage checks when slippage is not disabled.

Default production oracle config:

- `mode`: `CHAINLINK_TWAP_VERIFY`
- `twapSeconds`: `30 minutes` for production TWAPs; `0` uses the v3 pool spot price, matching the old V3Oracle behavior
- source deviation: `200` basis points unless the asset needs a stricter limit
- v4 pool spot deviation: `MAX_POOL_PRICE_DIFFERENCE = 200`

A token is lendable/collateralizable only when both oracle sources are configured and healthy. Native ETH is priced through a WETH TWAP alias. `TWAP_CHAINLINK_VERIFY` is the inverted two-source mode (TWAP valuation verified against the Chainlink-compatible feed); `CHAINLINK` and `TWAP` are temporary single-source emergency modes, not normal deployment modes.

Relevant admin calls:

- `V4Oracle.setTokenConfig(...)`
- `V4Oracle.setOracleMode(...)`
- `V4Oracle.setEmergencyAdmin(...)`
- `V4Oracle.setMaxPoolPriceDifference(...)`
- `V4Oracle.setSequencerUptimeFeed(...)`

### Vault configuration is required for

- accepted collateral tokens,
- collateral factors and value limits,
- allowed position hooks,
- allowed transformer contracts.

Only positions whose hook is explicitly allowlisted can be deposited as collateral. Non-hooked positions require allowlisting `address(0)`; the production deployment scripts allowlist only the `RevertHook`, so plain (non-hooked) v4 positions are not accepted as collateral unless an admin additionally allowlists `address(0)`.

Relevant admin calls:

- `V4Vault.setTokenConfig(...)`
- `V4Vault.setHookAllowList(...)`
- `V4Vault.setTransformer(...)`
- `V4Vault.setLimits(...)`

### Hook / automation configuration is required for

- protocol fee controller parameters,
- protocol-managed swap routes,
- oracle-distance limits,
- minimum position value,
- per-position automation mode settings,
- per-position swap protection settings,
- auto-lend token-to-vault routing,
- per-pool arbitrage auctions (epoch length, winner discount, reserve, bump, protocol fee),
- the auction executor denylist.

Relevant admin calls:

- `HookFeeController.setProtocolFeeRecipient(...)`
- `HookFeeController.setLpFeeBps(...)`
- `HookFeeController.setAutoLendFeeBps(...)`
- `HookFeeController.setDefaultSwapFeeBps(...)`
- `HookFeeController.setPoolOverrideSwapFeeBps(...)`
- `HookRouteController.setRoute(...)`
- `HookRouteController.clearRoute(...)`
- `RevertHook.setSwapProtectionConfig(...)`
- `RevertHook.setPositionConfig(...)`
- `RevertHook.setMaxTicksFromOracle(...)`
- `RevertHook.setMinPositionValueNative(...)`
- `RevertHook.setAutoLendVault(...)`
- `HookAuctionController.configurePool(...)`
- `HookAuctionController.setBiddingEnabled(...)`
- `HookAuctionController.setNormalLpFee(...)` (only while no bid is outstanding)
- `HookAuctionController.setExecutorDenied(...)`
- `HookAuctionController.sweepPendingDonation(...)` (rescue, only after wind-down)

## Operational notes

- `RevertHook` should be treated as an oracle-enabled-pool system. In practice, active hook automation depends on oracle pricing for position valuation and oracle-bounded trigger processing.
- Long-tail pairs can still work in some automation flows when oracle-based slippage checks are intentionally disabled with `10000` bps and only `amountOutMin` is enforced.
- That long-tail mode applies to selected standalone automator flows, not to the hook in the same way.
- Vault lending and borrowing always depend on the oracle and token configuration being set correctly.
- Production vault collateral should not be enabled until the token has a healthy Chainlink-compatible feed, a healthy Uniswap v3 TWAP pool against the oracle reference token, and passing fork validation.
- The hook and the automators are intentionally separate execution models. The hook is for swap-time automation; the automators are for operator-triggered workflows.
- Delegatecall targets under [src/hook](src/hook) are execution helpers for the hook, not standalone products.
- Auction executors must call `PoolManager.swap` directly. Registering a shared router as an executor would give every trader routing through it the discounted fee; deploy scripts seed the denylist with each chain's UniversalRouter, and operators should extend it with other shared routers or aggregators used on the chain.
- The auction's drip distribution is point-in-time to in-range liquidity (like v4 swap fees), with throttled release bounding JIT capture; it is not time-weighted per position.

## Security model

This codebase is built around a few important trust assumptions:

- owners/admins are trusted to configure feeds, TWAP pools, emergency modes, collateral factors, hook allowlists, and transformers correctly,
- oracle sources are trusted subject to staleness, source-deviation, and v4 pool spot-deviation checks,
- transformer contracts are privileged and must be audited before allowlisting,
- swap data for router-based operations is supplied off-chain and must be validated by the caller or operator.

The source contains additional contract-level security notes in:

- [src/vault/V4Vault.sol](src/vault/V4Vault.sol)
- [src/oracle/V4Oracle.sol](src/oracle/V4Oracle.sol)
- [src/vault/transformers/V4Utils.sol](src/vault/transformers/V4Utils.sol)
- [src/vault/transformers/LeverageTransformer.sol](src/vault/transformers/LeverageTransformer.sol)

## License

Most protocol contracts are released under `BUSL-1.1`. See individual file headers and [LICENSE](LICENSE) for details.
