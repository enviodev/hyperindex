import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*_test.res.mjs", "test/**/*.test.ts", "test/test.ts"],
    fileParallelism: false,
    sequence: {
      concurrent: false,
    },
    pool: "forks",
    maxWorkers: 1,
    testTimeout: 30_000,
    hookTimeout: 30_000,
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
