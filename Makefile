-include .env

test-mainnet:; forge test --fork-url ${MAINNET_RPC_URL} -vvvv
coverage-mainnet:; forge coverage --fork-url ${MAINNET_RPC_URL} -vvvv