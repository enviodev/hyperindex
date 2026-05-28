// Runs ONE stress matrix cell in the in-memory test harness and prints a single
// JSON line of metrics to stdout. Everything else goes to stderr.
//
//   ENVIO_CONFIG=<generated.yaml> STRESS_START=.. STRESS_END=.. node run-one.mjs
//
// The in-memory harness (createTestIndexer().process) NEVER touches Postgres:
// the worker thread runs the full HyperSync fetch -> NAPI borsh decode ->
// EventRouter dispatch -> handler pipeline, and every entity write is proxied
// back to the main thread and retained in state.processChanges. Worker threads
// share this process's address space, so process RSS (sampled here, and by
// `/usr/bin/time -v` in the wrapper) covers both the worker's decode/table
// memory and the main thread's retained change log -- i.e. the consumer-side
// OOM path from Solana Issues P1.
//
// Two quirks of the current SVM test path are handled here:
//  1. An empty chain config (`{chains:{0:{}}}`) enters auto-exit mode and
//     queries to HEAD; the config `end_block` does NOT bound it. We pass the
//     window EXPLICITLY via process({chains:{0:{startBlock,endBlock}}}).
//  2. Even with an explicit endBlock the run can loop at the window boundary
//     without resolving process() (chunk-range off-by-one vs the inclusive
//     `committed >= endBlock` exit check), so result.changes may never arrive.
//     We therefore race process() against STRESS_BUDGET_MS and read a live
//     matched-instruction count the handler writes to STRESS_COUNT_FILE.

import { readFileSync, rmSync } from "node:fs";

const cfg = process.env.ENVIO_CONFIG;
if (!cfg) {
  console.error("run-one: ENVIO_CONFIG must be set to a generated config path");
  process.exit(2);
}

const startBlock = Number(process.env.STRESS_START ?? 420650000);
const endBlock = Number(process.env.STRESS_END ?? 420650005);
const budgetMs = Number(process.env.STRESS_BUDGET_MS ?? 75000);
const countFile = process.env.STRESS_COUNT_FILE;
if (countFile) {
  try {
    rmSync(countFile);
  } catch {
    /* fresh run */
  }
}

let peakRss = process.memoryUsage().rss;
const sampler = setInterval(() => {
  const rss = process.memoryUsage().rss;
  if (rss > peakRss) peakRss = rss;
}, 100);
sampler.unref?.();

const mb = (b) => Math.round(b / 1048576);
const readCounts = () => {
  if (!countFile) return { matchedIx: 0, tbRows: 0 };
  try {
    return JSON.parse(readFileSync(countFile, "utf8"));
  } catch {
    return { matchedIx: 0, tbRows: 0 };
  }
};

const t0 = Date.now();
let outcome = "pass";
let nodes = 0;
let tokenDeltas = 0;
let flowTxs = 0;
let totalInstructions = 0;
let checkpoints = 0;
let resolved = false;

const { createTestIndexer } = await import("envio");
const indexer = createTestIndexer();

// Detect the boundary-hang: the count stops advancing while process() keeps
// polling empty ranges. Once stable AND the worker has produced data, we treat
// the window as fully fetched and stop (without a clean process() resolve).
let lastCount = -1;
let stableSince = 0;
const STABLE_MS = 8000;
const stuckCheck = () =>
  new Promise((resolve) => {
    const iv = setInterval(() => {
      if (resolved) {
        clearInterval(iv);
        return;
      }
      const { matchedIx } = readCounts();
      if (matchedIx !== lastCount) {
        lastCount = matchedIx;
        stableSince = Date.now();
      } else if (matchedIx > 0 && Date.now() - stableSince >= STABLE_MS) {
        clearInterval(iv);
        resolve("boundary-hang");
      } else if (Date.now() - t0 >= budgetMs) {
        clearInterval(iv);
        resolve("budget");
      }
    }, 500);
    iv.unref?.();
  });

const budget = new Promise((resolve) => {
  const to = setTimeout(() => resolve("budget"), budgetMs);
  to.unref?.();
});

try {
  const proc = indexer
    .process({ chains: { 0: { startBlock, endBlock } } })
    .then((result) => {
      resolved = true;
      return { kind: "resolved", result };
    })
    .catch((e) => {
      resolved = true;
      return { kind: "error", error: e };
    });

  const race = await Promise.race([
    proc,
    stuckCheck().then((why) => ({ kind: why })),
    budget.then(() => ({ kind: "budget" })),
  ]);

  if (race.kind === "resolved") {
    outcome = "pass";
    for (const change of race.result.changes) {
      checkpoints++;
      const n = change.InstructionNode;
      if (n?.sets) nodes += n.sets.length;
      const d = change.TokenDelta;
      if (d?.sets) tokenDeltas += d.sets.length;
      const t = change.FlowTx;
      if (t?.sets) flowTxs += t.sets.length;
      const s = change.IndexerStats;
      if (s?.sets?.length) {
        const ti = Number(s.sets[s.sets.length - 1].totalInstructions);
        if (ti > totalInstructions) totalInstructions = ti;
      }
    }
    totalInstructions = Math.max(totalInstructions, nodes);
  } else if (race.kind === "error") {
    const msg = String(race.error?.message ?? race.error);
    const heap = /heap out of memory|Allocation failed|JS heap/i.test(msg);
    const fellBack = /Svm does not support getting items/i.test(msg);
    outcome = heap ? "oom" : fellBack ? "endpoint-fallback" : "worker-exit";
    console.error("run-one error:", msg.slice(0, 240));
  } else {
    // boundary-hang or budget: data was fetched but process() never resolved.
    outcome = race.kind;
  }
} catch (e) {
  outcome = "error";
  console.error("run-one outer error:", String(e?.message ?? e));
}

clearInterval(sampler);
const wallMs = Date.now() - t0;
const rss = process.memoryUsage().rss;
if (rss > peakRss) peakRss = rss;

const counts = readCounts();
// Prefer the live handler count when process() didn't resolve.
const matchedInstructions = Math.max(totalInstructions, counts.matchedIx ?? 0);
const tokenBalanceRows = Math.max(tokenDeltas, counts.tbRows ?? 0);

const metrics = {
  config: cfg.replace(/^.*\//, ""),
  windowSlots: endBlock - startBlock,
  outcome,
  wallS: +(wallMs / 1000).toFixed(1),
  peakRssMB: mb(peakRss),
  matchedInstructions,
  tokenBalanceRows,
  nodes,
  flowTxs,
  checkpoints,
};
process.stdout.write(JSON.stringify(metrics) + "\n");

// boundary-hang/budget with real data is a successful measurement, not a fail.
const ok = outcome === "pass" || outcome === "boundary-hang" || (outcome === "budget" && matchedInstructions > 0);
// The worker thread keeps the event loop alive when process() hangs; force exit.
process.exit(ok ? 0 : outcome === "oom" ? 137 : 1);
