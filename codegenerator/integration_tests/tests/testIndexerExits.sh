#!/bin/bash

# This file will test a custom indexer with various configurations and fail/success states.
echo -e "\n============================\nTesting Exit: $TEMPLATE with config: $CONFIG_FILE and shouldFail $SHOULD_FAIL and should restart indexer: $TEST_RESTART\n============================\n"

# This shouldn't be needed - but the test will fail if port 9898 isn't available - so worth checking it first.
while :; do
	if lsof -i :9898 >/dev/null; then
		if [ "$CI" == "true" ]; then
			kill -9 $(lsof -t -i :9898)
		else
			echo "Waiting for the port 9898 to get freed - you can manually free it by running 'kill -9 $(lsof -t -i :9898)
' if you are happy to kill the process."
		fi
		sleep 1
	else
		echo "Port 9898 is free!"
		break
	fi
done

root_dir=$(pwd)

# By default this will use envio from pnpm, but you can override this with an the ENVIO_CMD env var.
# If you know that the version of envio inside the projct is correct, then you can use `ENVIO="pnpm envio".
envio_cmd=${ENVIO_CMD:-"pnpm envio"}

# change to the directory of the template
cd ./integration_test_output/${TEMPLATE}/

# install packages
echo "Installing packages"
pnpm install

# generate codegen as it is in gitignore
echo "Generating codegen"
$envio_cmd codegen --config ./$CONFIG_FILE

# clear everything before we start
echo "Clearing old docker state"
$envio_cmd stop || true

# start the indexer function, and check if it fails or exits with success
# will exit the test if failure occurs (expected or not)
start_indexer() {
    local startState="$1"
    export TUI_OFF=true
    $envio_cmd start
    local status=$?
        if [ $status -ne 0 ]; then
            if [ $SHOULD_FAIL = true ]; then
                echo "Indexer has failed as expected - startState: $startState"
                echo "finished workflow test"
                exit 0
            else 
                echo "Indexer has failed unexpectedly - startState: $startState"
                exit 1
            fi
        else 
            if [ $SHOULD_FAIL = true ]; then
                echo "Indexer should have failed with exit 1 - startState: $startState"
                exit 1
            else 
                echo "indexer has finished syncing as expected -startState: $startState"
            fi
        fi
}

# run the setup commands and start indexer
echo "Starting indexer"
TUI_OFF="true" $envio_cmd dev --config ./$CONFIG_FILE &

if [ $TEST_RESTART = true ]; then
    echo "Restarting indexer"
    start_indexer "restart"
fi
echo "running endblock tests"

function cleanup_indexer_process() {
    local pids=$(lsof -t -i :9898)
    if [[ -n "$pids" ]]; then
		echo "Killing the indexer process if it is still running"
        kill $pids || echo "Warning: Failed to kill process(es) with PID(s) $pids"
    else
        echo "No indexer process found running on port 9898."
	fi
}
trap cleanup_indexer_process EXIT ERR # Cleanup on exit (success) or ERR (failure)

# make requests to hasura and get indexed entity data
cd $root_dir

sleep 8 # Weird things happen if the indexer process hasn't started yet.

echo "Running tests"
node ./tests/${TEST_FILE}.js

echo "finished workflow test"
