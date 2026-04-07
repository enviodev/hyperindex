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
    // Bumped from 30s: scenario beforeAll/afterAll spawn `envio local db-migrate up`
    // as a subprocess and CI cold-start of the binary can exceed the previous limit.
    hookTimeout: 90_000,
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
