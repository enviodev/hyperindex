#!/bin/bash
# Script to run the merge TSV test

cd "$(dirname "$0")"

echo "Compiling test script..."
pnpm rescript

echo ""
echo "Running merge test..."
node src/test_merge_tsv.res.js

echo ""
echo "Files are preserved in test_cache_merge/ for your inspection."
echo "You can view:"
echo "  - Chunk files: test_cache_merge/original_cache_00001.tsv, etc."
echo "  - Merged file: test_cache_merge/merged_cache.tsv"

