# Test Script for TSV File Splitting

This test script verifies the `splitTsvFile` function that splits large TSV cache files into chunks.

## What it does

1. Creates a test TSV file with sample cache data (id + output columns)
2. Splits the file if it exceeds a threshold (2KB for testing)
3. Verifies that:
   - Original file is deleted
   - Chunk files are created with correct naming (`cache_name_00001.tsv`, `cache_name_00002.tsv`, etc.)
   - Each chunk file contains the header row
   - File sizes are reported

## Running the test

From the `codegenerator/cli/npm/envio` directory:

```bash
./test_split_tsv.sh
```

Or manually:

```bash
pnpm rescript
node src/test_split_tsv.res.js
```

## Expected output

The script will:
- Create a `test_cache/` directory
- Create `test_cache/test_cache.tsv` with sample data
- Split it into multiple chunk files if it exceeds the threshold
- Print information about file sizes and chunk files created
- Clean up the test files at the end

## Adjusting test parameters

You can modify the test in `src/test_split_tsv.res`:

- `chunkSizeBytes`: Change the threshold (currently 2KB for fast testing)
- Number of lines: Change `for i in 0 to 200` to create more/fewer lines
- Line size: Modify the `dataStr` variable to create larger/smaller lines

## Note

This test script duplicates the logic from `PgStorage.res` for standalone testing. Once verified, the same logic is already implemented in the main codebase.

