/**
 * Performance parity: `envio serve` must not be slower than the Hasura it
 * replaces, on the same queries, against the same Postgres, at the same
 * moment.
 *
 * `bench.ts` is the detailed instrument — per-case timings and resource use
 * against a stored baseline. This is the gate: a handful of representative
 * queries, measured live against both engines, failing the build if serve
 * regresses past a threshold. Measuring both engines in the same run is what
 * makes it safe to gate on: a slow or noisy CI runner slows both sides, so
 * the ratio holds even when the absolute numbers do not.
 *
 * Requires Postgres (5433) and Hasura (8080); serve is spawned by the suite.
 *
 * One caveat when running this locally: the dev harness builds and loads the
 * DEBUG addon, which is roughly 2.4x slower than the release build CI runs
 * against, and slow enough to swamp what is being measured — compression of a
 * 2 KB response costs ~7 us in release and ~350 us in debug. To measure what
 * ships, build the release library and pin it before starting:
 *
 *   cargo build --release -p envio --lib && cargo build -p envio --lib \
 *     && cp target/release/libenvio.so target/debug/envio.node
 *
 * (the debug build first, so its timestamp stays older than the pinned file
 * and the loader does not overwrite it).
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { writeFile } from "node:fs/promises";
import { allCases } from "./corpus/index.js";
import { phaseConfigs, type CorpusCase } from "./corpus.js";
import { applyFixture, trackDatabase } from "./hasuraSetup.js";
import { hasuraUrl, serveUrl, adminSecret } from "./env.js";
import { startServe, stopServe, type ServeProcess } from "./serveProcess.js";

const fixtureDir = new URL("../../fixtures/differential/", import.meta.url);

/**
 * How much slower than Hasura serve may be, over the corpus as a whole,
 * before the build fails. serve is normally well under 1x; this is loose
 * enough to survive a noisy shared runner and still catch a real regression
 * (an accidental N+1, a lost prepared statement cache, a per-request schema
 * rebuild).
 *
 * The budget is spent on the total rather than per case deliberately: an
 * individual 2 ms query is mostly round trip, so per-case ratios swing on a
 * shared runner and would turn one gate into fourteen chances to flake.
 */
const MAX_RATIO = Number(process.env.ENVIO_PERF_MAX_RATIO ?? 1.5);
const ITERATIONS = Number(process.env.ENVIO_PERF_ITERATIONS ?? 25);
const WARMUP = 5;

interface Timing {
  name: string;
  hasuraMs: number;
  serveMs: number;
  ratio: number;
}

async function once(endpoint: string, corpusCase: CorpusCase): Promise<void> {
  const res = await fetch(`${endpoint}/v1/graphql`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(corpusCase.role === "admin"
        ? { "x-hasura-admin-secret": adminSecret }
        : {}),
    },
    body: JSON.stringify({
      query: corpusCase.query,
      ...(corpusCase.variables !== undefined && {
        variables: corpusCase.variables,
      }),
    }),
  });
  // Drain the body: response size is part of what is being measured.
  await res.text();
}

function median(xs: number[]): number {
  const sorted = [...xs].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)]!;
}

/**
 * Alternates engines on every iteration so any drift over the run (page
 * cache warming, a neighbour stealing CPU) lands on both sides equally.
 */
async function measure(corpusCase: CorpusCase): Promise<Timing> {
  for (let i = 0; i < WARMUP; i++) {
    await once(hasuraUrl, corpusCase);
    await once(serveUrl, corpusCase);
  }
  const hasura: number[] = [];
  const serve: number[] = [];
  for (let i = 0; i < ITERATIONS; i++) {
    const h0 = performance.now();
    await once(hasuraUrl, corpusCase);
    hasura.push(performance.now() - h0);

    const s0 = performance.now();
    await once(serveUrl, corpusCase);
    serve.push(performance.now() - s0);
  }
  const hasuraMs = median(hasura);
  const serveMs = median(serve);
  return { name: corpusCase.name, hasuraMs, serveMs, ratio: serveMs / hasuraMs };
}

const benchCases = allCases.filter(
  (c) =>
    c.bench === true &&
    (c.phases ?? ["default"]).includes("default") &&
    c.transport === undefined &&
    c.knownGap === undefined
);

describe.sequential("performance vs hasura", () => {
  let serve: ServeProcess;
  const timings: Timing[] = [];

  beforeAll(async () => {
    await applyFixture(fixtureDir);
    await trackDatabase(phaseConfigs.default);
    serve = await startServe(phaseConfigs.default);
  }, 180_000);

  afterAll(async () => {
    if (timings.length) {
      const totalHasura = timings.reduce((a, t) => a + t.hasuraMs, 0);
      const totalServe = timings.reduce((a, t) => a + t.serveMs, 0);
      const report = [
        `# Performance vs Hasura`,
        ``,
        `Median of ${ITERATIONS} interleaved iterations per case, both engines`,
        `against the same Postgres in the same run. Budget: ${MAX_RATIO}x.`,
        ``,
        `| case | hasura | serve | ratio |`,
        `| --- | ---: | ---: | ---: |`,
        ...timings.map(
          (t) =>
            `| ${t.name} | ${t.hasuraMs.toFixed(2)} ms | ${t.serveMs.toFixed(2)} ms | ${t.ratio.toFixed(2)}x |`
        ),
        `| **total** | **${totalHasura.toFixed(2)} ms** | **${totalServe.toFixed(2)} ms** | **${(totalServe / totalHasura).toFixed(2)}x** |`,
        ``,
      ].join("\n");
      await writeFile(new URL("../../perf-report.md", import.meta.url), report);
      console.log(report);
    }
    await stopServe(serve);
  });

  it(
    "is not slower than Hasura over the corpus",
    async () => {
      expect(benchCases.length).toBeGreaterThan(0);
      for (const corpusCase of benchCases) {
        timings.push(await measure(corpusCase));
      }
      const hasura = timings.reduce((a, t) => a + t.hasuraMs, 0);
      const serve = timings.reduce((a, t) => a + t.serveMs, 0);
      const ratio = Number((serve / hasura).toFixed(2));
      expect({ withinBudget: ratio <= MAX_RATIO, ratio }).toEqual({
        withinBudget: true,
        ratio,
      });
    },
    benchCases.length * 120_000
  );
});
