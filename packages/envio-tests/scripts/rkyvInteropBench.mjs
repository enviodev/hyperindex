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

const median = (xs) => xs.sort((a, b) => a - b)[xs.length >> 1];
const now = () => process.hrtime.bigint();

const measure = (count, runs) => {
  const napi = { prepare: [], take: [] };
  const rkyv = { prepare: [], take: [], decode: [] };
  for (let run = 0; run < runs; run++) {
    let t = now();
    addon.rkyvInteropPrepareNapi(count);
    napi.prepare.push(Number(now() - t));
    t = now();
    const viaNapi = addon.rkyvInteropTakeNapi();
    napi.take.push(Number(now() - t));

    t = now();
    addon.rkyvInteropPrepareRkyv(count);
    rkyv.prepare.push(Number(now() - t));
    t = now();
    const bytes = addon.rkyvInteropTakeRkyv();
    rkyv.take.push(Number(now() - t));
    t = now();
    const viaRkyv = decode(bytes);
    rkyv.decode.push(Number(now() - t));

    if (run === 0 && count > 0) {
      const a = viaNapi.eventItems.at(-1), b = viaRkyv.eventItems.at(-1);
      if (a.srcAddress !== b.srcAddress || a.params.to !== b.params.to || a.params.value !== b.params.value || a.blockNumber !== b.blockNumber)
        throw new Error(`the two paths disagree: ${JSON.stringify([a, b], (_, v) => (typeof v === "bigint" ? `${v}n` : v))}`);
    }
  }
  const us = (xs) => median(xs) / 1000;
  return {
    count,
    napiPrepare: us(napi.prepare),
    napiMain: us(napi.take),
    rkyvPrepare: us(rkyv.prepare),
    rkyvMain: us(rkyv.take) + us(rkyv.decode),
    rkyvDecode: us(rkyv.decode),
  };
};

for (const count of [100, 1_000, 10_000]) measure(count, 30);
console.log("items   | napi worker | napi main | rkyv worker | rkyv main (decode) | main-thread speedup");
for (const count of [100, 1_000, 10_000, 50_000]) {
  const r = measure(count, count >= 10_000 ? 30 : 200);
  console.log(
    `${String(count).padStart(7)} | ${r.napiPrepare.toFixed(0).padStart(8)}µs | ${r.napiMain.toFixed(0).padStart(7)}µs | ${r.rkyvPrepare.toFixed(0).padStart(9)}µs | ${r.rkyvMain.toFixed(0).padStart(8)}µs (${r.rkyvDecode.toFixed(0)}µs) | ${(r.napiMain / r.rkyvMain).toFixed(2)}x`,
  );
}
