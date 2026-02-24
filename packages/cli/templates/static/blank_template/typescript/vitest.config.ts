import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    server: {
      deps: {
        // Externalize non-test files so they load via native Node.js ESM,
        // preventing dual module cache between vite and native import()
        external: [/^(?!.*\.(test|spec)\.)(?!.*_test\.)(?!.*\/test\/).*$/i],
      },
    },
  },
});
