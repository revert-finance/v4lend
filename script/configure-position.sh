#!/bin/bash

# Configure a position on RevertHook for Unichain
# Usage: ./script/configure-position.sh

set -e

# ==================== Configuration ====================

# Unichain RPC
RPC_URL="https://mainnet.unichain.org"

# RevertHook contract address (update after deployment)
REVERT_HOOK="0xfcafc56b43a0956ba8fe8d94f3a787cb53121d43"

# Position to configure
TOKEN_ID="2461350"

# ==================== Position Configuration ====================
# PositionConfig struct:
#   PositionMode mode;              // enum: 0=NONE, 1=AUTO_COMPOUND_ONLY, 2=AUTO_RANGE, 3=AUTO_EXIT, 4=AUTO_EXIT_AND_AUTO_RANGE, 5=AUTO_LEND, 6=AUTO_LEVERAGE
#   AutoCompoundMode autoCompoundMode; // enum: 0=NONE, 1=AUTO_COMPOUND, 2=HARVEST_TOKEN_0, 3=HARVEST_TOKEN_1
#   bool autoExitIsRelative;        // if true, auto exit ticks are relative to position limits
#   int24 autoExitTickLower;        // lower tick for auto-exit trigger
#   int24 autoExitTickUpper;        // upper tick for auto-exit trigger
#   int24 autoRangeLowerLimit;      // lower limit for auto-range
#   int24 autoRangeUpperLimit;      // upper limit for auto-range
#   int24 autoRangeLowerDelta;      // delta below current tick for new range
#   int24 autoRangeUpperDelta;      // delta above current tick for new range
#   int24 autoLendToleranceTick;    // tolerance for auto-lend
#   uint16 autoLeverageTargetBps;   // target leverage ratio in bps (0-10000)

# Example: AUTO_COMPOUND_ONLY mode
MODE="1"                           # AUTO_COMPOUND_ONLY
AUTO_COMPOUND_MODE="1"             # AUTO_COMPOUND
AUTO_EXIT_IS_RELATIVE="false"
AUTO_EXIT_TICK_LOWER="-8388608"    # type(int24).min - disabled
AUTO_EXIT_TICK_UPPER="8388607"     # type(int24).max - disabled
AUTO_RANGE_LOWER_LIMIT="-8388608"  # type(int24).min - disabled
AUTO_RANGE_UPPER_LIMIT="8388607"   # type(int24).max - disabled
AUTO_RANGE_LOWER_DELTA="0"
AUTO_RANGE_UPPER_DELTA="0"
AUTO_LEND_TOLERANCE_TICK="0"
AUTO_LEVERAGE_TARGET_BPS="0"

# ==================== General Configuration ====================
# GeneralConfig for swap pool settings (optional, set to 0 to use same pool)
SWAP_POOL_FEE="0"                  # 0 = use same pool
SWAP_POOL_TICK_SPACING="0"         # 0 = use same pool
SWAP_POOL_HOOKS="0x0000000000000000000000000000000000000000"
MAX_PRICE_IMPACT_BPS_0="100"       # 1% max slippage for token0->token1 swaps
MAX_PRICE_IMPACT_BPS_1="100"       # 1% max slippage for token1->token0 swaps

# ==================== Helper Functions ====================

print_header() {
    echo ""
    echo "=============================================="
    echo "$1"
    echo "=============================================="
}

# ==================== Main Script ====================

print_header "RevertHook Position Configuration"

echo "RPC URL: $RPC_URL"
echo "RevertHook: $REVERT_HOOK"
echo "Token ID: $TOKEN_ID"
echo ""

# Check if PRIVATE_KEY is set
if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY environment variable not set"
    echo "Usage: PRIVATE_KEY=0x... ./script/configure-position.sh"
    exit 1
fi

print_header "Step 1: Set General Config (optional)"

echo "Setting general config for token $TOKEN_ID..."
echo "  Swap Pool Fee: $SWAP_POOL_FEE"
echo "  Swap Pool Tick Spacing: $SWAP_POOL_TICK_SPACING"
echo "  Max Price Impact (token0->token1): ${MAX_PRICE_IMPACT_BPS_0} bps"
echo "  Max Price Impact (token1->token0): ${MAX_PRICE_IMPACT_BPS_1} bps"

# setGeneralConfig(uint256 tokenId, uint24 swapPoolFee, int24 swapPoolTickSpacing, address swapPoolHooks, uint32 maxPriceImpactBps0, uint32 maxPriceImpactBps1)
cast send "$REVERT_HOOK" \
    "setGeneralConfig(uint256,uint24,int24,address,uint32,uint32)" \
    "$TOKEN_ID" \
    "$SWAP_POOL_FEE" \
    "$SWAP_POOL_TICK_SPACING" \
    "$SWAP_POOL_HOOKS" \
    "$MAX_PRICE_IMPACT_BPS_0" \
    "$MAX_PRICE_IMPACT_BPS_1" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY"

echo "General config set successfully!"

print_header "Step 2: Set Position Config"

echo "Setting position config for token $TOKEN_ID..."
echo "  Mode: $MODE (1=AUTO_COMPOUND_ONLY)"
echo "  Auto Compound Mode: $AUTO_COMPOUND_MODE (1=AUTO_COMPOUND)"

# setPositionConfig(uint256 tokenId, (uint8,uint8,bool,int24,int24,int24,int24,int24,int24,int24,uint16) positionConfig)
# The struct is passed as a tuple
cast send "$REVERT_HOOK" \
    "setPositionConfig(uint256,(uint8,uint8,bool,int24,int24,int24,int24,int24,int24,int24,uint16))" \
    "$TOKEN_ID" \
    "($MODE,$AUTO_COMPOUND_MODE,$AUTO_EXIT_IS_RELATIVE,$AUTO_EXIT_TICK_LOWER,$AUTO_EXIT_TICK_UPPER,$AUTO_RANGE_LOWER_LIMIT,$AUTO_RANGE_UPPER_LIMIT,$AUTO_RANGE_LOWER_DELTA,$AUTO_RANGE_UPPER_DELTA,$AUTO_LEND_TOLERANCE_TICK,$AUTO_LEVERAGE_TARGET_BPS)" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY"

echo "Position config set successfully!"

print_header "Step 3: Verify Configuration"

echo "Reading position config..."
cast call "$REVERT_HOOK" \
    "positionConfigs(uint256)" \
    "$TOKEN_ID" \
    --rpc-url "$RPC_URL"

print_header "Configuration Complete!"

echo "Position $TOKEN_ID is now configured for auto-compounding on RevertHook"
echo ""
