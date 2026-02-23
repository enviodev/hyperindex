import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*[_-][Tt]est*.{ts,res.mjs}"],
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
