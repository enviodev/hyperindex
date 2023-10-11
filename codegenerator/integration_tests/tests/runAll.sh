#!/bin/bash

set -e # Exit on error

cargo run

# # NOTE: this test must be run from the root `integration_tests` folder via `./tests/runAll.sh`
#
# export TEMPLATE="Erc20"
# LANGUAGE="Javascript" ./tests/runSingle.sh
# LANGUAGE="Typescript" ./tests/runSingle.sh
# LANGUAGE="Rescript" ./tests/runSingle.sh
#
# export TEMPLATE="Greeter"
# LANGUAGE="Javascript" ./tests/runSingle.sh
# LANGUAGE="Typescript" ./tests/runSingle.sh
# LANGUAGE="Rescript" ./tests/runSingle.sh

run_single() {
	echo "Running for $TEMPLATE in $LANGUAGE"
	LANGUAGE=$1 ./tests/runSingle.sh &
	pid=$!
	echo "Started with PID $pid"
	wait $pid
	echo "Completed for $TEMPLATE in $LANGUAGE"
}

export TEMPLATE="Erc20"
run_single "Javascript"
sleep 5 # This sleep 'should' be completely unnecessary - but for some reason makes the tests less flaky :/ Really not sure why the tests sometimes fail
run_single "Typescript"
sleep 5 # This sleep 'should' be completely unnecessary - but for some reason makes the tests less flaky :/ Really not sure why the tests sometimes fail
run_single "Rescript"
sleep 5 # This sleep 'should' be completely unnecessary - but for some reason makes the tests less flaky :/ Really not sure why the tests sometimes fail

export TEMPLATE="Greeter"
run_single "Javascript"
sleep 5 # This sleep 'should' be completely unnecessary - but for some reason makes the tests less flaky :/ Really not sure why the tests sometimes fail
run_single "Typescript"
sleep 5 # This sleep 'should' be completely unnecessary - but for some reason makes the tests less flaky :/ Really not sure why the tests sometimes fail
run_single "Rescript"
