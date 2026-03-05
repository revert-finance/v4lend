# Uniswap Hackathon Checklist (Revert Hook)

This checklist is intended to make the project judge-ready and demo-safe.

## 1. Release Freeze

- [ ] Freeze a demo commit and create a tag (for example `hackathon-demo-v1`).
- [ ] Confirm `forge test` passes from that exact commit on a clean clone.
- [ ] Record deployed contract addresses and chain IDs in a single table.
- [ ] Verify all deployed contracts on the target explorer.

## 2. Deployment Readiness

- [ ] Resolve placeholders in `/Users/kalinbas/Code/v4lend/script/DeployUnichain.s.sol`:
  - [ ] `ZEROX_ALLOWANCE_HOLDER` is not `address(0)` if swap paths depend on it.
  - [ ] `SEQUENCER_UPTIME_FEED` is configured (or explicitly documented as unavailable).
- [ ] Ensure deployment scripts include the full intended stack for demo (Hook + actions + optional vault integrations).
- [ ] Ensure `RevertHook` core params are set after deploy:
  - [ ] `setProtocolFeeBps(...)`
  - [ ] `setMaxTicksFromOracle(...)`
  - [ ] `setMinPositionValueNative(...)`
- [ ] For auto-lend demos, configure vault routing per token:
  - [ ] `setAutoLendVault(token, vault)`

## 3. Demo Path Reliability

- [ ] Dry-run the deterministic local demo script:
  - [ ] `./script/hackathon-demo.sh local`
- [ ] Dry-run testnet simulation without broadcast:
  - [ ] `./script/hackathon-demo.sh testnet-sim --rpc-url <RPC_URL> --chain-id <CHAIN_ID>`
- [ ] If broadcasting, run only from dedicated demo wallet with limited funds.
- [ ] Pre-fund demo wallet for gas and required tokens.
- [ ] Pre-create fallback positions in case market state changes during live demo.

## 4. Security and Ops

- [ ] Publish short security brief for judges:
  - [ ] `/Users/kalinbas/Code/v4lend/docs/HACKATHON_SECURITY_BRIEF.md`
- [ ] Confirm operational roles are correct:
  - [ ] `owner`
  - [ ] `operator`
  - [ ] `withdrawer`
- [ ] Confirm emergency procedures:
  - [ ] Disable position automation per position.
  - [ ] Revoke operators if needed.
  - [ ] Sweep protocol fee balances via withdrawer.
- [ ] Confirm token support constraints are documented:
  - [ ] Oracle-dependent flows
  - [ ] Long-tail mode (`slippageBps = 10000`) behavior

## 5. Submission Assets

- [ ] 1-page architecture diagram and action flow (Swap trigger -> Dispatch -> Action contract).
- [ ] 2-3 minute demo script with exact transactions and expected outcomes.
- [ ] Benchmark slide with key gas numbers from `.gas-snapshot` and current run.
- [ ] Clear “what is novel vs existing hooks” statement.
- [ ] Explicit limitations and future work slide.

## 6. Live Demo Fallback Plan

- [ ] Have a pre-recorded run from the frozen commit.
- [ ] Have one “happy path” and one “constraint path” (for example oracle-disabled long-tail path).
- [ ] Keep one command to reproduce:
  - [ ] `./script/hackathon-demo.sh local`
- [ ] Keep one command to simulate target chain:
  - [ ] `./script/hackathon-demo.sh testnet-sim --rpc-url <RPC_URL> --chain-id <CHAIN_ID>`

