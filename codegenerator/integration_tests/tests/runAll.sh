#!/bin/bash

set -e # Exit on error

cargo run #calls the function run_all_init_combinations in main.rs to create all templates

# NOTE: this test must be run from the root `integration_tests` folder via `./tests/runAll.sh`

cp -R -f ./tests/test_indexers ./integration_test_output


export TEMPLATE="Erc20"
LANGUAGE="JavaScript" ./tests/runSingle.sh
LANGUAGE="TypeScript" ./tests/runSingle.sh
LANGUAGE="ReScript" ./tests/runSingle.sh

export TEMPLATE="Greeter"
LANGUAGE="JavaScript" ./tests/runSingle.sh
LANGUAGE="TypeScript" ./tests/runSingle.sh
LANGUAGE="ReScript" ./tests/runSingle.sh

export TEMPLATE="test_indexers/test_exits"
export TEST_FILE="EndblockSuccess"
CONFIG_FILE="config.yaml" SHOULD_FAIL=false TEST_RESTART=false ./tests/testIndexerExits.sh
CONFIG_FILE="config-broken.yaml" SHOULD_FAIL=true TEST_RESTART=false ./tests/testIndexerExits.sh

export TEMPLATE="test_indexers/dynamic_contracts"
export TEST_FILE="DynamicContracts"
CONFIG_FILE="config-dynamic-contracts.yaml" SHOULD_FAIL=false TEST_RESTART=true ./tests/testIndexerExits.sh
