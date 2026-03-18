#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage:
  ./script/hackathon-demo.sh local
  ./script/hackathon-demo.sh testnet-sim --rpc-url <RPC_URL> [--chain-id <CHAIN_ID>]
  ./script/hackathon-demo.sh testnet-broadcast --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> [--chain-id <CHAIN_ID>] [--verify]

Modes:
  local
    Runs deterministic local demo tests (no broadcast, no live chain dependency).

  testnet-sim
    Runs DeployUnichain script in simulation mode (no broadcast).

  testnet-broadcast
    Broadcasts DeployUnichain script to target chain.
    Requires --private-key and explicit confirmation via HACKATHON_BROADCAST_ACK=YES.
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command '$1'" >&2
    exit 1
  fi
}

run_local() {
  require_cmd forge
  require_cmd rg
  echo "==> Running deterministic local hook demo tests"

  local tests=(
    "test/RevertHook.t.sol::testBasicAutoCollect"
    "test/RevertHook.t.sol::testBasicAutoRange"
    "test/RevertHook.t.sol::testBasicAutoExit"
    "test/RevertHook.t.sol::testBasicAutoLend"
    "test/RevertHook.t.sol::testPriceImpactLimit_LimitEnforced"
    "test/RevertHook.t.sol::testImmediateExecution_AutoRange"
    "test/automators/AutoLend.t.sol::test_DepositAndWithdrawETHNativePosition"
  )

  local spec
  for spec in "${tests[@]}"; do
    local path="${spec%%::*}"
    local tname="${spec##*::}"
    echo "--> $path :: $tname"
    local out
    out="$(forge test --match-path "$path" --match-test "$tname" 2>&1 || true)"
    echo "$out"
    if echo "$out" | rg -q "No tests found"; then
      echo "error: no tests matched for $path :: $tname" >&2
      exit 1
    fi
    if echo "$out" | rg -q "Suite result: FAILED"; then
      echo "error: test failure for $path :: $tname" >&2
      exit 1
    fi
  done

  echo
  echo "==> Local deterministic demo completed successfully"
}

run_testnet() {
  local broadcast="$1"
  shift

  local rpc_url=""
  local chain_id="130"
  local private_key=""
  local verify="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rpc-url)
        rpc_url="${2:-}"
        shift 2
        ;;
      --chain-id)
        chain_id="${2:-}"
        shift 2
        ;;
      --private-key)
        private_key="${2:-}"
        shift 2
        ;;
      --verify)
        verify="1"
        shift 1
        ;;
      *)
        echo "error: unknown argument '$1'" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$rpc_url" ]]; then
    echo "error: --rpc-url is required" >&2
    exit 1
  fi

  require_cmd forge

  local cmd=(
    forge script script/DeployUnichain.s.sol:DeployUnichain
    --rpc-url "$rpc_url"
    --chain-id "$chain_id"
    -vvv
  )

  if [[ "$broadcast" == "1" ]]; then
    if [[ "${HACKATHON_BROADCAST_ACK:-}" != "YES" ]]; then
      echo "error: set HACKATHON_BROADCAST_ACK=YES to enable broadcast mode" >&2
      exit 1
    fi
    if [[ -z "$private_key" ]]; then
      echo "error: --private-key is required in broadcast mode" >&2
      exit 1
    fi
    cmd+=(--broadcast --private-key "$private_key")
    if [[ "$verify" == "1" ]]; then
      cmd+=(--verify)
    fi
    echo "==> Running testnet broadcast deploy"
  else
    echo "==> Running testnet simulation deploy (no broadcast)"
  fi

  "${cmd[@]}"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local mode="$1"
  shift

  case "$mode" in
    local)
      run_local
      ;;
    testnet-sim)
      run_testnet 0 "$@"
      ;;
    testnet-broadcast)
      run_testnet 1 "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "error: unknown mode '$mode'" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
