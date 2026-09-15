import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 120_000,
    // Every e2e suite here drives a real indexer against shared Postgres,
    // ClickHouse and Hasura instances, so two of them running at once fight over
    // the metrics port and the containers.
    fileParallelism: false,
  },
});
