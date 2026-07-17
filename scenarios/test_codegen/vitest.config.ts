import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: [
      "test/**/*_test.res.mjs",
      "test/**/*.test.ts",
    ],
    exclude: [
      "test/fixtures/**",
      "test/helpers/**",
      // Entirely commented-out test files
      "test/integration-raw-events.test.ts",
      "test/topic-hashing.test.ts",
    ],
    // Run tests sequentially - both file-wide and test-wide
    fileParallelism: false,
    sequence: {
      concurrent: false,
    },
    pool: "forks",
    maxWorkers: 1,
    testTimeout: 30_000,
    hookTimeout: 30_000,
    // Some tests hit live HyperSync/RPC endpoints; on CI a single hung
    // connection shouldn't fail the run. Tests run sequentially with a fresh
    // indexer per test, so a retry starts from a clean slate.
    retry: process.env.CI ? 1 : 0,
    setupFiles: ["test/setup.ts"],
    passWithNoTests: true,
    server: {
      deps: {
        // Externalize non-test files so they load via native Node.js ESM,
        // preventing dual module cache between vite and native import()
        external: [/^(?!.*\.(test|spec)\.)(?!.*_test\.)(?!.*\/test\/).*$/i],
      },
    },
  },
});
