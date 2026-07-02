/**
 * Differential suite: every corpus case is executed against both real Hasura
 * and `envio serve`; the responses must match exactly.
 *
 * Requires Postgres (5433) and Hasura (8080) to be running — the same
 * services the other e2e tests use. `envio serve` is spawned by the suite.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { allCases } from "./corpus/index.js";
import { phaseConfigs, type Phase } from "./corpus.js";
import { applyFixture, trackDatabase } from "./hasuraSetup.js";
import { hasuraUrl, serveUrl } from "./env.js";
import { runCase, normalize } from "./runner.js";
import { startServe, stopServe, type ServeProcess } from "./serveProcess.js";

const fixtureDir = new URL("../../fixtures/differential/", import.meta.url);

const phases: Phase[] = ["default", "limited"];

describe.sequential("differential", () => {
  beforeAll(async () => {
    await applyFixture(fixtureDir);
  });

  for (const phase of phases) {
    const phaseCases = allCases.filter((c) =>
      (c.phases ?? ["default"]).includes(phase)
    );

    describe.sequential(`phase: ${phase}`, () => {
      let serve: ServeProcess;

      beforeAll(async () => {
        await trackDatabase(phaseConfigs[phase]);
        serve = await startServe(phaseConfigs[phase]);
      }, 120_000);

      afterAll(async () => {
        await stopServe(serve);
      });

      for (const corpusCase of phaseCases) {
        it(corpusCase.name, async () => {
          const [hasura, envio] = await Promise.all([
            runCase(hasuraUrl, corpusCase),
            runCase(serveUrl, corpusCase),
          ]);
          expect(normalize(envio, corpusCase.compare)).toEqual(
            normalize(hasura, corpusCase.compare)
          );
        });
      }
    });
  }
});
