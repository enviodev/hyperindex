import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*_test.res.mjs", "test/**/*.test.ts"],
    exclude: ["test/helpers/**"],
    // No shared database or other cross-file state, so files can run in
    // parallel (each fork gets its own process-level globals).
    pool: "forks",
    testTimeout: 30_000,
    hookTimeout: 30_000,
    setupFiles: ["test/setup.ts"],
    passWithNoTests: true,
    server: {
      deps: {
        // Externalize non-test files so they load via native Node.js ESM,
        // preventing dual module cache between vite and native import()
        external: [/^(?!.*\.test\.)(?!.*_test\.)(?!.*\/test\/).*$/i],
      },
    },
  },
});
