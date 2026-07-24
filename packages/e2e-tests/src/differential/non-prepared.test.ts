/**
 * Differential suite for the pooler-safe execution path: every corpus case
 * is run against real Hasura and against `envio serve` started with
 * ENVIO_SERVE_USE_PREPARED_STATEMENTS=false (inline params + single
 * text-protocol query). Responses must match exactly — the non-prepared path
 * must be byte-for-byte Hasura-compatible, not just the prepared default.
 *
 * Requires Postgres (5433) and Hasura (8080), same as differential.test.ts.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { allCases } from "./corpus/index.js";
import { phaseConfigs } from "./corpus.js";
import { applyFixture, trackDatabase } from "./hasuraSetup.js";
import { hasuraUrl, serveUrl } from "./env.js";
import { runCase, normalize } from "./runner.js";
import { startServe, stopServe, type ServeProcess } from "./serveProcess.js";

const fixtureDir = new URL("../../fixtures/differential/", import.meta.url);

const defaultCases = allCases.filter((c) =>
  (c.phases ?? ["default"]).includes("default")
);

describe.sequential("differential (non-prepared / pooler-safe path)", () => {
  let serve: ServeProcess;

  beforeAll(async () => {
    await applyFixture(fixtureDir);
    await trackDatabase(phaseConfigs.default);
    serve = await startServe(phaseConfigs.default, {
      ENVIO_SERVE_USE_PREPARED_STATEMENTS: "false",
    });
  }, 120_000);

  afterAll(async () => {
    await stopServe(serve);
  });

  for (const corpusCase of defaultCases) {
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
