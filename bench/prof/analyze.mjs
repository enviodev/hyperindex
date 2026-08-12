import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const dir = process.argv[2] ?? ".";
const files = readdirSync(dir).filter((f) => f.endsWith(".cpuprofile"));

for (const file of files) {
  const prof = JSON.parse(readFileSync(path.join(dir, file), "utf8"));
  const byId = new Map(prof.nodes.map((n) => [n.id, n]));
  const parentOf = new Map();
  for (const n of prof.nodes) for (const c of n.children ?? []) parentOf.set(c, n.id);

  // self time per node from the sample stream
  const self = new Map();
  let total = 0;
  for (let i = 0; i < prof.samples.length; i++) {
    const dt = prof.timeDeltas[i] ?? 0;
    total += dt;
    const id = prof.samples[i];
    self.set(id, (self.get(id) ?? 0) + dt);
  }

  const label = (n) => {
    const cf = n.callFrame;
    const url = (cf.url ?? "").replace(/^file:\/\/.*\/(packages|node_modules)\//, "$1/");
    return `${cf.functionName || "(anon)"} @ ${url}:${cf.lineNumber + 1}`;
  };

  // aggregate self time by function label
  const byFn = new Map();
  for (const [id, t] of self) {
    const n = byId.get(id);
    if (!n) continue;
    const k = label(n);
    byFn.set(k, (byFn.get(k) ?? 0) + t);
  }

  // aggregate total (inclusive) time by label, walking each sample's stack once
  const inclusive = new Map();
  for (const [id, t] of self) {
    const seen = new Set();
    let cur = id;
    while (cur != null) {
      const n = byId.get(cur);
      if (!n) break;
      const k = label(n);
      if (!seen.has(k)) {
        seen.add(k);
        inclusive.set(k, (inclusive.get(k) ?? 0) + t);
      }
      cur = parentOf.get(cur);
    }
  }

  const ms = (us) => (us / 1000).toFixed(0);
  const pct = (us) => ((100 * us) / total).toFixed(1);
  console.log(`\n##### ${file}  total=${ms(total)}ms samples=${prof.samples.length}`);
  console.log("\n--- top 25 by SELF time");
  for (const [k, t] of [...byFn].sort((a, b) => b[1] - a[1]).slice(0, 25)) {
    console.log(`${ms(t).padStart(7)}ms ${pct(t).padStart(5)}%  ${k}`);
  }
  console.log("\n--- selected INCLUSIVE totals");
  const interesting = [
    "insert", "insertWithRetry", "setUpdatesOrThrow", "setCheckpointsOrThrow",
    "stringify", "JSON.stringify", "convertOrThrow", "encodeValues", "serialize",
    "setOrThrow", "writeBatch", "processEventBatch", "runEventHandlerOrThrow",
    "decode", "parse",
  ];
  for (const [k, t] of [...inclusive].sort((a, b) => b[1] - a[1])) {
    if (interesting.some((i) => k.toLowerCase().includes(i.toLowerCase()))) {
      console.log(`${ms(t).padStart(7)}ms ${pct(t).padStart(5)}%  ${k}`);
    }
  }
}
