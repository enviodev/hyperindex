#!/bin/bash

# This file will test a single scenario (language agnostic)
echo -e "\n============================\nTesting TEMPLATE: $TEMPLATE, LANGUAGE: $LANGUAGE\n============================\n"

set -e # Exit on error

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
envio_cmd=${ENVIO_CMD:-"cargo run --manifest-path $(dirname $(pwd))/cli/Cargo.toml --"}

# change to the directory of the template
cd ./integration_test_output/${TEMPLATE}/${LANGUAGE}/

# install packages
echo "Installing packages"
pnpm install

# generate codegen as it is in gitignore
echo "Generating codegen"
$envio_cmd codegen

# clear everything before we start
echo "Clearing old docker state"
$envio_cmd stop || true

# start the indexer running manual steps
# NOTE: if dev fails or has issues you can debug with these separate steps.
# $envio_cmd local docker up
# $envio_cmd local db-migrate setup
# npm run start & PID=$!
# $envio_cmd start & PID=$!

echo "Starting indexer"
$envio_cmd dev &

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

# NOTE: the error should propagate to this bash process, since the 'set -e' setting is used.
echo "Running tests"
node ./tests/${TEMPLATE}.js

echo "finished workflow test"
