#!/bin/bash

# This file will test a single scenario (language agnostic)
echo -e "\n============================\nTsting TEMPLATE: $TEMPLATE, LANGUAGE: $LANGUAGE\n============================\n"

set -e  # Exit on error
trap 'kill -- -$(ps -o pgid= $PID | grep -o [0-9]*)' EXIT  # Cleanup on exit (success) OR error.

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
# pnpm envio local docker up
# pnpm envio local db-migrate setup
# pnpm envio start & PID=$!
$envio_cmd dev & PID=$!

# save this process so we can kill it later in the script
echo "process id is $PID"

# make requests to hasura and get indexed entity data
cd $root_dir
echo -e "\n\n here $(pwd) \n\n"

# NOTE: the error should propagate to this bash process, since the 'set -e' setting is used.
node ./tests/${TEMPLATE}.js
cat ./tests/${TEMPLATE}.js
echo -e "\n\n starting test \n\n"

# if [ $? -ne 0 ]; then
#   echo "Test failed!"
#   exit 1
# fi
