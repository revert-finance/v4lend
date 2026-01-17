# Pre-Audit Deployment Plan for Base

## Overview

Prepare Revert V4Utils contracts for final audit and Base deployment. This includes:
1. Base deployment script (full ecosystem)
2. Base fork tests (critical use cases)
3. Comprehensive audit preparation (NatSpec, security comments, invariant tests)

---

## Phase 1: Base Deployment Script ✅

### File: `script/DeployBase.s.sol`

**Base Network Addresses:**
```solidity
// Uniswap V4 (from docs.uniswap.org/contracts/v4/deployments)
PoolManager: 0x498581ff718922c3f8e6a244956af099b2652b2b
PositionManager: 0x7c5f5a4bbd8fd63184577525326123b519429bdc
Universal Router: 0x6ff5693b99212da76ad316178a184ab56d299b43
Permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3

// 0x Protocol
AllowanceHolder: 0x0000000000001fF3684f28c67538d4D072C22734

// Tokens
WETH: 0x4200000000000000000000000000000000000006 (OP Stack standard)
USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (native USDC)

// Chainlink Feeds
CHAINLINK_ETH_USD: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
CHAINLINK_USDC_USD: 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B
SEQUENCER_UPTIME_FEED: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433
```

**Deployment Order:**
1. `InterestRateModel` - Compound V2-style rates
2. `LiquidityCalculator` - Stateless math library
3. `V4Oracle` - Configure with Chainlink feeds + sequencer uptime
4. `RevertHookFunctions` - Delegatecall target 1
5. `RevertHookFunctions2` - Delegatecall target 2
6. `RevertHook` - CREATE2 with salt mining for valid hook address
7. `V4Vault` - USDC vault with token configs, limits, reserves
8. `FlashloanLiquidator` - Liquidation utility
9. `V4Utils` - Register with vault as transformer
10. `LeverageTransformer` - Register with vault as transformer
11. Configure integrations (hook allowlist, auto-lend vault)

**Run Command:**
```bash
forge script script/DeployBase.s.sol:DeployBase \
  --chain-id 8453 --rpc-url <BASE_RPC> --broadcast --verify
```

---

## Phase 2: Base Fork Tests ✅

### Files Created:
- `test/integration/base/V4BaseForkTestBase.sol` - Base fork test base class
- `test/integration/base/V4BaseVaultHook.t.sol` - Hook integration tests
- `test/integration/base/V4BaseVault.t.sol` - Vault tests
- `test/integration/base/V4BaseOracle.t.sol` - Oracle tests

### Test Cases:

**Auto-Compound Fees** (`V4BaseVaultHook.t.sol`)
- Create position in hooked pool
- Configure for auto-compound
- Generate fees via swaps
- Verify fees are compounded into liquidity

**Auto-Range Rebalancing** (`V4BaseVaultHook.t.sol`)
- Create position with auto-range config
- Move price out of range
- Verify position is rebalanced to new range

**Vault Operations** (`V4BaseVault.t.sol`)
- Deposit and withdraw
- Create loan with collateral
- Borrow against collateral
- Repay loan
- Retrieve position after full repayment

**Position Valuation** (`V4BaseOracle.t.sol`)
- Get position value from oracle
- Verify price consistency
- Test sequencer uptime feed
- Validate feed age checks

**Run Command:**
```bash
BASE_RPC_URL=<your-base-rpc> forge test --match-path "test/integration/base/*" -vvv
```

---

## Phase 3: Invariant Tests ✅

### Files Created:
- `test/invariants/V4VaultInvariants.t.sol` - Vault invariants
- `test/invariants/RevertHookInvariants.t.sol` - Hook invariants

### V4Vault Invariants:
- [x] Debt exchange rate only increases
- [x] Lend exchange rate only increases
- [x] Share/asset consistency
- [x] Deposit/withdraw reversibility
- [x] Multiple deposits proportional
- [x] Reserve factor bounded
- [x] Collateral factors bounded
- [x] Global limits respected
- [x] Preview matches actual operations

### RevertHook Invariants:
- [x] Protocol fee BPS bounded (≤ 10000)
- [x] Position mode valid enum
- [x] Owner-only admin functions
- [x] Hook permissions correct
- [x] Auto-leverage target bounded

**Run Command:**
```bash
forge test --match-path "test/invariants/*" -vvv
```

---

## Phase 4: Audit Preparation ✅

### 4.1 NatSpec Documentation ✅

**Completed - Core contracts have comprehensive NatSpec:**
- [x] `src/V4Vault.sol` - Contract-level security docs + function docs
- [x] `src/RevertHook.sol` - Contract-level security docs + function docs
- [x] `src/V4Oracle.sol` - Contract-level security docs + function docs

**Security Documentation Added:**
- Contract-level `@dev` security considerations
- `@custom:security-contact` for all core contracts
- Critical function security comments

### 4.2 Security Comments ✅

**Security comments added to critical functions:**
- [x] `V4Vault.transform()` - Transformer trust model, reentrancy protection
- [x] `V4Vault.liquidate()` - Liquidation penalty mechanics, bad debt socialization
- [x] `V4Vault.borrow()` - Safety buffer, min loan size, daily limits
- [x] `V4Oracle` contract - Price manipulation protection, sequencer uptime
- [x] `RevertHook` contract - Hook trigger validation, delegatecall pattern

---

## Phase 5: Pre-Deployment Checklist

### Code Quality
- [ ] Remove all `TODO` comments or address them
- [ ] Remove commented-out code
- [ ] Ensure consistent error messages
- [ ] Verify all events are emitted correctly

### Security
- [ ] Review all external calls for reentrancy
- [ ] Check for integer overflow/underflow (Solidity 0.8+)
- [ ] Verify access control on all admin functions
- [ ] Test emergency pause/unpause functionality
- [ ] Review oracle manipulation resistance

### Configuration
- [ ] Document all configuration parameters and their valid ranges
- [ ] Verify default values are safe
- [ ] Test edge cases for configuration limits

### Gas Optimization
- [ ] Review gas usage of frequently called functions
- [ ] Consider calldata vs memory for large structs
- [ ] Review loop bounds

### Static Analysis
- [ ] Run Slither and fix high/medium findings
- [ ] Run Mythril for symbolic execution
- [ ] Consider Certora formal verification for critical invariants

---

## File Summary

### New Files Created:
1. ✅ `script/DeployBase.s.sol` - Base deployment script
2. ✅ `test/integration/base/V4BaseForkTestBase.sol` - Fork test base
3. ✅ `test/integration/base/V4BaseVaultHook.t.sol` - Hook tests
4. ✅ `test/integration/base/V4BaseVault.t.sol` - Vault tests
5. ✅ `test/integration/base/V4BaseOracle.t.sol` - Oracle tests
6. ✅ `test/invariants/V4VaultInvariants.t.sol` - Vault invariants
7. ✅ `test/invariants/RevertHookInvariants.t.sol` - Hook invariants

### Files to Modify (NatSpec/Security Comments):
1. `src/V4Vault.sol`
2. `src/RevertHook.sol`
3. `src/RevertHookConfig.sol`
4. `src/RevertHookFunctions.sol`
5. `src/RevertHookFunctions2.sol`
6. `src/V4Oracle.sol`
7. `src/transformers/V4Utils.sol`
8. `src/transformers/LeverageTransformer.sol`
9. `src/InterestRateModel.sol`
10. `src/utils/Swapper.sol`

---

## Execution Order

1. ✅ **Create Base deployment script** - Done
2. ⏳ **Deploy to Base** - Run script when ready
3. ✅ **Create Base fork tests** - Done
4. ⏳ **Run fork tests** - After deployment
5. ✅ **Add NatSpec documentation** - Done (core contracts)
6. ✅ **Add security comments** - Done (critical functions)
7. ✅ **Create invariant tests** - Done
8. ⏳ **Final review** - Pre-deployment checklist

---

## Notes

- Fork tests use `deal()` to fund test accounts, avoiding dependency on whale accounts
- Base has a sequencer uptime feed that is configured in V4Oracle for L2 safety
- The deployment script uses CREATE2 for RevertHook to ensure correct hook flags
- Run `forge build` to verify compilation before deployment
