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
    setupFiles: ["test/setup.ts"],
    passWithNoTests: true,
    server: {
      deps: {
        external: [/^(?!.*\.(test|spec)\.)(?!.*_test\.).*$/i],
      },
    },
  },
});
