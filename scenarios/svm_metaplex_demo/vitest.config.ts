import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    pool: "forks",
    maxWorkers: 1,
    testTimeout: 120_000,
    server: {
      deps: {
        // Mirror scenarios/e2e_test: externalize non-test files so they
        // load via native Node ESM, preserving `import.meta.url` for NAPI
        // addon resolution.
        external: [/^(?!.*\.(test|spec)\.)(?!.*_test\.)(?!.*\/test\/).*$/i],
      },
    },
  },
});
