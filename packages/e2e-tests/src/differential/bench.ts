/**
 * Per-case benchmark: Hasura vs envio serve on identical data, plus
 * process-level resource usage.
 *
 * This measures TIMING ONLY. Correctness is diffServe.ts's job, checked
 * against the small fixture dataset (schema.sql + seed.sql) — this script
 * runs against whatever dataset is currently loaded, typically the much
 * larger bench-seed.sql, so it must NOT also diff against the (small-
 * dataset) oracle snapshots: unfiltered list queries would spuriously
 * "mismatch" simply because bench-seed.sql added rows.
 *
 * Two modes, so Rust iteration never needs Hasura/Docker running:
 *
 *   --record-baseline   Runs ONLY against Hasura (must be up), captures
 *                        per-case latency stats + Hasura/Postgres resource
 *                        usage, writes fixtures/differential/hasura-baseline.json.
 *                        Run this once per dataset change (e.g. after
 *                        re-seeding bench-seed.sql); Hasura's numbers don't
 *                        change between Rust rebuilds. A --filter'd re-record
 *                        merges into the existing file instead of replacing
 *                        it, so fixing one case's expected behavior doesn't
 *                        discard timings for every other case.
 *
 *   (default)            Runs ONLY against envio serve (must be up) and
 *                        computes speedup against the stored baseline — no
 *                        live Hasura needed.
 *
 * Methodology:
 * - Sampling is time-budgeted: each case runs until min-iters samples are
 *   collected and either the per-case budget is spent or max-iters is hit.
 *   Fast cases get many samples cheaply; slow full-table scans stop early
 *   (their variance is low anyway).
 * - Default concurrency is 1. Cases CAN run on a worker pool
 *   (--concurrency N) for a faster sweep, but per-case numbers get noisy:
 *   the baseline and engine-only runs happen in separate processes at
 *   separate times, so "N cases running concurrently" means a different
 *   MIX of light/heavy queries contends for the one shared Postgres
 *   instance in each run. Verified empirically: cases that looked "2-4x
 *   slower" at --concurrency 6 were actually 1.4-3.8x FASTER when
 *   re-measured at --concurrency 1 — the geomean speedup stayed directionally
 *   right, but individual "which cases regressed" conclusions from a
 *   concurrent sweep are not reliable. Use --concurrency >1 only for a
 *   quick smoke check ("is anything catastrophically slower"), and
 *   --concurrency 1 (the default) for the numbers that go in a report or
 *   drive an optimization decision.
 * - Resource usage is sampled from /proc every 500ms for the relevant
 *   process tree (Hasura container or envio serve) and for Postgres.
 *
 * Usage:
 *   pnpm --filter e2e-tests exec tsx src/differential/bench.ts --record-baseline [--seed]
 *   pnpm --filter e2e-tests exec tsx src/differential/bench.ts
 *     [--all] [--filter substr] [--concurrency N] [--budget-ms N]
 *     [--min-iters N] [--max-iters N]
 */

import { execSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { readFileSync, readdirSync } from "node:fs";
import { allCases } from "./corpus/index.js";
import { hasuraUrl, serveUrl } from "./env.js";
import { runCase } from "./runner.js";
import { runSql } from "./hasuraSetup.js";
import { arg, flag } from "./cliArgs.js";
import type { CorpusCase } from "./corpus.js";

const concurrency = Number(arg("--concurrency") ?? 1);
const budgetMs = Number(arg("--budget-ms") ?? 1500);
const minIters = Number(arg("--min-iters") ?? 3);
const maxIters = Number(arg("--max-iters") ?? 30);
const warmupRounds = Number(arg("--warmup") ?? 2);
const filter = arg("--filter");
const recordBaseline = flag("--record-baseline");

const baselinePath = new URL(
  "../../fixtures/differential/hasura-baseline.json",
  import.meta.url
);

interface Stats {
  p50: number;
  p90: number;
  mean: number;
  min: number;
  n: number;
}

function stats(samplesMs: number[]): Stats {
  const s = [...samplesMs].sort((a, b) => a - b);
  const pick = (q: number) => s[Math.min(s.length - 1, Math.floor(q * s.length))]!;
  return {
    p50: pick(0.5),
    p90: pick(0.9),
    mean: s.reduce((a, b) => a + b, 0) / s.length,
    min: s[0]!,
    n: s.length,
  };
}

async function timed(endpoint: string, corpusCase: CorpusCase): Promise<number> {
  const t0 = performance.now();
  await runCase(endpoint, corpusCase);
  return performance.now() - t0;
}

async function benchOne(
  endpoint: string,
  corpusCase: CorpusCase
): Promise<Stats> {
  await runCase(endpoint, corpusCase); // untimed correctness/warm hit
  for (let i = 0; i < warmupRounds; i++) {
    await timed(endpoint, corpusCase);
  }
  const samples: number[] = [];
  const started = performance.now();
  while (true) {
    samples.push(await timed(endpoint, corpusCase));
    const elapsed = performance.now() - started;
    if (samples.length >= maxIters) break;
    if (samples.length >= minIters && elapsed > budgetMs) break;
  }
  return stats(samples);
}

// ---------------------------------------------------------------------------
// /proc resource sampling

interface ProcSnapshot {
  cpuTicks: number;
  rssKb: number;
}

function snapshotPids(pids: number[]): ProcSnapshot {
  let cpuTicks = 0;
  let rssKb = 0;
  for (const pid of pids) {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
      // utime and stime are fields 14 and 15 (1-indexed), after the comm
      // field which may contain spaces — split after the closing paren.
      const after = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      cpuTicks += Number(after[11]) + Number(after[12]);
      const status = readFileSync(`/proc/${pid}/status`, "utf8");
      const m = status.match(/VmRSS:\s+(\d+) kB/);
      if (m) rssKb += Number(m[1]);
    } catch {
      // process exited between listing and reading
    }
  }
  return { cpuTicks, rssKb };
}

function descendantsOf(rootPids: number[]): number[] {
  const byParent = new Map<number, number[]>();
  for (const entry of readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const stat = readFileSync(`/proc/${entry}/stat`, "utf8");
      const after = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      const ppid = Number(after[1]);
      const list = byParent.get(ppid) ?? [];
      list.push(Number(entry));
      byParent.set(ppid, list);
    } catch {
      // raced
    }
  }
  const all = new Set<number>(rootPids);
  const queue = [...rootPids];
  while (queue.length) {
    for (const child of byParent.get(queue.shift()!) ?? []) {
      if (!all.has(child)) {
        all.add(child);
        queue.push(child);
      }
    }
  }
  return [...all];
}

function pidsByCommand(pattern: string): number[] {
  try {
    return execSync(`pgrep -f ${JSON.stringify(pattern)}`, { encoding: "utf8" })
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(Number);
  } catch {
    return [];
  }
}

function postgresPids(): number[] {
  const pids: number[] = [];
  for (const entry of readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const comm = readFileSync(`/proc/${entry}/comm`, "utf8").trim();
      if (comm === "postgres") pids.push(Number(entry));
    } catch {
      // raced
    }
  }
  return pids;
}

function hasuraContainerPid(): number[] {
  for (const name of ["hasura-test", "envio-hasura"]) {
    try {
      const pid = Number(
        execSync(`docker inspect -f '{{.State.Pid}}' ${name} 2>/dev/null`, {
          encoding: "utf8",
        }).trim()
      );
      if (pid > 0) return [pid];
    } catch {
      // try next name
    }
  }
  return [];
}

interface ResourceReport {
  label: string;
  cpuSeconds: number;
  peakRssMb: number;
  avgRssMb: number;
}

class ResourceSampler {
  private tracks: {
    label: string;
    pids: () => number[];
    startCpu: number;
    lastCpu: number;
    peakRssKb: number;
    rssSamples: number[];
  }[] = [];
  private timer?: NodeJS.Timeout;
  private clockTicks = 100;

  constructor(specs: { label: string; pids: () => number[] }[]) {
    try {
      this.clockTicks = Number(
        execSync("getconf CLK_TCK", { encoding: "utf8" }).trim()
      );
    } catch {
      // default 100
    }
    for (const spec of specs) {
      const snap = snapshotPids(spec.pids());
      this.tracks.push({
        label: spec.label,
        pids: spec.pids,
        startCpu: snap.cpuTicks,
        lastCpu: snap.cpuTicks,
        peakRssKb: snap.rssKb,
        rssSamples: snap.rssKb ? [snap.rssKb] : [],
      });
    }
  }

  start() {
    this.timer = setInterval(() => {
      for (const t of this.tracks) {
        const snap = snapshotPids(t.pids());
        t.lastCpu = snap.cpuTicks;
        if (snap.rssKb > 0) {
          t.peakRssKb = Math.max(t.peakRssKb, snap.rssKb);
          t.rssSamples.push(snap.rssKb);
        }
      }
    }, 500);
    this.timer.unref();
  }

  stop(): ResourceReport[] {
    if (this.timer) clearInterval(this.timer);
    return this.tracks.map((t) => ({
      label: t.label,
      cpuSeconds: (t.lastCpu - t.startCpu) / this.clockTicks,
      peakRssMb: t.peakRssKb / 1024,
      avgRssMb:
        t.rssSamples.length === 0
          ? 0
          : t.rssSamples.reduce((a, b) => a + b, 0) / t.rssSamples.length / 1024,
    }));
  }
}

// ---------------------------------------------------------------------------

function selectCases(): CorpusCase[] {
  return allCases.filter(
    (c) =>
      (c.phases ?? ["default"]).includes("default") &&
      (flag("--all") ? c.compare !== "rootSet" : c.bench === true) &&
      (!filter || c.name.includes(filter))
  );
}

async function runPool<T>(
  items: T[],
  worker: (item: T) => Promise<void>
): Promise<void> {
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.max(1, concurrency) }, async () => {
      while (next < items.length) {
        await worker(items[next++]!);
      }
    })
  );
}

interface Baseline {
  recordedAt: string;
  cases: Record<string, Stats>;
  resources: ResourceReport[];
}

async function recordBaselineMode() {
  if (flag("--seed")) {
    console.log("Applying bench-seed.sql (large volume)...");
    const sql = await readFile(
      new URL("../../fixtures/differential/bench-seed.sql", import.meta.url),
      "utf8"
    );
    await runSql(sql);
    console.log("Seeded.");
  }

  const cases = selectCases();
  console.log(
    `Recording Hasura baseline for ${cases.length} cases (budget ${budgetMs}ms/case, ${minIters}-${maxIters} iters, concurrency ${concurrency})\n`
  );
  console.log(
    "This is the only step that needs Hasura/Docker running — the result is\n" +
      "cached to disk so Rust iteration never has to start Hasura again.\n"
  );

  const sampler = new ResourceSampler([
    { label: "hasura", pids: () => descendantsOf(hasuraContainerPid()) },
    { label: "postgres", pids: postgresPids },
  ]);
  sampler.start();

  // Merge into any existing baseline so a filtered re-record (e.g. after
  // fixing one case) doesn't discard timings for every other case.
  let existing: Baseline | undefined;
  try {
    existing = JSON.parse(await readFile(baselinePath, "utf8")) as Baseline;
  } catch {
    existing = undefined;
  }
  const results: Record<string, Stats> = { ...(existing?.cases ?? {}) };
  await runPool(cases, async (c) => {
    const s = await benchOne(hasuraUrl, c);
    results[c.name] = s;
    console.log(`${c.name.padEnd(52)} hasura p50 ${s.p50.toFixed(1).padStart(8)}ms (n=${s.n})`);
  });

  const resources = sampler.stop();
  console.log("\nHasura resource usage during recording:");
  for (const r of resources) {
    console.log(
      `  ${r.label.padEnd(12)} cpu ${r.cpuSeconds.toFixed(1)}s | peak rss ${r.peakRssMb.toFixed(0)} MB | avg rss ${r.avgRssMb.toFixed(0)} MB`
    );
  }

  // Resource usage reflects only the cases just recorded, so only replace
  // the stored figures on a broad (unfiltered) run; a targeted --filter
  // re-record keeps the prior full-sweep numbers.
  const baseline: Baseline = {
    recordedAt: new Date().toISOString(),
    cases: results,
    resources: filter && existing ? existing.resources : resources,
  };

  await writeFile(baselinePath, JSON.stringify(baseline, null, 1) + "\n");
  console.log(`\nBaseline written to ${baselinePath.pathname}`);
  console.log(
    "You can now stop Hasura/Docker and iterate with:\n" +
      "  pnpm --filter e2e-tests exec tsx src/differential/bench.ts"
  );
}

async function engineMode() {
  let baseline: Baseline;
  try {
    baseline = JSON.parse(await readFile(baselinePath, "utf8")) as Baseline;
  } catch {
    console.error(
      `No baseline found at ${baselinePath.pathname}.\n` +
        "Start Hasura once and run:\n" +
        "  pnpm --filter e2e-tests exec tsx src/differential/bench.ts --record-baseline"
    );
    process.exit(1);
  }

  const cases = selectCases();
  console.log(
    `Benchmarking envio serve for ${cases.length} cases against the recorded Hasura baseline\n` +
      `(from ${baseline.recordedAt}) — no live Hasura needed.\n` +
      "NOTE: this measures TIMING ONLY, against whatever dataset is currently\n" +
      "loaded (e.g. after bench-seed.sql). Correctness is a separate concern —\n" +
      "verify with diffServe.ts against the small fixture dataset (schema.sql +\n" +
      "seed.sql, no bench-seed.sql) BEFORE re-seeding for a benchmark run.\n"
  );

  const servePids = pidsByCommand("bin\\.mjs serve");
  const sampler = new ResourceSampler([
    { label: "envio serve", pids: () => descendantsOf(servePids) },
    { label: "postgres", pids: postgresPids },
  ]);
  sampler.start();
  const sweepStart = performance.now();

  interface CaseResult {
    name: string;
    envio: Stats;
    hasura: Stats | undefined;
    speedup: number | undefined;
  }
  const results: CaseResult[] = [];

  await runPool(cases, async (c) => {
    const envio = await benchOne(serveUrl, c);
    const hasura = baseline.cases[c.name];
    const speedup = hasura ? hasura.p50 / envio.p50 : undefined;
    results.push({ name: c.name, envio, hasura, speedup });
    console.log(
      `${c.name.padEnd(52)} envio p50 ${envio.p50.toFixed(1).padStart(8)}ms` +
        (hasura
          ? ` | hasura(baseline) p50 ${hasura.p50.toFixed(1).padStart(8)}ms | x${speedup!.toFixed(2)}`
          : " | (no baseline)")
    );
  });

  const sweepSeconds = (performance.now() - sweepStart) / 1000;
  const resources = sampler.stop();

  results.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  const withSpeedup = results.filter((r) => r.speedup !== undefined);
  const geomean = withSpeedup.length
    ? Math.exp(
        withSpeedup.reduce((a, r) => a + Math.log(r.speedup!), 0) /
          withSpeedup.length
      )
    : undefined;
  const slower = withSpeedup.filter((r) => r.speedup! < 0.95);
  const missingBaseline = results.filter((r) => r.hasura === undefined);

  console.log(`\nSweep took ${sweepSeconds.toFixed(0)}s`);
  if (geomean !== undefined) {
    console.log(
      `Geometric-mean speedup (p50, envio vs recorded hasura baseline): x${geomean.toFixed(2)}`
    );
  }
  console.log(`Cases where envio serve is >5% slower than baseline: ${slower.length}`);
  for (const r of slower) {
    console.log(
      `  ${r.name}: hasura(baseline) ${r.hasura!.p50.toFixed(1)}ms vs envio ${r.envio.p50.toFixed(1)}ms`
    );
  }
  if (missingBaseline.length > 0) {
    console.log(
      `Cases with no recorded baseline (re-run --record-baseline to cover them): ${missingBaseline.map((r) => r.name).join(", ")}`
    );
  }
  console.log("\nResource usage over the sweep:");
  for (const r of resources) {
    console.log(
      `  ${r.label.padEnd(20)} cpu ${r.cpuSeconds.toFixed(1)}s | peak rss ${r.peakRssMb.toFixed(0)} MB | avg rss ${r.avgRssMb.toFixed(0)} MB`
    );
  }

  const report = [
    `# Differential benchmark — Hasura (recorded baseline) vs envio serve`,
    ``,
    `Baseline recorded ${baseline.recordedAt}. ${cases.length} cases; per-case budget ${budgetMs}ms, ${minIters}-${maxIters} iterations, warmup ${warmupRounds}; case concurrency ${concurrency}; sweep ${sweepSeconds.toFixed(0)}s.`,
    ``,
    `## Resources (envio serve, this sweep)`,
    ``,
    `| process | cpu seconds | peak rss (MB) | avg rss (MB) |`,
    `|---|---|---|---|`,
    ...resources.map(
      (r) =>
        `| ${r.label} | ${r.cpuSeconds.toFixed(1)} | ${r.peakRssMb.toFixed(0)} | ${r.avgRssMb.toFixed(0)} |`
    ),
    ``,
    `## Resources (hasura, at baseline recording time)`,
    ``,
    `| process | cpu seconds | peak rss (MB) | avg rss (MB) |`,
    `|---|---|---|---|`,
    ...baseline.resources.map(
      (r) =>
        `| ${r.label} | ${r.cpuSeconds.toFixed(1)} | ${r.peakRssMb.toFixed(0)} | ${r.avgRssMb.toFixed(0)} |`
    ),
    ``,
    `## Per case`,
    ``,
    `| case | hasura p50 (ms, baseline) | envio p50 (ms) | envio p90 | speedup (p50) | samples |`,
    `|---|---|---|---|---|---|`,
    ...results.map(
      (r) =>
        `| ${r.name} | ${r.hasura ? r.hasura.p50.toFixed(1) : "-"} | ${r.envio.p50.toFixed(1)} | ${r.envio.p90.toFixed(1)} | ${r.speedup ? `x${r.speedup.toFixed(2)}` : "-"} | ${r.envio.n} |`
    ),
    ``,
    geomean !== undefined
      ? `Geometric-mean p50 speedup vs baseline: **x${geomean.toFixed(2)}**; cases >5% slower: **${slower.length}**.`
      : "",
  ].join("\n");
  const out = new URL("../../bench-report.md", import.meta.url);
  await writeFile(out, report + "\n");
  console.log(`\nReport written to ${out.pathname}`);
}

async function main() {
  if (recordBaseline) {
    await recordBaselineMode();
  } else {
    await engineMode();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
