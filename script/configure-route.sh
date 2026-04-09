#!/bin/bash

# Configure a protocol-managed swap route on HookRouteController
# Usage: PRIVATE_KEY=0x... ./script/configure-route.sh

set -e

# ==================== Configuration ====================

RPC_URL="${RPC_URL:-https://mainnet.unichain.org}"
HOOK_ROUTE_CONTROLLER="${HOOK_ROUTE_CONTROLLER:-0x0000000000000000000000000000000000000000}"

# Ordered route pair. Configure both directions if needed.
TOKEN_IN="${TOKEN_IN:-0x0000000000000000000000000000000000000000}"
TOKEN_OUT="${TOKEN_OUT:-0x0000000000000000000000000000000000000000}"

# Routed pool config
FEE="${FEE:-3000}"
TICK_SPACING="${TICK_SPACING:-60}"
HOOKS="${HOOKS:-0x0000000000000000000000000000000000000000}"

# Set CLEAR_ROUTE=true to delete the route instead of setting it.
CLEAR_ROUTE="${CLEAR_ROUTE:-false}"

print_header() {
    echo ""
    echo "=============================================="
    echo "$1"
    echo "=============================================="
}

print_header "HookRouteController Configuration"

echo "RPC URL: $RPC_URL"
echo "HookRouteController: $HOOK_ROUTE_CONTROLLER"
echo "Token In: $TOKEN_IN"
echo "Token Out: $TOKEN_OUT"
echo ""

if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY environment variable not set"
    echo "Usage: PRIVATE_KEY=0x... ./script/configure-route.sh"
    exit 1
fi

if [ "$HOOK_ROUTE_CONTROLLER" = "0x0000000000000000000000000000000000000000" ]; then
    echo "Error: HOOK_ROUTE_CONTROLLER is not configured"
    exit 1
fi

if [ "$TOKEN_IN" = "$TOKEN_OUT" ]; then
    echo "Error: TOKEN_IN and TOKEN_OUT must differ"
    exit 1
fi

if [ "$CLEAR_ROUTE" = "true" ]; then
    print_header "Clearing Route"

    cast send "$HOOK_ROUTE_CONTROLLER" \
        "clearRoute(address,address)" \
        "$TOKEN_IN" \
        "$TOKEN_OUT" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY"

    echo "Route cleared successfully!"
    exit 0
fi

print_header "Setting Route"

echo "Fee: $FEE"
echo "Tick Spacing: $TICK_SPACING"
echo "Hooks: $HOOKS"

cast send "$HOOK_ROUTE_CONTROLLER" \
    "setRoute(address,address,uint24,int24,address)" \
    "$TOKEN_IN" \
    "$TOKEN_OUT" \
    "$FEE" \
    "$TICK_SPACING" \
    "$HOOKS" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY"

echo "Route configured successfully!"
