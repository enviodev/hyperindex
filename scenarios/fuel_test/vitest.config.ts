import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*_test*.{ts,res.mjs}", "test/**/*-test*.ts", "test/test.ts"],
    fileParallelism: false,
    sequence: {
      concurrent: false,
    },
    pool: "forks",
    poolOptions: {
      forks: {
        singleFork: true,
      },
    },
    testTimeout: 30_000,
    hookTimeout: 30_000,
    passWithNoTests: true,
  },
});
