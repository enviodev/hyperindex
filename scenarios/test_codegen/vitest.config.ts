import { availableParallelism } from "node:os";
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
    // Files run in parallel: every indexer gets a Postgres schema of its own
    // (see MockIndexer.Indexer.run), so they no longer share one. Tests within
    // a file stay sequential — they share the process-global config and
    // handler registry.
    sequence: {
      concurrent: false,
    },
    pool: "forks",
    // Vitest defaults to one fewer worker than the machine has; the suite is
    // not CPU-saturated enough for that to pay off, and the extra worker is
    // worth ~20% of the wall clock.
    maxWorkers: availableParallelism(),
    testTimeout: 30_000,
    hookTimeout: 30_000,
    setupFiles: ["test/setup.ts"],
    globalSetup: ["test/globalSetup.ts"],
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
