# Audit Handoff

This document is a concise protocol handoff for external auditors reviewing `v4lend`.

Target snapshot:
- commit: `775f7e23f2d38aa0e0268214f671efe72fda527a`
- branch: `main`

Validation at this snapshot:
- `forge test`
- `forge build --sizes`

Both were green at handoff time.

## Scope

Primary audit scope is first-party Solidity under [`src/`](/Users/kalinbas/Code/v4lend/src).

Main protocol components:
- [`src/vault/V4Vault.sol`](/Users/kalinbas/Code/v4lend/src/vault/V4Vault.sol)
- [`src/oracle/V4Oracle.sol`](/Users/kalinbas/Code/v4lend/src/oracle/V4Oracle.sol)
- [`src/RevertHook.sol`](/Users/kalinbas/Code/v4lend/src/RevertHook.sol) and [`src/hook/`](/Users/kalinbas/Code/v4lend/src/hook)
- [`src/automators/`](/Users/kalinbas/Code/v4lend/src/automators)
- [`src/vault/transformers/`](/Users/kalinbas/Code/v4lend/src/vault/transformers)
- shared math / planning / swap helpers under [`src/shared/`](/Users/kalinbas/Code/v4lend/src/shared)

Supporting tests, scripts, and docs are meant as context, not as primary protocol scope.

## System Summary

`v4lend` is a Uniswap v4-native lending and automation system built around LP NFTs.

The system supports:
- using Uniswap v4 LP NFTs as collateral in a single-asset ERC4626 vault
- valuing LP positions with Chainlink-backed oracle checks
- swap-triggered automation through a v4 hook
- operator-driven standalone automators
- vault-managed transforms for compounding, range changes, and leverage flows

High-level modules:
- `V4Vault`: lenders deposit one asset; borrowers post LP NFTs as collateral and borrow the vault asset
- `V4Oracle`: values LP collateral and fees in a common reference asset
- `RevertHook`: on-swap automation for LP positions
- automators: operator-driven one-shot execution contracts
- transformers: helpers used directly or via `V4Vault.transform(...)`

## Actors And Trust Model

Privileged actors:
- vault owner
- hook owner
- protocol owner / deployment owner in scripts
- approved automator operators
- approved vault transformers

User actors:
- LP/NFT owners
- lenders
- borrowers
- liquidators

External dependencies:
- Uniswap v4 `PoolManager`
- Uniswap v4 `PositionManager`
- Chainlink-style feeds
- ERC4626 vaults for auto-lend
- swap routers / calldata targets used by automators and transformers

Important trust assumptions:
- oracle token configs are correct and maintained
- hook fee and route controllers are configured by the intended hook owner
- automator operators are trusted to submit the intended quoted execution calldata
- approved transformers are trusted as part of the vault’s privileged surface

## Main Contracts

### V4Vault

File:
- [`src/vault/V4Vault.sol`](/Users/kalinbas/Code/v4lend/src/vault/V4Vault.sol)

Purpose:
- ERC4626 vault for one lend/borrow asset
- LP NFT collateral management
- borrow / repay / liquidate
- reserve accounting
- transform orchestration

Notes:
- `V4Vault` intentionally holds lender funds, reserves, and collateral NFTs
- unlike automators and hook helpers, it is not expected to end operations with zero balances

### V4Oracle

File:
- [`src/oracle/V4Oracle.sol`](/Users/kalinbas/Code/v4lend/src/oracle/V4Oracle.sol)

Purpose:
- LP valuation
- fee valuation
- Chainlink normalization
- oracle-vs-pool deviation checks
- L2 sequencer guard integration

### RevertHook

Files:
- [`src/RevertHook.sol`](/Users/kalinbas/Code/v4lend/src/RevertHook.sol)
- [`src/hook/`](/Users/kalinbas/Code/v4lend/src/hook)

Purpose:
- swap-triggered LP automation
- auto exit
- auto range
- auto collect
- auto lend
- auto leverage

Important implementation detail:
- the deployed hook delegates execution into sidecar contracts
- storage layout compatibility matters across the shared hook/action state spine

See also:
- [`docs/hook-hierarchy.md`](/Users/kalinbas/Code/v4lend/docs/hook-hierarchy.md)

### Standalone Automators

Files:
- [`src/automators/AutoCollect.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoCollect.sol)
- [`src/automators/AutoExit.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoExit.sol)
- [`src/automators/AutoLend.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoLend.sol)
- [`src/automators/AutoLeverage.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoLeverage.sol)
- [`src/automators/AutoRange.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoRange.sol)
- shared base: [`src/automators/Automator.sol`](/Users/kalinbas/Code/v4lend/src/automators/Automator.sol)

Purpose:
- operator-driven execution outside the hook path
- one strategy per contract

Important implementation detail:
- protocol fees are sent directly to `protocolFeeRecipient`
- automators no longer retain protocol fees or use a withdrawer model

### Controllers

Files:
- [`src/hook/HookFeeController.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookFeeController.sol)
- [`src/hook/HookRouteController.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookRouteController.sol)

Purpose:
- keep fee governance and swap routing out of `RevertHook` storage

Auth model:
- both controllers are administered through `hook.owner()`
- they do not keep an independent mutable owner

## Accounting Model

This section is intentionally explicit because it is a recurring source of review comments.

### Whole-Balance Sweep Model

The following helper/execution layers intentionally use a whole-balance accounting model:
- hook action helpers in [`src/hook/RevertHookActionBase.sol`](/Users/kalinbas/Code/v4lend/src/hook/RevertHookActionBase.sol)
- vault transformer helpers in [`src/vault/transformers/V4Utils.sol`](/Users/kalinbas/Code/v4lend/src/vault/transformers/V4Utils.sol)
- leverage transformer logic in [`src/vault/transformers/LeverageTransformer.sol`](/Users/kalinbas/Code/v4lend/src/vault/transformers/LeverageTransformer.sol)
- automators in [`src/automators/`](/Users/kalinbas/Code/v4lend/src/automators)

Intended behavior:
- these execution helpers are expected to finish a successful call with no unintended leftover underlying balances
- they may read or sweep whole self-balances during execution
- any residual balance present at the start of a successful call is treated as part of the next sweep by design

This is intentional and not considered a bug by itself.

### Flat-After-Success Expectation

For successful executions:
- `RevertHook` helper paths are expected to end flat in the relevant pool tokens / ETH
- automators are expected to end flat in the relevant pool tokens / ETH
- transformer helper contracts are expected to end flat in the relevant working assets / ETH

Exception:
- [`src/automators/AutoLend.sol`](/Users/kalinbas/Code/v4lend/src/automators/AutoLend.sol) intentionally holds ERC4626 vault shares while a position is in its lent state
- “empty after execution” for `AutoLend` means no stray underlying tokens or ETH remain, not that ERC4626 share balances are always zero

### Components That Intentionally Hold Balances

These contracts are not expected to end flat:
- [`src/vault/V4Vault.sol`](/Users/kalinbas/Code/v4lend/src/vault/V4Vault.sol)
- ERC4626 lend vaults used by `AutoLend`

`V4Vault` intentionally holds:
- lender asset liquidity
- reserves
- loan state
- collateral NFTs

## Fee Model

### Hook Fees

Hook fee governance is in:
- [`src/hook/HookFeeController.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookFeeController.sol)

Fee types:
- LP protocol fee
- auto-lend gain fee
- hook swap fee

Hook swap-fee behavior:
- charged only on hook-internal swaps
- charged on actual output, not input
- only for swap-bearing modes
- routed directly to `protocolFeeRecipient`
- not retained in the hook

### Hook Swap Routing

Hook routing is protocol-managed through:
- [`src/hook/HookRouteController.sol`](/Users/kalinbas/Code/v4lend/src/hook/HookRouteController.sol)

Current routing model:
- single-pool route per ordered `(tokenIn, tokenOut)`
- direction-specific routing
- fallback to the source pool when no route is configured
- no retry-on-source if a configured alternate route fails

Important constraint:
- dynamic-fee routes are intentionally rejected
- only static-fee routes are supported by the current planning logic

### Automator Fees

Automators:
- send protocol fees directly to `protocolFeeRecipient`
- do not retain protocol fees in-contract
- do not use a withdrawer escrow model anymore

Automators intentionally do not have a separate onchain swap-fee schedule like the hook because their swap paths are composed offchain through quoted calldata.

## Position / Config Model

### Hook

Per-position config still exists for:
- mode activation
- trigger configuration
- swap protection / price impact limits

Routing is no longer per-position.

Per-position route choice was removed in favor of protocol-level routing via `HookRouteController`.

### Vault

Vault operation depends on admin configuration for:
- token collateral factors and value caps
- hook allowlist
- transformer allowlist
- global and daily debt / lend limits
- minimum loan size

### Oracle

Oracle coverage is mandatory for:
- vault valuation / health checks
- hook oracle guardrails
- slippage checks when they are not explicitly disabled

## Important Non-Upgradeable / Deployment Notes

The current architecture is effectively redeploy-oriented rather than upgrade-in-place:
- hook controllers are standalone deployed contracts
- hook action sidecars store controller references as immutables
- the deployed hook stores sidecar addresses as immutables
- the hook address is part of hooked pool identity

Practical consequence:
- changing the live hook stack typically means a new hook deployment and new hooked pools, not just swapping one helper contract

## Intended Security Invariants

Auditors should expect the protocol to maintain these invariants:

Vault:
- only authorized borrowers can modify their loan state
- debt, collateral value, and liquidation conditions stay coherent
- reserve accounting never creates or destroys lender claims incorrectly

Hook:
- no unauthorized action execution
- trigger bookkeeping remains internally consistent
- one action failure should not corrupt unrelated trigger state
- delegatecall sidecars must remain storage-layout compatible with the shared state spine

Automators:
- only approved operators can execute
- protocol fees are sent directly to the recipient
- successful executions should not strand unintended underlying balances

Oracle:
- price normalization and feed selection stay coherent
- pool/oracle deviation checks gate unsafe valuations

## Tests Most Relevant To Audit

Core suites:
- [`test/vault/V4Vault.t.sol`](/Users/kalinbas/Code/v4lend/test/vault/V4Vault.t.sol)
- [`test/hook/RevertHook.t.sol`](/Users/kalinbas/Code/v4lend/test/hook/RevertHook.t.sol)
- [`test/hook/RevertHookNativeAutoLend.t.sol`](/Users/kalinbas/Code/v4lend/test/hook/RevertHookNativeAutoLend.t.sol)
- [`test/vault/V4VaultHook.t.sol`](/Users/kalinbas/Code/v4lend/test/vault/V4VaultHook.t.sol)
- [`test/automators/`](/Users/kalinbas/Code/v4lend/test/automators)
- [`test/oracle/V4OracleTest.t.sol`](/Users/kalinbas/Code/v4lend/test/oracle/V4OracleTest.t.sol)

Invariant suites:
- [`test/hook/invariants/`](/Users/kalinbas/Code/v4lend/test/hook/invariants)
- [`test/vault/invariants/`](/Users/kalinbas/Code/v4lend/test/vault/invariants)

Recent tests of note:
- automator contracts finishing empty after successful operations
- protocol fees sent directly to the fee recipient
- hook route-controller behavior
- hook swap-fee behavior
- third-token `AutoLeverage` deleverage sizing

## Suggested Audit Focus

Highest-value review areas:
- `V4Vault` borrow / repay / liquidation / transform flows
- `RevertHook` delegatecall safety and trigger accounting
- `HookFeeController` and `HookRouteController` trust boundaries
- `AutoLeverage` leverage-down / third-token paths
- `V4Oracle` valuation assumptions and stale / deviating price behavior
- shared swap helpers and native ETH handling

## Things We Intentionally Want Auditors To Know Up Front

- whole-balance accounting in hook/helpers/transformers/automators is intentional
- `AutoLend` intentionally holds ERC4626 shares while a position is lent
- hook swap routing is protocol-managed, not user-managed
- hook swap fees are direct-send, not retained
- dynamic-fee hook routes are intentionally unsupported
- controllers are governed by `hook.owner()`

