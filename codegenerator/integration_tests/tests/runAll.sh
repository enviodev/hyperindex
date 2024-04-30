#!/bin/bash

set -e # Exit on error

cargo run

# NOTE: this test must be run from the root `integration_tests` folder via `./tests/runAll.sh`

export TEMPLATE="Erc20"
LANGUAGE="JavaScript" ./tests/runSingle.sh
LANGUAGE="TypeScript" ./tests/runSingle.sh
LANGUAGE="ReScript" ./tests/runSingle.sh

export TEMPLATE="Greeter"
LANGUAGE="JavaScript" ./tests/runSingle.sh
LANGUAGE="TypeScript" ./tests/runSingle.sh
LANGUAGE="ReScript" ./tests/runSingle.sh
