// Perf comparison for FetchState buffer accumulation: the merge-dedup approach
// (mergeIntoBuffer — merge a sorted buffer with a maybe-unsorted response,
// inlined comparison, no Array.sort callback) vs. the previous
// concat + native Array.sort(callback) + Set-key dedup.
//
// mergeIntoBuffer isn't exported from the compiled module, so this is a faithful
// JS port of both algorithms (the compiled ReScript is essentially this JS).
//
// Run: node packages/envio/bench/mergeIntoBuffer.bench.mjs

const cmp = (a, b) => {
  if (a.blockNumber !== b.blockNumber) return a.blockNumber < b.blockNumber ? -1 : 1;
  if (a.logIndex !== b.logIndex) return a.logIndex < b.logIndex ? -1 : 1;
  const ia = a.onEventRegistration.index, ib = b.onEventRegistration.index;
  return ia < ib ? -1 : ia > ib ? 1 : 0;
};

function mergeIntoBuffer(buffer, newItems) {
  const n = newItems.length;
  for (let i = 1; i < n; i++) {
    const x = newItems[i]; let j = i - 1;
    while (j >= 0 && cmp(newItems[j], x) > 0) { newItems[j + 1] = newItems[j]; j--; }
    newItems[j + 1] = x;
  }
  const m = buffer.length, merged = []; let last = null;
  const push = (it) => { if (last === null || cmp(last, it) !== 0) { merged.push(it); last = it; } };
  let i = 0, j = 0;
  while (i < m && j < n) { if (cmp(buffer[i], newItems[j]) <= 0) push(buffer[i++]); else push(newItems[j++]); }
  while (i < m) push(buffer[i++]);
  while (j < n) push(newItems[j++]);
  return merged;
}

function concatSortDedup(buffer, newItems) {
  const key = (it) => `${it.blockNumber}:${it.logIndex}:${it.onEventRegistration.index}`;
  const seen = new Set();
  for (const it of buffer) seen.add(key(it));
  const kept = newItems.filter((it) => { const k = key(it); if (seen.has(k)) return false; seen.add(k); return true; });
  const all = buffer.concat(kept);
  all.sort(cmp);
  return all;
}

const mk = (b, l = 0, idx = 0) => ({ kind: 0, blockNumber: b, logIndex: l, onEventRegistration: { index: idx } });
const makeBuffer = (N) => { const a = []; for (let b = 0; b < N; b++) a.push(mk(b)); return a; };
const makeResponse = (start, R) => {
  const a = []; for (let k = 0; k < R; k++) a.push(mk(start + k));
  for (let k = 1; k < R; k += 17) { const t = a[k]; a[k] = a[k - 1]; a[k - 1] = t; } // occasional disorder
  return a;
};

// Correctness: the merge must equal concat + sort + dedup.
{
  const buf = makeBuffer(1000), resp = makeResponse(1000, 200);
  const a = mergeIntoBuffer(buf.slice(), resp.slice());
  const b = concatSortDedup(buf.slice(), resp.slice());
  const eq = a.length === b.length && a.every((x, i) => cmp(x, b[i]) === 0);
  console.log("correctness (merge == concat+sort+dedup):", eq, `len ${a.length}`);
}

function bench(name, fn, buffer, R, iters) {
  const resps = Array.from({ length: iters + 30 }, () => makeResponse(buffer.length, R));
  for (let w = 0; w < 20; w++) fn(buffer, resps[w].slice());
  const t0 = process.hrtime.bigint();
  for (let it = 0; it < iters; it++) fn(buffer, resps[it].slice());
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  console.log(`${name.padEnd(18)} N=${buffer.length} R=${R}  ${((ms / iters) * 1000).toFixed(1)} us/op`);
}

for (const [N, R, iters] of [[1000, 200, 5000], [10000, 200, 3000], [50000, 300, 1000]]) {
  const buf = makeBuffer(N);
  bench("mergeIntoBuffer", mergeIntoBuffer, buf, R, iters);
  bench("concat+sort+set", concatSortDedup, buf, R, iters);
  console.log("");
}
