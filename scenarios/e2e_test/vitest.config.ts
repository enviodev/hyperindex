import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    pool: "forks",
    maxWorkers: 1,
    testTimeout: 60_000,
    server: {
      deps: {
        // Externalize non-test files so they load via native Node.js ESM,
        // preserving import.meta.url for NAPI addon resolution
        external: [/^(?!.*\.(test|spec)\.)(?!.*_test\.)(?!.*\/test\/).*$/i],
      },
    },
  },
});
