-include .env

test-mainnet:; forge test --fork-url ${MAINNET_RPC_URL} -vvvvvv