#!/bin/bash

# This file will test a single scenario (language agnostic)
echo -e "\n============================\nTesting TEMPLATE: $TEMPLATE, LANGUAGE: $LANGUAGE\n============================\n"

set -e  # Exit on error

root_dir=$(pwd)

# By default this will use envio from pnpm, but you can override this with an the ENVIO_CMD env var.
# If you know that the version of envio inside the projct is correct, then you can use `ENVIO="pnpm envio".
envio_cmd=${ENVIO_CMD:-"cargo run --manifest-path $(dirname $(pwd))/cli/Cargo.toml --"}

# change to the directory of the template
cd ./integration_test_output/${TEMPLATE}/${LANGUAGE}/

# install packages
pnpm install

# generate codegen as it is in gitignore
$envio_cmd codegen

# clear everything before we start
$envio_cmd stop || true

# start the indexer running manual steps
# NOTE: if dev fails or has issues you can debug with these separate steps.
# $envio_cmd local docker up
# $envio_cmd local db-migrate setup
# npm run start & PID=$!
# $envio_cmd start & PID=$!

$envio_cmd dev &

function cleanup_indexer_process()
{
  if [[ -n $(lsof -t -i :9898) ]]; then
    echo "Killing the indexer process if it is still running"
    kill $(lsof -t -i :9898)
  fi
}
trap cleanup_indexer_process EXIT ERR # Cleanup on exit (success) or ERR (failure)

# make requests to hasura and get indexed entity data
cd $root_dir

sleep 2 # Weird things happen if the indexer process hasn't started yet.

# NOTE: the error should propagate to this bash process, since the 'set -e' setting is used.
node ./tests/${TEMPLATE}.js

echo "finished workflow test"
