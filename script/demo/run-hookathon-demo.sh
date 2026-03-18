#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROFILE="${FOUNDRY_PROFILE:-ci}"
LOG_DIR="${HOOKATHON_LOG_DIR:-$ROOT_DIR/script/demo/logs}"
mkdir -p "$LOG_DIR"
SKIP_SIMULATION="${HOOKATHON_SKIP_SIMULATION:-1}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RAW_LOG_PATH="${HOOKATHON_RAW_LOG_PATH:-$LOG_DIR/unichain-hookathon-demo-${TIMESTAMP}.raw.log}"
REPLAY_LOG_PATH="${HOOKATHON_REPLAY_LOG_PATH:-$LOG_DIR/unichain-hookathon-demo-${TIMESTAMP}.replay.log}"
TOTAL_DURATION="${HOOKATHON_REPLAY_TOTAL_DURATION:-40}"
JITTER="${HOOKATHON_REPLAY_JITTER:-0.45}"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: ./script/demo/run-hookathon-demo.sh [additional forge script args]

Runs the full Unichain fork Hookathon demo, stores the raw Forge output, then
replays the demo log slowly for presentation/video capture.

Environment overrides:
  FOUNDRY_PROFILE                 Forge profile to use (default: ci)
  HOOKATHON_LOG_DIR               Directory for generated log files
  HOOKATHON_RAW_LOG_PATH          Full path for raw Forge output
  HOOKATHON_REPLAY_LOG_PATH       Full path for cleaned replay log
  HOOKATHON_SKIP_SIMULATION       Set to 1 to pass --skip-simulation (default: 1)
  HOOKATHON_REPLAY_TOTAL_DURATION Target total replay time in seconds (default: 40)
  HOOKATHON_REPLAY_JITTER         Random timing variation per block, 0 to 1 (default: 0.45)
EOF
  exit 0
fi

FORGE_ARGS=(
  script
  script/demo/UnichainForkHookathonE2E.s.sol:UnichainForkHookathonE2E
  -vv
  --color
  always
  "$@"
)

if [[ "$SKIP_SIMULATION" == "1" ]]; then
  FORGE_ARGS+=(--skip-simulation)
fi

echo "Running Hookathon demo"
echo

if ! env FOUNDRY_PROFILE="$PROFILE" forge "${FORGE_ARGS[@]}" >"$RAW_LOG_PATH" 2>&1; then
  echo "Hookathon demo failed. Showing the end of the raw Forge log:" >&2
  echo >&2
  tail -n 120 "$RAW_LOG_PATH" >&2
  exit 1
fi

perl -pe 's/\e\[[0-9;]*[[:alpha:]]//g' "$RAW_LOG_PATH" \
  | awk '
      /^== Logs ==$/ { capture = 1; next }
      /^## Setting up 1 EVM\./ { capture = 0 }
      /^SKIPPING ON CHAIN SIMULATION\./ { capture = 0 }
      /^SIMULATION COMPLETE\./ { capture = 0 }
      capture && /^  Hook:/ && saw_completion { capture = 0; next }
      capture && /^  Demo Completed Successfully$/ { saw_completion = 1 }
      capture && /^    event debt before:/ { next }
      capture && /^    event debt after:/ { next }
      capture && /^    refreshed base tick:/ { next }
      capture { print }
    ' \
  | sed '/^[[:space:]]*$/N;/^\n$/D' >"$REPLAY_LOG_PATH"

python3 - "$REPLAY_LOG_PATH" "$TOTAL_DURATION" "$JITTER" <<'PY'
import random
import sys
import time

path = sys.argv[1]
total_duration = max(0.0, float(sys.argv[2]))
jitter = max(0.0, min(1.0, float(sys.argv[3])))
use_color = sys.stdout.isatty()

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
NEON_GREEN = "\033[38;2;20;245;108m"
SOFT_WHITE = "\033[38;2;241;236;244m"
OCEAN_TEAL = "\033[38;2;35;193;190m"

with open(path, "r", encoding="utf-8") as fh:
    lines = [line.rstrip("\n") for line in fh]


def is_blank(line: str) -> bool:
    return line.strip() == ""


def is_top_level(line: str) -> bool:
    return line.startswith("  ") and not line.startswith("    ")


def is_child(line: str) -> bool:
    return line.startswith("    ")


def is_divider(line: str) -> bool:
    stripped = line.strip()
    return stripped != "" and len(set(stripped)) == 1 and stripped[0] in "=-"


def is_header(line: str) -> bool:
    stripped = line.strip()
    if stripped == "":
        return False
    if stripped == "Demo Completed Successfully":
        return True
    return stripped[0].isdigit() and "." in stripped


def paint(line: str, *styles: str) -> str:
    if not use_color or not styles:
        return line
    prefix = "".join(styles)
    return f"{prefix}{line}{RESET}"


def colorize(line: str) -> str:
    stripped = line.strip()
    hook_execution_prefixes = (
        "Configuration immediately triggered AUTO_LEVERAGE",
        "AUTO_RANGE executed",
        "AUTO_EXIT executed",
    )

    if stripped == "":
        return line
    if is_divider(line):
        return paint(line, BOLD, SOFT_WHITE)
    if stripped == "Unichain Fork Hookathon Demo":
        return paint(line, BOLD, NEON_GREEN)
    if stripped == "Demo Completed Successfully":
        return paint(line, BOLD, NEON_GREEN)
    if is_header(line):
        return paint(line, BOLD, SOFT_WHITE)
    if any(stripped.startswith(prefix) for prefix in hook_execution_prefixes):
        return paint(line, BOLD, NEON_GREEN)
    if stripped.startswith("Range hunt"):
        return paint(line, BOLD, OCEAN_TEAL)
    if stripped.startswith("Minted position type"):
        return paint(line, BOLD, OCEAN_TEAL)
    if stripped.startswith("Position moved into vault custody"):
        return paint(line, BOLD, OCEAN_TEAL)
    if stripped.startswith("Leverage, range, and lower-side exit are now active"):
        return paint(line, BOLD, OCEAN_TEAL)
    if line.startswith("    "):
        return paint(line, DIM)
    if any(
        stripped.startswith(prefix)
        for prefix in (
            "Fork RPC:",
            "Demo operator:",
            "Hook:",
            "Vault:",
            "Pool token0:",
            "Pool token1:",
            "Starting tick:",
            "Current tick:",
            "Current upper range edge:",
            "Next leverage upper trigger:",
            "Range upper trigger:",
            "Range should fire before the next upper leverage trigger.",
        )
    ):
        return paint(line, OCEAN_TEAL)
    return line


def next_non_blank(index: int) -> str:
    for j in range(index + 1, len(lines)):
        if not is_blank(lines[j]):
            return lines[j]
    return ""


def prev_non_blank(index: int) -> str:
    for j in range(index - 1, -1, -1):
        if not is_blank(lines[j]):
            return lines[j]
    return ""


blocks: list[list[str]] = []
pending_header: list[str] = []
current: list[str] = []


def flush_current() -> None:
    global current
    if current:
        blocks.append(current.copy())
        current.clear()


for idx, line in enumerate(lines):
    if is_blank(line):
        flush_current()
        continue

    prev_line = prev_non_blank(idx)
    next_line = next_non_blank(idx)
    divider_wrapped_title = is_top_level(line) and not is_divider(line) and is_divider(prev_line) and is_divider(next_line)

    if is_top_level(line) and (is_divider(line) or is_header(line) or divider_wrapped_title):
        flush_current()
        pending_header.append(line)
        continue

    if is_top_level(line):
        has_children = is_child(next_line)
        if has_children:
            flush_current()
            current.extend(pending_header)
            pending_header.clear()
            current.append(line)
            continue

        if not current:
            current.extend(pending_header)
            pending_header.clear()
        current.append(line)
        continue

    if not current:
        current.extend(pending_header)
        pending_header.clear()
    current.append(line)

flush_current()
if pending_header:
    blocks.append(pending_header.copy())

delays: list[float] = []
if len(blocks) > 1 and total_duration > 0:
    rng = random.Random()
    weights: list[float] = []
    for block in blocks[:-1]:
        has_section_banner = any(is_divider(line) for line in block)
        has_event = any(
            line.strip().startswith(prefix)
            for line in block
            for prefix in (
                "Configuration immediately triggered AUTO_LEVERAGE",
                "AUTO_RANGE executed",
                "Range hunt",
                "Loan state before",
                "Loan after",
            )
        )
        base_weight = 1.35 if has_section_banner else 1.0
        if has_event:
            base_weight += 0.15
        swing_low = max(0.20, 1.0 - 1.35 * jitter)
        swing_high = 1.0 + 1.85 * jitter
        random_factor = rng.uniform(swing_low, swing_high)
        if has_event and rng.random() < 0.45:
            random_factor *= rng.uniform(1.0, 1.0 + 0.80 * jitter)
        elif not has_section_banner and rng.random() < 0.25:
            random_factor *= rng.uniform(max(0.70, 1.0 - 0.90 * jitter), 1.0)
        weights.append(base_weight * random_factor)

    weight_sum = sum(weights)
    if weight_sum > 0:
        delays = [total_duration * (weight / weight_sum) for weight in weights]
    else:
        delays = [0.0 for _ in weights]

for i, block in enumerate(blocks):
    print("\n".join(colorize(line) for line in block), flush=True)
    if i != len(blocks) - 1:
        print(flush=True)
        time.sleep(delays[i] if i < len(delays) else 0.0)
PY
