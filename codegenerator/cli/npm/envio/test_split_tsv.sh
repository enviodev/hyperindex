#!/bin/bash
# Script to run the split TSV test

cd "$(dirname "$0")"

echo "Compiling test script..."
pnpm rescript

echo ""
echo "Running test..."
node src/test_split_tsv.res.js

echo ""
echo "Cleaning up test files..."
rm -rf test_cache

echo "Done!"

