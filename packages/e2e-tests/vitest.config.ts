import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 120_000,
    // The differential suite needs `envio serve` + tracked Hasura; it runs
    // via its own config (vitest.differential.config.ts) only.
    exclude: ["**/node_modules/**", "src/differential/**"],
  },
});
