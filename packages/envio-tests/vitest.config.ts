import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const devAddon = path.join(repoRoot, "target", "debug", "envio.node");

export default defineConfig({
  test: {
    include: ["test/**/*_test.res.mjs", "test/**/*.test.ts"],
    exclude: ["test/helpers/**"],
    // Files run in parallel: every scenario indexer gets a Postgres schema of
    // its own (see IndexerRunner.run). Tests within a file stay sequential —
    // the handler registration a scenario activates is process-global.
    sequence: {
      concurrent: false,
    },
    pool: "forks",
    testTimeout: 30_000,
    hookTimeout: 30_000,
    setupFiles: ["test/setup.ts"],
    globalSetup: ["test/helpers/globalSetup.ts", "test/helpers/GlobalSetup.res.mjs"],
    env: {
      ENVIO_DEV_ADDON: devAddon,
    },
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
