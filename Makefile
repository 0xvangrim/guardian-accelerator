-include .env
test-mainnet:; forge test -vvvv --match-path test/unit/PerpetuEx.t.sol --fork-url "${MAINNET_RPC_URL}" --match-test "${TEST}"
test-anvil:; forge test -vvvv --match-contract PerpetuExTestAnvil
coverage-mainnet:; forge coverage --fork-url ${MAINNET_RPC_URL} -vvvv