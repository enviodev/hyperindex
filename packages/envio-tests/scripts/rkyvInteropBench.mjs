// An experiment, not a test: one page of event items crossing from Rust to JS
// the way `get_items` returns it today (napi objects + a JsTape per params)
// against one rkyv archive read by Sury's `S.rkyv`. See
// packages/cli/src/rkyv_interop.rs.
//
//   cargo build --release --lib
//   SURY=<path to sury's index.mjs> node packages/envio-tests/scripts/rkyvInteropBench.mjs

import { copyFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../../", import.meta.url));
const addonPath = join(tmpdir(), "envio-rkyv-bench.node");
copyFileSync(process.env.ENVIO_ADDON ?? join(root, "target/release/libenvio.so"), addonPath);
const addon = createRequire(import.meta.url)(addonPath);
const S = await import(process.env.SURY ?? "sury");

// alloy's U256, archived by ruint as four u64 limbs.
const U256 = S.bigint.with(S.rkyvType, "U256");

// The Rust structs in rkyv_interop.rs, field for field. i64 reads into a
// number, as napi converts it.
const i64 = S.number.with(S.rkyvType, "i64");
const Page = S.schema({
  archiveHeight: S.optional(i64),
  nextBlock: i64,
  eventItems: S.array(
    S.schema({
      logIndex: i64,
      srcAddress: S.string,
      blockNumber: i64,
      transactionIndex: i64,
      onEventRegistrationIndex: i64,
      params: S.schema({ from: S.string, to: S.string, value: U256 }),
    }),
  ),
  blockItems: S.array(
    S.schema({ blockNumber: i64, onBlockRegistrationIndex: i64, skipped: S.boolean }),
  ),
  responseBlocks: i64,
});
const decode = S.decodeOrThrow(S.rkyv, Page);

// Typed-array columns read the way the storage arena's read side does
// (Reading.res): each into a plain array in one pass, text through Node's
// Buffer#toString over a range rather than a view per row.
const arenaColumns = (columns) => {
  const [logIndex, srcData, srcEnds, blockNumber, transactionIndex, registration, fromData, fromEnds, toData, toEnds, valueData, valueEnds] = columns;
  const count = logIndex.byteLength / 8;
  const floats = (b) => {
    const view = new Float64Array(b.buffer, b.byteOffset, count);
    const out = new Array(count);
    for (let row = 0; row < count; row++) out[row] = view[row];
    return out;
  };
  const texts = (data, ends) => {
    const view = new Uint32Array(ends.buffer, ends.byteOffset, count);
    const out = new Array(count);
    for (let row = 0, start = 0; row < count; row++) {
      const end = view[row];
      out[row] = data.toString("utf8", start, end);
      start = end;
    }
    return out;
  };
  return [
    floats(logIndex), texts(srcData, srcEnds), floats(blockNumber), floats(transactionIndex), floats(registration),
    texts(fromData, fromEnds), texts(toData, toEnds), texts(valueData, valueEnds),
  ];
};

// The arena's rows built by hand, as Reading.res builds them.
const arenaRows = (columns) => {
  const [li, src, bn, ti, ri, from, to, value] = arenaColumns(columns);
  const eventItems = new Array(li.length);
  for (let row = 0; row < li.length; row++) {
    eventItems[row] = {
      logIndex: li[row],
      srcAddress: src[row],
      blockNumber: bn[row],
      transactionIndex: ti[row],
      onEventRegistrationIndex: ri[row],
      params: { from: from[row], to: to[row], value: BigInt(value[row]) },
    };
  }
  return { eventItems };
};

// Rows from columns by Sury: S.compactColumns, the value's digits read into a
// bigint by S.to. Flat: S.compactColumns doesn't apply an S.shape on its row
// schema, so the params can't be nested the way the other paths nest them.
const flatRow = (value) =>
  S.schema({
    logIndex: S.number,
    srcAddress: S.string,
    blockNumber: S.number,
    transactionIndex: S.number,
    onEventRegistrationIndex: S.number,
    from: S.string,
    to: S.string,
    value,
  });
const rowsFromTextColumns = S.decodeOrThrow(S.compactColumns(S.unknown).with(S.to, S.array(flatRow(S.string.with(S.to, S.bigint)))));
const rowsFromColumns = S.decodeOrThrow(S.compactColumns(S.unknown).with(S.to, S.array(flatRow(S.bigint))));
const arenaSury = (columns) => ({ eventItems: rowsFromTextColumns(arenaColumns(columns)) });

// One Vec per field in Rust, read by S.rkyv as a tuple of arrays. A typed tuple
// can't be chained into S.compactColumns (Sury throws compiling the link), so
// the rows are a second operation.
const decodeColumns = S.decodeOrThrow(
  S.rkyv,
  S.tuple([S.array(i64), S.array(S.string), S.array(i64), S.array(i64), S.array(i64), S.array(S.string), S.array(S.string), S.array(U256)]),
);
const rkyvColumns = (bytes) => ({ eventItems: rowsFromColumns(decodeColumns(bytes)) });

const paths = {
  napi: { prepare: (n) => addon.rkyvInteropPrepareNapi(n), take: () => addon.rkyvInteropTakeNapi(), read: (x) => x },
  rkyv: { prepare: (n) => addon.rkyvInteropPrepareRkyv(n), take: () => addon.rkyvInteropTakeRkyv(), read: decode },
  rkyvColumns: { prepare: (n) => addon.rkyvInteropPrepareColumns(n), take: () => addon.rkyvInteropTakeColumns(), read: rkyvColumns },
  arena: { prepare: (n) => addon.rkyvInteropPrepareArena(n), take: () => addon.rkyvInteropTakeArena(), read: arenaRows },
  arenaSury: { prepare: (n) => addon.rkyvInteropPrepareArena(n), take: () => addon.rkyvInteropTakeArena(), read: arenaSury },
};

const median = (xs) => xs.sort((a, b) => a - b)[xs.length >> 1];
const now = () => process.hrtime.bigint();
const same = (a, b) =>
  a.srcAddress === b.srcAddress && a.blockNumber === b.blockNumber && (b.params ?? b).to === a.params.to && (b.params ?? b).value === a.params.value;

const measure = (count, runs) => {
  const times = Object.fromEntries(Object.keys(paths).map((name) => [name, { worker: [], main: [] }]));
  for (let run = 0; run < runs; run++) {
    let reference;
    for (const [name, path] of Object.entries(paths)) {
      let t = now();
      path.prepare(count);
      times[name].worker.push(Number(now() - t));
      t = now();
      const result = path.read(path.take());
      times[name].main.push(Number(now() - t));
      if (run === 0 && count > 0) {
        const last = result.eventItems.at(-1);
        if (reference === undefined) reference = last;
        else if (!same(reference, last))
          throw new Error(`${name} disagrees: ${JSON.stringify([reference, last], (_, v) => (typeof v === "bigint" ? `${v}n` : v))}`);
      }
    }
  }
  const us = (xs) => median(xs) / 1000;
  return { count, ...Object.fromEntries(Object.entries(times).map(([name, t]) => [name, { worker: us(t.worker), main: us(t.main) }])) };
};

for (const count of [100, 1_000, 10_000]) measure(count, 20);
const results = [];
const names = Object.keys(paths);
console.log(`main thread µs (worker µs) | ${names.join(" | ")}`);
for (const count of [100, 1_000, 10_000, 50_000]) {
  const r = measure(count, count >= 10_000 ? 25 : 150);
  results.push(r);
  console.log(`${String(count).padStart(7)} | ${names.map((n) => `${r[n].main.toFixed(0)} (${r[n].worker.toFixed(0)})`).join(" | ")}`);
}
if (process.env.RESULTS) (await import("node:fs")).writeFileSync(process.env.RESULTS, JSON.stringify(results, null, 2));
