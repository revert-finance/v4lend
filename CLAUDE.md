# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Revert V4Utils - Smart contracts for Uniswap V4 LP position management, including:
- **V4Vault**: ERC4626 lending vault using Uniswap V4 positions as collateral
- **RevertHook**: Uniswap V4 hook enabling auto-compounding, auto-exit, auto-range, and auto-lend features
- **V4Utils**: Position management utilities (change range, compound fees, withdraw and swap)
- **V4Oracle**: Position valuation using Chainlink price feeds

## Build & Test Commands

```bash
# Install dependencies
forge install

# Build
forge build

# Run all tests (uses Ethereum Mainnet fork)
forge test

# Run specific test file
forge test --match-path test/RevertHook.t.sol

# Run specific test function
forge test --match-test testAutoCompound

# Run with verbosity for debugging
forge test -vvvv

# Gas snapshot
forge snapshot
```

## Architecture

### Core Contracts

**RevertHook** (`src/RevertHook.sol`) - Uniswap V4 hook with:
- Inherits from `RevertHookConfig` (configuration) and `BaseHook` (OpenZeppelin)
- Hook permissions: `afterInitialize`, `beforeAddLiquidity`, `afterAddLiquidity`, `afterRemoveLiquidity`, `afterSwap`
- Position modes: `AUTO_COMPOUND_ONLY`, `AUTO_RANGE`, `AUTO_EXIT`, `AUTO_EXIT_AND_AUTO_RANGE`, `AUTO_LEND`
- Uses `TickLinkedList` for efficient trigger tracking by tick

**RevertHookConfig** (`src/RevertHookConfig.sol`) - Configuration base class:
- `PositionConfig`: mode, auto-exit ticks, auto-range deltas, auto-lend tolerance
- `GeneralConfig`: swap pool settings, max price impact
- Manages trigger lists for upper/lower tick boundaries

**V4Vault** (`src/V4Vault.sol`) - ERC4626 lending vault:
- Single asset lending (e.g., USDC) with V4 positions as collateral
- Implements `transform()` pattern for atomic position modifications
- Interest rate model with debt/lend exchange rates
- Liquidation with configurable penalty (2-10%)

**V4Oracle** (`src/V4Oracle.sol`) - Position valuation:
- Uses Chainlink feeds for price discovery
- Validates pool prices against oracle prices (`maxPoolPriceDifference`)
- Calculates position value including uncollected fees

**LiquidityCalculator** (`src/LiquidityCalculator.sol`) - Math library:
- Calculates optimal swap amounts for double-sided liquidity deposits
- `calculateSimple()`: for swaps in different pool
- `calculateSamePool()`: simulates tick crossing for same-pool swaps

### Transformer Pattern

The vault uses a transformer pattern where whitelisted contracts can modify positions:
1. Call `transform(tokenId, transformer, data)` on vault
2. Vault grants NFT approval to transformer
3. Transformer executes encoded function call
4. Vault verifies collateral health after transformation

### Key Libraries

- `TickLinkedList` (`src/lib/TickLinkedList.sol`): Sorted linked list for tick-based triggers
- `Swapper` (`src/utils/Swapper.sol`): Universal Router / 0x integration for swaps

## Testing

Tests use Foundry with mainnet forking:
- `test/utils/BaseTest.sol`: Base test setup with deployers
- `test/utils/Deployers.sol`: Deploys V4 infrastructure
- Integration tests in `test/integration/` use `V4ForkTestBase.sol`

Solidity version: 0.8.30
EVM version: Cancun

## Deployment

Example deployment command:
```bash
forge script script/DeployV4Utils.s.sol:DeployV4Utils \
  --sig "run(address,address,address,address)" \
  "<positionManager>" "<universalRouter>" "<zeroxAllowanceHolder>" "<permit2>" \
  --chain-id <chainId> --rpc-url <rpc> --broadcast --verify
```