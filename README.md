# Revert v4lend

`v4lend` is a Uniswap v4-native lending and automation codebase.

It includes:
- a lending vault that accepts Uniswap v4 LP NFTs as collateral,
- an oracle for valuing LP positions with Chainlink-backed price checks,
- a Uniswap v4 hook for on-swap automation,
- standalone automators for operator-driven execution,
- transformers for vault-managed position changes,
- liquidation helpers and shared planning / swap utilities.

The system is designed around Uniswap v4 positions as the core primitive: positions can be valued, financed, transformed, and automatically managed.

## Main modules

### `V4Vault`
[`src/vault/V4Vault.sol`](src/vault/V4Vault.sol)

An ERC4626 lending vault for a single borrow/lend asset. Users deposit the vault asset to lend, and borrowers post Uniswap v4 LP positions as collateral.

Main responsibilities:
- ERC4626 deposits, mints, withdrawals, and redeems
- borrowing and repayment against LP collateral
- liquidation and reserve accounting
- transformer-based atomic collateral management
- hook allowlisting and collateral token configuration

### `V4Oracle`
[`src/oracle/V4Oracle.sol`](src/oracle/V4Oracle.sol)

Values Uniswap v4 LP positions using Chainlink feeds plus pool-price sanity checks.

Main responsibilities:
- price normalization into a common reference asset
- LP value and fee valuation
- pool price vs oracle price deviation checks
- L2 sequencer uptime guard support

### `RevertHook`
[`src/RevertHook.sol`](src/RevertHook.sol)

A Uniswap v4 hook that automates LP management from swap callbacks.

The public hook entrypoint lives at the top level, while the hook implementation is split under [`src/hook`](src/hook):
- views and admin/config logic
- callback flow
- trigger bookkeeping
- immediate execution logic
- execution delegates for position, auto-lend, and auto-leverage actions

Supported hook-side automation modes include:
- auto exit
- auto range
- auto compound
- auto lend
- auto leverage

### Standalone automators
[`src/automators`](src/automators)

Operator-driven contracts that execute one automation strategy at a time:
- [`AutoCompound.sol`](src/automators/AutoCompound.sol)
- [`AutoExit.sol`](src/automators/AutoExit.sol)
- [`AutoLend.sol`](src/automators/AutoLend.sol)
- [`AutoLeverage.sol`](src/automators/AutoLeverage.sol)
- [`AutoRange.sol`](src/automators/AutoRange.sol)

These are useful when automation should be triggered by operators or keepers instead of fully inside the hook path.

### Vault transformers
[`src/vault/transformers`](src/vault/transformers)

Atomic position-management helpers used directly or through `V4Vault.transform(...)`:
- [`V4Utils.sol`](src/vault/transformers/V4Utils.sol) for range changes, compounding, swaps, and mint/increase flows
- [`LeverageTransformer.sol`](src/vault/transformers/LeverageTransformer.sol) for leverage up/down and leveraged entry

### Liquidation helper
[`src/vault/liquidation/FlashloanLiquidator.sol`](src/vault/liquidation/FlashloanLiquidator.sol)

A helper that uses a Uniswap v3 flash loan to liquidate vault loans and route the seized collateral through swaps.

## Repository layout

```text
src/
  RevertHook.sol
  automators/
  hook/
  oracle/
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
  hook/
  oracle/
  shared/
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
- git submodules

### Clone and install

```sh
git clone --recurse-submodules <repo-url>
cd v4lend
```

If you already cloned the repo without submodules:

```sh
git submodule update --init --recursive
```

Build the contracts:

```sh
forge build
```

## Testing

A large part of the suite runs against a mainnet fork.

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
- [`test/hook/invariants`](test/hook/invariants)
- [`test/vault/invariants`](test/vault/invariants)

Check contract sizes:

```sh
forge build --sizes
```

## Deployment scripts

Deployment scripts live in [`script/`](script).

Main entrypoints:
- [`DeployBase.s.sol`](script/DeployBase.s.sol): full Base deployment for oracle, vault, hook, and related contracts
- [`DeployUnichain.s.sol`](script/DeployUnichain.s.sol): Unichain-focused deployment for the hook stack and oracle configuration
- [`DeployMainnet.s.sol`](script/DeployMainnet.s.sol): example mainnet deployment flow
- [`DeployV4Utils.s.sol`](script/DeployV4Utils.s.sol): standalone deployment for `V4Utils`

Example pattern:

```sh
forge script script/DeployBase.s.sol:DeployBase \
  --rpc-url <RPC_URL> \
  --chain-id <CHAIN_ID> \
  --broadcast
```

The hook deployment scripts mine a CREATE2 salt so the deployed hook address has the required Uniswap v4 hook flags.

## Configuration model

Token and feature support is configuration-dependent.

### Oracle configuration is required for
- vault loan valuation and health checks,
- hook value checks and oracle-distance guardrails,
- automator slippage checks when slippage is not disabled.

Relevant admin calls:
- `V4Oracle.setTokenConfig(...)`
- `V4Oracle.setMaxPoolPriceDifference(...)`
- `V4Oracle.setSequencerUptimeFeed(...)`

### Vault configuration is required for
- accepted collateral tokens,
- collateral factors and value limits,
- allowed position hooks,
- allowed transformer contracts.

Relevant admin calls:
- `V4Vault.setTokenConfig(...)`
- `V4Vault.setHookAllowList(...)`
- `V4Vault.setTransformer(...)`
- `V4Vault.setLimits(...)`

### Hook / automation configuration is required for
- protocol fee parameters,
- oracle-distance limits,
- minimum position value,
- per-position automation mode settings,
- auto-lend token-to-vault routing.

Relevant admin calls:
- `RevertHook.setGeneralConfig(...)`
- `RevertHook.setPositionConfig(...)`
- `RevertHook.setProtocolFeeBps(...)`
- `RevertHook.setProtocolFeeRecipient(...)`
- `RevertHook.setMaxTicksFromOracle(...)`
- `RevertHook.setMinPositionValueNative(...)`
- `RevertHook.setAutoLendVault(...)`

## Operational notes

- Long-tail pairs can still work in some automation flows when oracle-based slippage checks are intentionally disabled with `10000` bps and only `amountOutMin` is enforced.
- Vault lending and borrowing always depend on the oracle and token configuration being set correctly.
- The hook and the automators are intentionally separate execution models. The hook is for swap-time automation; the automators are for operator-triggered workflows.
- Delegatecall targets under [`src/hook`](src/hook) are execution helpers for the hook, not standalone products.

## Security model

This codebase is built around a few important trust assumptions:
- owners/admins are trusted to configure feeds, collateral factors, hook allowlists, and transformers correctly,
- oracle feeds are trusted subject to staleness and pool-difference checks,
- transformer contracts are privileged and must be audited before allowlisting,
- swap data for router-based operations is supplied off-chain and must be validated by the caller or operator.

The source contains additional contract-level security notes in:
- [`src/vault/V4Vault.sol`](src/vault/V4Vault.sol)
- [`src/oracle/V4Oracle.sol`](src/oracle/V4Oracle.sol)
- [`src/vault/transformers/V4Utils.sol`](src/vault/transformers/V4Utils.sol)
- [`src/vault/transformers/LeverageTransformer.sol`](src/vault/transformers/LeverageTransformer.sol)

## License

Most protocol contracts are released under `BUSL-1.1`. See individual file headers and [`LICENSE`](LICENSE) for details.
