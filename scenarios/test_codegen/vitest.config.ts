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
    // Migrations now run once via globalSetup (test/global-setup.ts) instead
    // of in per-file beforeAll/afterAll hooks, so the default hookTimeout is fine.
    hookTimeout: 30_000,
    globalSetup: ["test/global-setup.ts"],
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
