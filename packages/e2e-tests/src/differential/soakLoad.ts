/**
 * Concurrent soak/load test for `envio serve`.
 *
 * Unlike bench.ts (single-connection, per-case latency at concurrency=1),
 * this fires a mixed sample of the corpus at N concurrent workers for an
 * extended duration and watches for the failure modes that only show up
 * under sustained concurrent load: memory leaks (RSS growth), fd leaks,
 * and p99 latency degradation over time. It does not check response
 * correctness (that's diffServe.ts's job) — only that the server stays up,
 * fast, and doesn't 5xx.
 *
 * `envio serve` must already be running (start it yourself, or pass
 * --spawn to have this script start/stop it against scenarios/test_codegen
 * — see serveProcess.ts). Resource monitoring (RSS/fd) needs the server's
 * PID: with --spawn it's known directly; otherwise pass --pid/--pid-file,
 * or this script tries `pgrep -f "bin\.mjs serve"`. If no PID can be
 * found, the load test still runs, just without RSS/fd assertions.
 *
 * Usage:
 *   # quick local iteration (default 60s, concurrency 32)
 *   pnpm --filter e2e-tests exec tsx src/differential/soakLoad.ts --spawn
 *
 *   # real acceptance soak
 *   pnpm --filter e2e-tests exec tsx src/differential/soakLoad.ts \
 *     --duration 2h --concurrency 48 --spawn
 *
 *   # against an already-running server
 *   pnpm --filter e2e-tests exec tsx src/differential/soakLoad.ts \
 *     --duration 30m --concurrency 32 --pid 12345
 *
 * Flags:
 *   --duration MS|Ns|Nm|Nh   total run time (default 60s)
 *   --concurrency N          in-flight worker count (default 32)
 *   --url URL                target base URL (default env.ts serveUrl)
 *   --case-pool bench|all    corpus subset to sample from (default bench)
 *   --filter substr          restrict pool to case names containing substr
 *   --spawn                  spawn+manage envio serve (scenarios/test_codegen)
 *   --pid N                  server PID to monitor (skips auto-discovery)
 *   --pid-file path          read the server PID from a file
 *   --sample-interval MS|Ns  RSS/fd sampling period (default 15s)
 *   --window MS|Ns|Nm        latency time-bucket width (default: duration/6,
 *                            clamped to [5s, 5m])
 *   --warmup-frac F          fraction of run excluded as warmup (default 0.1)
 *   --rss-growth-pct N       fail if RSS grows more than N% (default 20)
 *   --fd-growth-abs N        fail if fd count grows by more than N (default 50)
 *   --fd-growth-pct N        ...or by more than N% of baseline (default 50)
 *   --p99-drift-multiplier N fail if late p99 > N x early p99 (default 2)
 *   --report path            write the markdown report here (default
 *                            <e2e-tests>/soak-report.md)
 */

import { readFileSync, readdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { allCases } from "./corpus/index.js";
import { serveUrl } from "./env.js";
import { runCase } from "./runner.js";
import { startServe, stopServe, type ServeProcess } from "./serveProcess.js";
import { phaseConfigs } from "./corpus.js";
import type { CorpusCase } from "./corpus.js";

// ---------------------------------------------------------------------------
// CLI args

const argv = process.argv.slice(2);
const flag = (name: string) => argv.includes(name);
const arg = (name: string): string | undefined => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

/** Accepts a plain number (ms) or Ns / Nm / Nh (seconds/minutes/hours). */
function parseDuration(input: string): number {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)?$/.exec(input.trim());
  if (!m) throw new Error(`Invalid duration: ${input}`);
  const n = Number(m[1]);
  switch (m[2]) {
    case "h":
      return n * 3_600_000;
    case "m":
      return n * 60_000;
    case "s":
      return n * 1_000;
    case "ms":
    case undefined:
      return n;
    default:
      throw new Error(`Invalid duration unit: ${input}`);
  }
}

const durationMs = parseDuration(arg("--duration") ?? "60s");
const concurrency = Math.max(1, Number(arg("--concurrency") ?? 32));
const targetUrl = arg("--url") ?? serveUrl;
const casePool = (arg("--case-pool") ?? "bench") as "bench" | "all";
const caseFilter = arg("--filter");
const shouldSpawn = flag("--spawn");
const explicitPid = arg("--pid") ? Number(arg("--pid")) : undefined;
const pidFile = arg("--pid-file");
const sampleIntervalMs = parseDuration(arg("--sample-interval") ?? "15s");
const windowMs = arg("--window")
  ? parseDuration(arg("--window")!)
  : Math.min(5 * 60_000, Math.max(5_000, Math.floor(durationMs / 6)));
const warmupFrac = Number(arg("--warmup-frac") ?? 0.1);
const rssGrowthPctThreshold = Number(arg("--rss-growth-pct") ?? 20);
const fdGrowthAbsThreshold = Number(arg("--fd-growth-abs") ?? 50);
const fdGrowthPctThreshold = Number(arg("--fd-growth-pct") ?? 50);
const p99DriftMultiplier = Number(arg("--p99-drift-multiplier") ?? 2);
const reportPath = arg("--report");

// ---------------------------------------------------------------------------
// Case pool

function selectPool(): CorpusCase[] {
  const pool = allCases.filter(
    (c) =>
      (c.phases ?? ["default"]).includes("default") &&
      (casePool === "all" ? c.compare !== "rootSet" : c.bench === true) &&
      (!caseFilter || c.name.includes(caseFilter))
  );
  if (pool.length === 0) {
    throw new Error(
      `No corpus cases matched --case-pool ${casePool}${caseFilter ? ` --filter ${caseFilter}` : ""}`
    );
  }
  return pool;
}

// ---------------------------------------------------------------------------
// Reservoir-sampled latency stats (bounded memory over a multi-hour run)

class Reservoir {
  private samples: number[] = [];
  private seen = 0;
  constructor(private readonly cap: number) {}

  add(value: number) {
    this.seen++;
    if (this.samples.length < this.cap) {
      this.samples.push(value);
    } else {
      const j = Math.floor(Math.random() * this.seen);
      if (j < this.cap) this.samples[j] = value;
    }
  }

  get count(): number {
    return this.seen;
  }

  percentile(q: number): number | undefined {
    if (this.samples.length === 0) return undefined;
    const sorted = [...this.samples].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
  }
}

interface WindowStats {
  index: number;
  startMs: number;
  reservoir: Reservoir;
  count: number;
  errorCount: number;
}

// ---------------------------------------------------------------------------
// Resource (RSS + fd) sampling via /proc — no shelling out, portable to any
// Linux box without extra deps.

interface ResourceSample {
  tMs: number;
  rssKb: number;
  fdCount: number;
}

class ResourceMonitor {
  samples: ResourceSample[] = [];
  private timer?: NodeJS.Timeout;
  private missCount = 0;
  onProcessGone?: () => void;

  constructor(
    private readonly pid: number,
    private readonly startedAt: number
  ) {}

  private snapshot(): ResourceSample | undefined {
    try {
      const status = readFileSync(`/proc/${this.pid}/status`, "utf8");
      const m = /VmRSS:\s+(\d+) kB/.exec(status);
      const rssKb = m ? Number(m[1]) : 0;
      const fdCount = readdirSync(`/proc/${this.pid}/fd`).length;
      this.missCount = 0;
      return { tMs: Date.now() - this.startedAt, rssKb, fdCount };
    } catch {
      return undefined;
    }
  }

  start() {
    const first = this.snapshot();
    if (first) this.samples.push(first);
    this.timer = setInterval(() => {
      const s = this.snapshot();
      if (s) {
        this.samples.push(s);
      } else {
        this.missCount++;
        // A couple of misses can be a raced read; several in a row means
        // the server process has exited mid-soak — that's a hard failure,
        // not a monitoring hiccup.
        if (this.missCount >= 3) this.onProcessGone?.();
      }
    }, sampleIntervalMs);
    this.timer.unref();
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
  }
}

function pidByCommand(pattern: string): number | undefined {
  try {
    const out = execSync(`pgrep -f ${JSON.stringify(pattern)}`, {
      encoding: "utf8",
    })
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(Number);
    return out[0];
  } catch {
    return undefined;
  }
}

// ---------------------------------------------------------------------------

interface RunResult {
  pass: boolean;
  reasons: string[];
}

async function main() {
  const pool = selectPool();
  console.log(
    `Soak load: ${pool.length} corpus cases (pool=${casePool}${caseFilter ? `, filter=${caseFilter}` : ""}), ` +
      `concurrency=${concurrency}, duration=${(durationMs / 1000).toFixed(0)}s, window=${(windowMs / 1000).toFixed(0)}s, target=${targetUrl}`
  );

  let serve: ServeProcess | undefined;
  let pid: number | undefined = explicitPid;

  if (shouldSpawn) {
    console.log("Spawning envio serve (scenarios/test_codegen)...");
    serve = await startServe(phaseConfigs.default);
    pid = serve.child.pid;
    console.log(`envio serve up, pid=${pid}`);
  } else {
    // Confirm the target is actually reachable before burning the whole
    // run against a dead server.
    try {
      const res = await fetch(`${targetUrl}/healthz`);
      if (!res.ok) throw new Error(`status ${res.status}`);
    } catch (err) {
      console.error(
        `${targetUrl}/healthz not reachable (${err instanceof Error ? err.message : err}). ` +
          "Start envio serve first, or pass --spawn."
      );
      process.exit(1);
    }
    if (pid === undefined && pidFile) {
      pid = Number(readFileSync(pidFile, "utf8").trim());
    }
    if (pid === undefined) {
      pid = pidByCommand("bin\\.mjs serve");
    }
  }

  if (pid === undefined) {
    console.warn(
      "WARNING: could not determine envio serve's PID (no --pid/--pid-file, " +
        "no --spawn, and pgrep found no match). Running the load test WITHOUT " +
        "RSS/fd leak assertions — only latency and status-code checks apply."
    );
  } else {
    console.log(`Monitoring resource usage for pid ${pid}`);
  }

  try {
    const result = await runSoak(pool, pid);
    if (!result.pass) {
      console.error("\nSOAK FAILED:");
      for (const r of result.reasons) console.error(`  - ${r}`);
      process.exitCode = 1;
    } else {
      console.log("\nSOAK PASSED");
    }
  } finally {
    await stopServe(serve);
  }
}

async function runSoak(
  pool: CorpusCase[],
  pid: number | undefined
): Promise<RunResult> {
  const startedAt = Date.now();
  const endAt = startedAt + durationMs;

  const globalReservoir = new Reservoir(20_000);
  const windows: WindowStats[] = [];
  const windowFor = (tMs: number): WindowStats => {
    const idx = Math.floor(tMs / windowMs);
    let w = windows[idx];
    if (!w) {
      w = { index: idx, startMs: idx * windowMs, reservoir: new Reservoir(3_000), count: 0, errorCount: 0 };
      windows[idx] = w;
    }
    return w;
  };

  const statusCounts = new Map<number, number>();
  let total = 0;
  let count5xx = 0;
  let networkErrors = 0;

  let monitor: ResourceMonitor | undefined;
  let processDied = false;
  if (pid !== undefined) {
    monitor = new ResourceMonitor(pid, startedAt);
    monitor.onProcessGone = () => {
      processDied = true;
    };
    monitor.start();
  }

  let stopRequested = false;

  const worker = async () => {
    while (!stopRequested && Date.now() < endAt && !processDied) {
      const c = pool[Math.floor(Math.random() * pool.length)]!;
      // Bucket by when the request STARTED, not when it completed — a slow
      // request issued near a window boundary should count against the
      // window that issued it, not skew whichever (possibly tiny, partial)
      // window it happens to land in once it finally finishes.
      const w = windowFor(Date.now() - startedAt);
      const t0 = performance.now();
      let status: number;
      try {
        const res = await runCase(targetUrl, c);
        status = res.status;
      } catch {
        status = 0; // transport-level failure (refused/reset/timeout)
      }
      const latencyMs = performance.now() - t0;

      total++;
      statusCounts.set(status, (statusCounts.get(status) ?? 0) + 1);
      if (status === 0) networkErrors++;
      else if (status >= 500) count5xx++;

      globalReservoir.add(latencyMs);
      w.count++;
      w.reservoir.add(latencyMs);
      if (status === 0 || status >= 500) w.errorCount++;

      if (status === 0) {
        // Back off briefly so a dead server doesn't turn into a hot spin
        // loop that floods logs and pegs a CPU for the rest of the run.
        await new Promise((r) => setTimeout(r, 50));
      }
    }
  };

  const heartbeatEveryMs = Math.min(30_000, windowMs);
  const heartbeat = setInterval(() => {
    const elapsedS = ((Date.now() - startedAt) / 1000).toFixed(0);
    const last = monitor?.samples.at(-1);
    const rss = last ? `${(last.rssKb / 1024).toFixed(0)}MB` : "n/a";
    const fd = last ? String(last.fdCount) : "n/a";
    console.log(
      `[${elapsedS}s] requests=${total} 5xx=${count5xx} netErr=${networkErrors} rss=${rss} fd=${fd}`
    );
  }, heartbeatEveryMs);
  heartbeat.unref();

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  stopRequested = true;
  clearInterval(heartbeat);
  monitor?.stop();

  return buildReport({
    startedAt,
    actualDurationMs: Date.now() - startedAt,
    total,
    count5xx,
    networkErrors,
    statusCounts,
    globalReservoir,
    windows: windows.filter((w): w is WindowStats => w !== undefined),
    resourceSamples: monitor?.samples ?? [],
    processDied,
    pid,
  });
}

interface ReportInput {
  startedAt: number;
  actualDurationMs: number;
  total: number;
  count5xx: number;
  networkErrors: number;
  statusCounts: Map<number, number>;
  globalReservoir: Reservoir;
  windows: WindowStats[];
  resourceSamples: ResourceSample[];
  processDied: boolean;
  pid: number | undefined;
}

function avg(xs: number[]): number | undefined {
  return xs.length === 0 ? undefined : xs.reduce((a, b) => a + b, 0) / xs.length;
}

async function buildReport(input: ReportInput): Promise<RunResult> {
  const reasons: string[] = [];
  const {
    actualDurationMs,
    total,
    count5xx,
    networkErrors,
    statusCounts,
    globalReservoir,
    windows,
    resourceSamples,
    processDied,
    pid,
  } = input;

  if (processDied) {
    reasons.push(
      `envio serve (pid ${pid}) stopped responding on /proc partway through the run — the process likely crashed or exited.`
    );
  }
  if (count5xx > 0) {
    reasons.push(`${count5xx} HTTP 5xx response(s) out of ${total} requests.`);
  }
  if (networkErrors > 0) {
    reasons.push(
      `${networkErrors} transport-level failure(s) (connection refused/reset/timeout) out of ${total} requests.`
    );
  }

  // Latency: compare an early "stabilized" window against the last window.
  // A trailing window can be a sliver (the run stops issuing new requests
  // at the deadline, but a handful of slow in-flight ones still land in
  // whatever window is current) — comparing against a handful of samples
  // is noise, not a trend, so only windows with a representative sample
  // count are eligible for the comparison itself (the full per-window
  // table below still reports every window, sliver or not).
  const warmupEndMs = actualDurationMs * warmupFrac;
  const stabilized = windows.filter((w) => w.startMs >= warmupEndMs);
  const sortedCounts = [...stabilized.map((w) => w.count)].sort((a, b) => a - b);
  const medianCount = sortedCounts[Math.floor(sortedCounts.length / 2)] ?? 0;
  const minReliableCount = Math.max(5, medianCount * 0.4);
  const reliable = stabilized.filter((w) => w.count >= minReliableCount);
  const earlyWindow = reliable[0];
  const lateWindow = reliable.at(-1);
  const earlyP99 = earlyWindow?.reservoir.percentile(0.99);
  const lateP99 = lateWindow?.reservoir.percentile(0.99);
  let p99DriftRatio: number | undefined;
  if (earlyP99 !== undefined && lateP99 !== undefined && earlyP99 > 0) {
    p99DriftRatio = lateP99 / earlyP99;
    if (
      earlyWindow !== lateWindow &&
      p99DriftRatio > p99DriftMultiplier &&
      lateP99 - earlyP99 > 5 // ignore drift entirely within sub-5ms noise
    ) {
      reasons.push(
        `p99 latency drifted from ${earlyP99.toFixed(1)}ms (window ${earlyWindow!.index}) to ${lateP99.toFixed(1)}ms ` +
          `(window ${lateWindow!.index}) — x${p99DriftRatio.toFixed(2)}, threshold x${p99DriftMultiplier}.`
      );
    }
  }

  // RSS / fd: baseline = average over the stabilized window right after
  // warmup; final = average over the last ~10% of the run.
  const postWarmup = resourceSamples.filter((s) => s.tMs >= warmupEndMs);
  const baselineWindowEnd = warmupEndMs + actualDurationMs * 0.2;
  const baselineSamples = postWarmup.filter((s) => s.tMs <= baselineWindowEnd);
  const finalWindowStart = actualDurationMs * 0.9;
  const finalSamples = resourceSamples.filter((s) => s.tMs >= finalWindowStart);

  const rssBaselineKb = avg((baselineSamples.length ? baselineSamples : postWarmup).map((s) => s.rssKb));
  const rssFinalKb = avg((finalSamples.length ? finalSamples : postWarmup).map((s) => s.rssKb));
  let rssGrowthPct: number | undefined;
  if (rssBaselineKb !== undefined && rssFinalKb !== undefined && rssBaselineKb > 0) {
    rssGrowthPct = ((rssFinalKb - rssBaselineKb) / rssBaselineKb) * 100;
    if (rssGrowthPct > rssGrowthPctThreshold) {
      reasons.push(
        `RSS grew ${rssGrowthPct.toFixed(1)}% from stabilized baseline (${(rssBaselineKb / 1024).toFixed(0)}MB -> ${(rssFinalKb / 1024).toFixed(0)}MB), ` +
          `threshold ${rssGrowthPctThreshold}%.`
      );
    }
  }

  const fdBaseline = avg((baselineSamples.length ? baselineSamples : postWarmup).map((s) => s.fdCount));
  const fdFinal = avg((finalSamples.length ? finalSamples : postWarmup).map((s) => s.fdCount));
  let fdGrowthAbs: number | undefined;
  if (fdBaseline !== undefined && fdFinal !== undefined) {
    fdGrowthAbs = fdFinal - fdBaseline;
    const fdThreshold = Math.max(fdGrowthAbsThreshold, fdBaseline * (fdGrowthPctThreshold / 100));
    if (fdGrowthAbs > fdThreshold) {
      reasons.push(
        `Open fd count grew by ${fdGrowthAbs.toFixed(0)} from stabilized baseline (${fdBaseline.toFixed(0)} -> ${fdFinal.toFixed(0)}), ` +
          `threshold ${fdThreshold.toFixed(0)} (max of ${fdGrowthAbsThreshold} abs / ${fdGrowthPctThreshold}% of baseline).`
      );
    }
  }

  const overallP50 = globalReservoir.percentile(0.5);
  const overallP99 = globalReservoir.percentile(0.99);
  const errorRate = total > 0 ? ((count5xx + networkErrors) / total) * 100 : 0;
  const rps = total / (actualDurationMs / 1000);

  const lines: string[] = [];
  lines.push(`# Soak load report`);
  lines.push("");
  lines.push(
    `Duration ${(actualDurationMs / 1000).toFixed(0)}s, concurrency ${concurrency}, target ${targetUrl}, ${total} requests (${rps.toFixed(1)} req/s).`
  );
  lines.push("");
  lines.push(`## Status codes`);
  lines.push("");
  for (const [status, n] of [...statusCounts.entries()].sort((a, b) => a[0] - b[0])) {
    lines.push(`- ${status === 0 ? "transport error" : status}: ${n} (${((n / total) * 100).toFixed(2)}%)`);
  }
  lines.push("");
  lines.push(`Error rate (5xx + transport): **${errorRate.toFixed(3)}%**`);
  lines.push("");
  lines.push(`## Latency`);
  lines.push("");
  lines.push(`Overall p50 ${overallP50?.toFixed(1) ?? "n/a"}ms, p99 ${overallP99?.toFixed(1) ?? "n/a"}ms (n=${globalReservoir.count}).`);
  lines.push("");
  lines.push(`| window | start (s) | requests | errors | p50 (ms) | p99 (ms) |`);
  lines.push(`|---|---|---|---|---|---|`);
  for (const w of windows) {
    lines.push(
      `| ${w.index} | ${(w.startMs / 1000).toFixed(0)} | ${w.count} | ${w.errorCount} | ${w.reservoir.percentile(0.5)?.toFixed(1) ?? "n/a"} | ${w.reservoir.percentile(0.99)?.toFixed(1) ?? "n/a"} |`
    );
  }
  lines.push("");
  if (earlyP99 !== undefined && lateP99 !== undefined) {
    lines.push(
      `p99 drift: window ${earlyWindow!.index} (${earlyP99.toFixed(1)}ms) -> window ${lateWindow!.index} (${lateP99.toFixed(1)}ms), x${p99DriftRatio?.toFixed(2)} (threshold x${p99DriftMultiplier}).`
    );
  } else {
    lines.push(`p99 drift: not enough stabilized windows to compare (run longer than the warmup fraction, or lower --window).`);
  }
  lines.push("");
  lines.push(`## Resource usage (pid ${pid ?? "n/a"})`);
  lines.push("");
  if (resourceSamples.length > 0) {
    const first = resourceSamples[0]!;
    const last = resourceSamples.at(-1)!;
    const peakRssKb = Math.max(...resourceSamples.map((s) => s.rssKb));
    lines.push(
      `RSS: start ${(first.rssKb / 1024).toFixed(0)}MB, stabilized baseline ${rssBaselineKb ? (rssBaselineKb / 1024).toFixed(0) : "n/a"}MB, ` +
        `final ${rssFinalKb ? (rssFinalKb / 1024).toFixed(0) : "n/a"}MB, peak ${(peakRssKb / 1024).toFixed(0)}MB, growth ${rssGrowthPct?.toFixed(1) ?? "n/a"}% (threshold ${rssGrowthPctThreshold}%).`
    );
    lines.push(
      `fd count: start ${first.fdCount}, stabilized baseline ${fdBaseline?.toFixed(0) ?? "n/a"}, final ${last.fdCount}, growth ${fdGrowthAbs?.toFixed(0) ?? "n/a"}.`
    );
  } else if (pid === undefined) {
    lines.push(`No PID available — RSS/fd were not monitored for this run.`);
  } else {
    lines.push(`No resource samples collected for pid ${pid} — it may have exited before the first sample.`);
  }
  lines.push("");
  lines.push(`## Result`);
  lines.push("");
  if (reasons.length === 0) {
    lines.push(`PASS`);
  } else {
    lines.push(`FAIL:`);
    for (const r of reasons) lines.push(`- ${r}`);
  }

  const report = lines.join("\n") + "\n";
  console.log("\n" + report);

  const out = reportPath
    ? new URL(reportPath, `file://${process.cwd()}/`)
    : new URL("../../soak-report.md", import.meta.url);
  await writeFile(out, report);
  console.log(`Report written to ${out.pathname}`);

  return { pass: reasons.length === 0, reasons };
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
