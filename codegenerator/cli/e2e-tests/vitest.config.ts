import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 60000,
    hookTimeout: 30000,
    include: ["src/**/*.test.ts"],
    globals: true,
  },
});
