import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: [
      "test/**/*_test*.{ts,res.mjs}",
      "test/**/*-test*.ts",
    ],
    exclude: [
      "test/fixtures/**",
      "test/helpers/**",
      // Entirely commented-out test files
      "test/integration-raw-events-test.ts",
      "test/topic-hashing-test.ts",
    ],
    // Run tests sequentially to avoid database conflicts
    pool: "forks",
    poolOptions: {
      forks: {
        singleFork: true,
      },
    },
    sequence: {
      concurrent: false,
    },
    testTimeout: 30_000,
    hookTimeout: 30_000,
    passWithNoTests: true,
  },
});
