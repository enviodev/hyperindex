/**
 * Records the corpus responses from real Hasura into snapshots/, providing
 * the ground-truth oracle for developing `envio serve` without diffing live.
 *
 * Usage: pnpm --filter e2e-tests record:differential [--phase default|limited]
 */

import { mkdir, writeFile, rm } from "node:fs/promises";
import { allCases } from "./corpus/index.js";
import { phaseConfigs, type Phase } from "./corpus.js";
import { applyFixture, trackDatabase } from "./hasuraSetup.js";
import { hasuraUrl } from "./env.js";
import { runCase } from "./runner.js";

const fixtureDir = new URL("../../fixtures/differential/", import.meta.url);
const snapshotsDir = new URL("snapshots/", fixtureDir);

const phaseArg = process.argv.includes("--phase")
  ? (process.argv[process.argv.indexOf("--phase") + 1] as Phase)
  : undefined;

const phases: Phase[] = phaseArg ? [phaseArg] : ["default", "limited"];

async function main() {
  console.log("Applying fixture schema + seed...");
  await applyFixture(fixtureDir);

  for (const phase of phases) {
    console.log(`Tracking Hasura metadata for phase '${phase}'...`);
    await trackDatabase(phaseConfigs[phase]);

    const phaseCases = allCases.filter((c) =>
      (c.phases ?? ["default"]).includes(phase)
    );
    console.log(`Recording ${phaseCases.length} cases for phase '${phase}'...`);

    const dir = new URL(`${phase}/`, snapshotsDir);
    await rm(dir, { recursive: true, force: true });
    await mkdir(dir, { recursive: true });

    for (const corpusCase of phaseCases) {
      const response = await runCase(hasuraUrl, corpusCase);
      const snapshot = {
        role: corpusCase.role ?? "public",
        request: {
          query: corpusCase.query,
          ...(corpusCase.variables !== undefined && {
            variables: corpusCase.variables,
          }),
          ...(corpusCase.operationName !== undefined && {
            operationName: corpusCase.operationName,
          }),
        },
        status: response.status,
        body: response.body,
      };
      await writeFile(
        new URL(`${corpusCase.name}.json`, dir),
        JSON.stringify(snapshot, null, 1) + "\n"
      );
    }
  }
  console.log("Done.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
