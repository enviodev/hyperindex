import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 120_000,
    // The smoke tests index real blocks through live HyperSync; a failed
    // attempt surfaces quickly with a real error, so one retry on CI absorbs
    // a hung connection on the runner without hiding deterministic failures.
    retry: process.env.CI ? 1 : 0,
  },
});
