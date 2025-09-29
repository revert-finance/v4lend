# Revert V4Utils

This repository contains the smart contracts for Revert V4Utils.

It uses Foundry as development toolchain.


## Setup

Install foundry 

https://book.getfoundry.sh/getting-started/installation

Install dependencies

```sh
forge install
```


## Tests

Most tests use a forked state of Ethereum Mainnet. You can run all tests with: 

```sh
forge test
```

## Deployment

Example for Mainnet

forge script script/DeployV4Utils.s.sol:DeployV4Utils --sig "run(address,address,address,address)" "0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e" "0x66a9893cc07d91d95644aedd05d03f95e1dba8af" "0x0000000000001ff3684f28c67538d4d072c22734" "0x000000000022D473030F116dDEE9F6B43aC78BA3" --chain-id 1  --rpc-url https://eth.llamarpc.com  --interactives 1 --broadcast --verify --etherscan-api-key ...

Example for Unichain

forge script script/DeployV4Utils.s.sol:DeployV4Utils --sig "run(address,address,address,address)" "0x4529a01c7a0410167c5740c487a8de60232617bf" "0xef740bf23acae26f6492b10de645d6b98dc8eaf3" "0x0000000000001ff3684f28c67538d4d072c22734" "0x000000000022D473030F116dDEE9F6B43aC78BA3" --chain-id 130 --rpc-url https://mainnet.unichain.org --interactives 1 --broadcast --verify --etherscan-api-key ...
