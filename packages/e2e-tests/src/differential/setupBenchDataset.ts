/**
 * Applies the differential fixture (schema.sql + seed.sql), tracks it in
 * Hasura (default phase), and layers bench-seed.sql on top — the exact
 * sequence `bench.ts --record-baseline` expects to already be in place.
 * Needs Hasura up (used for both metadata tracking and applying the SQL
 * files via its /v2/query endpoint, so no direct pg client dependency is
 * needed here — see hasuraSetup.ts).
 *
 * Usage: pnpm --filter e2e-tests exec tsx src/differential/setupBenchDataset.ts
 */

import { readFile } from "node:fs/promises";
import { applyFixture, trackDatabase, runSql } from "./hasuraSetup.js";
import { phaseConfigs } from "./corpus.js";

const fixtureDir = new URL("../../fixtures/differential/", import.meta.url);

async function main() {
  console.log("Applying fixture schema + seed...");
  await applyFixture(fixtureDir);

  console.log("Tracking Hasura metadata (default phase)...");
  await trackDatabase(phaseConfigs.default);

  console.log("Applying bench-seed.sql (large volume)...");
  const sql = await readFile(new URL("bench-seed.sql", fixtureDir), "utf8");
  await runSql(sql);

  console.log("Bench dataset ready.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
