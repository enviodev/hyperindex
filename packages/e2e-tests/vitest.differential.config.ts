import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/differential/**/*.test.ts"],
    testTimeout: 120_000,
    hookTimeout: 180_000,
    // The suite tracks/clears shared Hasura metadata — never parallelize.
    fileParallelism: false,
    maxWorkers: 1,
  },
});
