import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

const shim = fileURLToPath(
  new URL("../../packages/envio/src/subgraph/graph-ts.ts", import.meta.url),
);

export default defineConfig({
  resolve: {
    // Running `envio dev` in this project, mappings are loaded by Node with
    // tsx, and the runtime's own resolve hook redirects graph-ts to the shim.
    // Vite resolves the mapping's imports itself and never consults that hook,
    // so the redirect is restated here for the test run only.
    alias: [{ find: /^@graphprotocol\/graph-ts$/, replacement: shim }],
  },
  test: {
    pool: "forks",
    testTimeout: 60_000,
  },
});
