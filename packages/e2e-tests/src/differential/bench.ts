/**
 * Per-case benchmark: Hasura vs envio serve on identical data.
 *
 * Prereqs: Postgres fixture applied, Hasura tracked (record:differential
 * does both), bench-seed.sql applied (pass --seed to apply it), Hasura on
 * :8080 and `envio serve` on :8081 both running.
 *
 * Usage:
 *   pnpm --filter e2e-tests exec tsx src/differential/bench.ts [--seed]
 *     [--filter substr] [--iterations N] [--concurrency C] [--all]
 *
 * By default runs corpus cases marked `bench: true`; --all runs every
 * deterministic corpus case in the default phase.
 */

import { readFile, writeFile } from "node:fs/promises";
import { allCases } from "./corpus/index.js";
import { hasuraUrl, serveUrl } from "./env.js";
import { runCase } from "./runner.js";
import { runSql } from "./hasuraSetup.js";
import type { CorpusCase } from "./corpus.js";

const argv = process.argv.slice(2);
const flag = (name: string) => argv.includes(name);
const arg = (name: string): string | undefined => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

const iterations = Number(arg("--iterations") ?? 30);
const warmup = Number(arg("--warmup") ?? 5);
const concurrency = Number(arg("--concurrency") ?? 1);
const filter = arg("--filter");

interface Stats {
  p50: number;
  p90: number;
  p99: number;
  mean: number;
  min: number;
}

function stats(samplesMs: number[]): Stats {
  const s = [...samplesMs].sort((a, b) => a - b);
  const pick = (q: number) => s[Math.min(s.length - 1, Math.floor(q * s.length))]!;
  return {
    p50: pick(0.5),
    p90: pick(0.9),
    p99: pick(0.99),
    mean: s.reduce((a, b) => a + b, 0) / s.length,
    min: s[0]!,
  };
}

async function benchEndpoint(
  endpoint: string,
  corpusCase: CorpusCase
): Promise<Stats> {
  for (let i = 0; i < warmup; i++) {
    await runCase(endpoint, corpusCase);
  }
  const samples: number[] = [];
  if (concurrency <= 1) {
    for (let i = 0; i < iterations; i++) {
      const t0 = performance.now();
      await runCase(endpoint, corpusCase);
      samples.push(performance.now() - t0);
    }
  } else {
    for (let batch = 0; batch < Math.ceil(iterations / concurrency); batch++) {
      const t0 = performance.now();
      await Promise.all(
        Array.from({ length: concurrency }, () => runCase(endpoint, corpusCase))
      );
      const dt = performance.now() - t0;
      for (let i = 0; i < concurrency; i++) samples.push(dt);
    }
  }
  return stats(samples);
}

async function main() {
  if (flag("--seed")) {
    console.log("Applying bench-seed.sql (large volume, ~30s)...");
    const sql = await readFile(
      new URL("../../fixtures/differential/bench-seed.sql", import.meta.url),
      "utf8"
    );
    await runSql(sql);
    console.log("Seeded.");
  }

  const cases = allCases.filter(
    (c) =>
      (c.phases ?? ["default"]).includes("default") &&
      (flag("--all") ? c.compare !== "rootSet" : c.bench === true) &&
      (!filter || c.name.includes(filter))
  );

  console.log(
    `Benchmarking ${cases.length} cases (${iterations} iters, warmup ${warmup}, concurrency ${concurrency})\n`
  );

  const rows: {
    name: string;
    hasura: Stats;
    envio: Stats;
    speedup: number;
    matches: boolean;
  }[] = [];

  for (const corpusCase of cases) {
    const [h, e] = [
      await runCase(hasuraUrl, corpusCase),
      await runCase(serveUrl, corpusCase),
    ];
    const matches = JSON.stringify(h.body) === JSON.stringify(e.body);
    const hasura = await benchEndpoint(hasuraUrl, corpusCase);
    const envio = await benchEndpoint(serveUrl, corpusCase);
    const speedup = hasura.p50 / envio.p50;
    rows.push({ name: corpusCase.name, hasura, envio, speedup, matches });
    console.log(
      `${corpusCase.name.padEnd(46)} hasura p50 ${hasura.p50.toFixed(1).padStart(7)}ms | envio p50 ${envio.p50.toFixed(1).padStart(7)}ms | x${speedup.toFixed(2)}${matches ? "" : "  (RESPONSE MISMATCH)"}`
    );
  }

  const geomean = Math.exp(
    rows.reduce((a, r) => a + Math.log(r.speedup), 0) / rows.length
  );
  const slower = rows.filter((r) => r.speedup < 0.95);
  console.log(`\nGeometric-mean speedup (p50, envio vs hasura): x${geomean.toFixed(2)}`);
  console.log(`Cases where envio serve is >5% slower: ${slower.length}`);
  for (const r of slower) {
    console.log(
      `  ${r.name}: hasura ${r.hasura.p50.toFixed(1)}ms vs envio ${r.envio.p50.toFixed(1)}ms`
    );
  }

  const report = [
    `# Differential benchmark — Hasura vs envio serve`,
    ``,
    `Iterations: ${iterations}, warmup: ${warmup}, concurrency: ${concurrency}`,
    ``,
    `| case | hasura p50 (ms) | envio p50 (ms) | hasura p90 | envio p90 | speedup (p50) | match |`,
    `|---|---|---|---|---|---|---|`,
    ...rows.map(
      (r) =>
        `| ${r.name} | ${r.hasura.p50.toFixed(1)} | ${r.envio.p50.toFixed(1)} | ${r.hasura.p90.toFixed(1)} | ${r.envio.p90.toFixed(1)} | x${r.speedup.toFixed(2)} | ${r.matches ? "yes" : "NO"} |`
    ),
    ``,
    `Geometric-mean p50 speedup: **x${geomean.toFixed(2)}**`,
  ].join("\n");
  const out = new URL("../../bench-report.md", import.meta.url);
  await writeFile(out, report + "\n");
  console.log(`\nReport written to ${out.pathname}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
