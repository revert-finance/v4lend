# Revert Hook Security and Constraints Brief (Hackathon)

## Scope

This brief covers the V4 hook automation stack in this repository, with focus on:

- `RevertHook` dispatcher and trigger handling
- `RevertHookPositionActions` and `RevertHookLendingActions` delegatecall modules
- Automator families (AutoCompound/AutoRange/AutoExit/AutoLend)

## Trust Model

- **Trusted owner/admin model**: owner-configured parameters and allowlists are trusted.
- **Trusted operators** (automators): only configured operators can execute automation actions.
- **Trusted withdrawer**: can withdraw accumulated protocol fee balances.
- **External dependencies**:
  - Uniswap v4 `PoolManager` / `PositionManager`
  - Permit2 approvals
  - Oracle feeds through `V4Oracle`
  - Optional ERC4626 vault integrations (AutoLend paths)

## Core Security Controls

- **Per-position config gating**: actions require explicit position config and trigger conditions.
- **Role checks**:
  - owner-only setters for protocol-level parameters
  - operator checks for automation execution
  - withdrawer checks for fee sweeps
- **Oracle protection**:
  - Hook action execution bounded by `maxTicksFromOracle`.
  - Automators support oracle-based output floor when slippage < `10000`.
- **Long-tail support mode**:
  - Per-position `slippageBps = 10000` disables oracle slippage floor and relies on router `amountOutMin`.
- **Reentrancy hardening**:
  - nonReentrant guards on automator entrypoints where applicable.
- **Accounting behavior**:
  - AutoLend keeps protocol fees in contract; user leftovers are sent out immediately after operations.

## Key Constraints (Important for Judges)

- Some flows are **oracle-dependent**:
  - vault value/health checks
  - hook trigger bounds based on oracle deviation
  - automator oracle slippage guard when enabled
- Some flows are **oracle-optional**:
  - automator swaps in long-tail mode when slippage is set to `10000` per position
- AutoLend is designed for **non-vault positions** in automator mode.
- Deployment scripts must have chain-specific constants correctly configured before production-like demos.

## Operational Risks to Manage in Demo

- Incorrect role setup (`owner`, `operator`, `withdrawer`) can block flows or create admin risk.
- Missing oracle feed config for tokens can disable oracle-dependent paths.
- Incorrect vault/token pairing in AutoLend configuration can break expected behavior.
- Broadcast demos are exposed to live market conditions; keep fallback positions and a prerecorded backup.

## Recommended Demo-Safe Configuration

- Use a dedicated demo wallet with minimal required privileges and limited funds.
- Pre-configure a small token set with verified feed coverage.
- Set conservative `maxTicksFromOracle`.
- For long-tail demonstration, explicitly set per-position slippage to `10000` and explain tradeoff.
- Run deterministic local script first, then testnet simulation, then optional broadcast.

## Verification Expectations Before Presentation

- Targeted tests pass for hook and automator suites.
- Contract addresses and deployment transaction hashes are documented.
- Explorer verification completed for all deployed contracts.
- Demo runbook includes exact calls, expected events, and fallback path.

