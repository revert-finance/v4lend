# V4Utils Test Suite

This directory contains comprehensive tests for the V4Utils contract's `execute()` function.

## Test Files

### 1. `V4UtilsExecute.t.sol` - Mainnet Fork Tests
- **Purpose**: Tests V4Utils functionality by forking Ethereum mainnet
- **Features**: 
  - Uses real mainnet state at block 19,000,000
  - Tests with realistic token addresses (WETH, USDC, etc.)
  - Comprehensive test coverage for all `execute()` scenarios

### 2. `V4UtilsSimple.t.sol` - Local Tests  
- **Purpose**: Tests V4Utils functionality with local deployments
- **Features**:
  - Uses mock tokens for faster testing
  - No external dependencies
  - Good for development and CI/CD

## Setup Instructions

### For Mainnet Fork Tests (`V4UtilsExecute.t.sol`)

1. **Set up environment variables**:
   ```bash
   export MAINNET_RPC_URL="https://eth-mainnet.alchemyapi.io/v2/YOUR_API_KEY"
   # or
   export MAINNET_RPC_URL="https://mainnet.infura.io/v3/YOUR_PROJECT_ID"
   ```

2. **Run the tests**:
   ```bash
   forge test --match-contract V4UtilsExecuteTest -vvv
   ```

### For Local Tests (`V4UtilsSimple.t.sol`)

1. **Run the tests** (no setup required):
   ```bash
   forge test --match-contract V4UtilsSimpleTest -vvv
   ```

## Test Coverage

Both test suites cover the following scenarios:

### 1. `COMPOUND_FEES` Action
- Collects accumulated fees from a position
- Swaps fees to a target token
- Adds the swapped tokens back as liquidity
- Tests fee compounding functionality

### 2. `CHANGE_RANGE` Action  
- Removes liquidity from current position
- Creates a new position with different tick range
- Handles token swaps if needed
- Tests position range modification

### 3. `WITHDRAW_AND_COLLECT_AND_SWAP` Action
- Removes all liquidity from position
- Collects all accumulated fees
- Swaps tokens to a single target token
- Tests complete position withdrawal

### 4. Additional Functions
- `swap()` - Direct token swapping
- `swapAndMint()` - Swap tokens and create new position
- `executeWithPermit()` - Execute with EIP712 signature

## Test Structure

Each test follows this pattern:
1. **Setup**: Create test position with liquidity
2. **Execute**: Call `execute()` with specific instructions
3. **Verify**: Check that operations completed successfully
4. **Log**: Output relevant information for debugging

## Key Features Tested

- ✅ Position creation and management
- ✅ Liquidity removal and fee collection  
- ✅ Token swapping integration
- ✅ Range modification
- ✅ NFT transfer handling
- ✅ Error conditions and edge cases
- ✅ Gas optimization
- ✅ Integration with V4 PositionManager

## Running Specific Tests

```bash
# Test only COMPOUND_FEES functionality
forge test --match-test testExecuteCompoundFees -vvv

# Test only CHANGE_RANGE functionality  
forge test --match-test testExecuteChangeRange -vvv

# Test only WITHDRAW_AND_COLLECT_AND_SWAP functionality
forge test --match-test testExecuteWithdrawAndCollectAndSwap -vvv

# Test swap functions
forge test --match-test testSwap -vvv
```

## Debugging

Use `-vvv` flag for detailed output:
```bash
forge test --match-contract V4UtilsSimpleTest -vvv
```

This will show:
- Contract deployment addresses
- Token balances before/after operations
- Transaction details
- Console.log outputs

## Notes

- **Mainnet Fork Tests**: Require RPC access and may be slower
- **Local Tests**: Faster but use mock tokens
- **Gas Costs**: Tests include gas usage monitoring
- **Error Handling**: Tests cover various error conditions
- **Integration**: Tests verify integration with V4 core contracts

## Troubleshooting

### Common Issues

1. **RPC URL Error**: Make sure `MAINNET_RPC_URL` is set correctly
2. **Out of Gas**: Increase gas limit in foundry.toml
3. **Import Errors**: Ensure all dependencies are installed
4. **Compilation Errors**: Check Solidity version compatibility

### Getting Help

- Check Foundry documentation: https://book.getfoundry.sh/
- Review V4 documentation: https://docs.uniswap.org/sdk/v4/
- Check test logs for specific error messages
