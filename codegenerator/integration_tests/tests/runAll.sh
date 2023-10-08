#!/bin/bash

set -e  # Exit on error

# NOTE: this test must be run from the root `integration_tests` folder via `./tests/runAll.sh`

export TEMPLATE="Erc20"
LANGUAGE="Javascript" ./tests/runSingle.sh
LANGUAGE="Typescript" ./tests/runSingle.sh
LANGUAGE="Rescript" ./tests/runSingle.sh
