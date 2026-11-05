// An experiment, not a test: entities crossing between JavaScript and Rust on
// the storage path, through the arena as a batch write and a load do today,
// against an rkyv archive written and read by Sury's `S.rkyv`.
//
// - write: `Change.t` values staged into the arena (test/bench/
//   RkyvInteropBench.res, the real `Storage.stageChangesOrThrow`), against the
//   same values encoded by S.rkyv and validated in place by Rust.
// - read: rows Postgres returned, read out of the arena and parsed into
//   entities (`StorageClient.read` and the table's `pgRowsSchema`), against the
//   same rows archived in Rust and decoded by S.rkyv.
//
// Postgres and the Rust side's own work are outside the timings: each measures
// the crossing and the JavaScript on either side of it.
//
//   cargo build --release --lib, staged as node_modules/envio-linux-x64/envio.node
//   ENVIO_PG_PORT=5432 SURY=<sury's index.mjs> node scripts/rkyvStorageBench.mjs

import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";

const require = createRequire(import.meta.url);
const addon = require("envio-linux-x64/envio.node");
const S = await import(process.env.SURY ?? "sury");
const bench = await import("../test/bench/RkyvInteropBench.res.mjs");

const Account = S.schema({
  id: S.string,
  owner: S.string,
  balance: S.string.with(S.to, S.bigint),
  transfers: S.int32,
  active: S.boolean,
  ratio: S.optional(S.number),
});
const Change = S.union([
  S.schema({ type: "SET", entityId: S.string, entity: Account, checkpointId: S.bigint }),
  S.schema({ type: "DELETE", entityId: S.string, checkpointId: S.bigint }),
]);
const encodeChanges = S.encodeOrThrow(S.array(Change), S.rkyv);
const decodeAccounts = S.decodeOrThrow(S.rkyv, S.array(Account));

// The same entities as protobuf messages (PbChanges and PbAccounts in
// rkyv_interop.rs): a change is one message, a delete without its entity.
const F = (schema, number) => schema.with(S.protobufField, number);
const PbAccount = S.schema({
  id: F(S.string, 1),
  owner: F(S.string, 2),
  balance: F(S.string.with(S.to, S.bigint), { number: 3, type: "string" }),
  transfers: F(S.int32, 4),
  active: F(S.boolean, 5),
  ratio: F(S.optional(S.number), 6),
});
const PbChange = S.schema({ type: F(S.string, 4), entityId: F(S.string, 1), entity: F(S.optional(PbAccount), 3), checkpointId: F(S.bigint, 2) });
const encodeChangesProtobuf = S.encodeOrThrow(S.schema({ changes: F(S.array(PbChange), 1) }), S.protobuf);
const decodeAccountsProtobuf = S.decodeOrThrow(S.protobuf, S.schema({ accounts: F(S.array(PbAccount), 1) }));

const address = (seed) => "0x" + (BigInt(seed) * 0x9e3779b97f4a7c15n % (1n << 160n)).toString(16).padStart(40, "0");
const changesOf = (count) =>
  Array.from({ length: count }, (_, i) =>
    i % 10 === 9
      ? { type: "DELETE", entityId: `account-${i}`, checkpointId: BigInt(i) }
      : {
          type: "SET",
          entityId: `account-${i}`,
          entity: {
            id: `account-${i}`,
            owner: address(i * 7),
            balance: BigInt(i) * 10n ** 18n,
            transfers: i % 1000,
            active: i % 3 !== 0,
            ratio: i % 2 === 0 ? i / 7 : undefined,
          },
          checkpointId: BigInt(i),
        },
  );

const median = (xs) => xs.sort((a, b) => a - b)[xs.length >> 1];
const now = () => process.hrtime.bigint();
const show = (x) => JSON.stringify(x, (_, v) => (typeof v === "bigint" ? `${v}n` : v));

const measure = async (count, runs) => {
  const changes = changesOf(count);
  const t = { arenaWrite: [], rkyvWrite: [], protobufWrite: [], arenaRead: [], rkyvRead: [], protobufRead: [] };
  for (let run = 0; run < runs; run++) {
    let start = now();
    const handle = bench.stage(changes);
    t.arenaWrite.push(Number(now() - start));
    bench.discard(handle);

    start = now();
    const sets = addon.rkyvInteropReceiveChanges(encodeChanges(changes));
    t.rkyvWrite.push(Number(now() - start));
    if (sets !== changes.filter((change) => change.type === "SET").length) throw new Error(`Rust read ${sets} sets`);

    start = now();
    const pbSets = addon.rkyvInteropReceiveChangesProtobuf(encodeChangesProtobuf({ changes }));
    t.protobufWrite.push(Number(now() - start));
    if (pbSets !== sets) throw new Error(`Rust read ${pbSets} sets from protobuf`);

    const result = await bench.query(count);
    start = now();
    const viaArena = bench.read(result);
    t.arenaRead.push(Number(now() - start));

    addon.rkyvInteropPrepareAccounts(count);
    start = now();
    const viaRkyv = decodeAccounts(addon.rkyvInteropTakeAccounts());
    t.rkyvRead.push(Number(now() - start));

    addon.rkyvInteropPrepareAccountsProtobuf(count);
    start = now();
    const viaProtobuf = decodeAccountsProtobuf(addon.rkyvInteropTakeAccountsProtobuf()).accounts;
    t.protobufRead.push(Number(now() - start));

    if (run === 0) {
      const a = viaArena.at(-1);
      for (const b of [viaRkyv.at(-1), viaProtobuf.at(-1)])
        if (viaArena.length !== count || show(a) !== show(b)) throw new Error(`the reads disagree: ${show([a, b])}`);
    }
  }
  const us = (xs) => median(xs) / 1000;
  return Object.fromEntries([["count", count], ...Object.entries(t).map(([k, v]) => [k, us(v)])]);
};

for (const count of [100, 1_000, 10_000]) await measure(count, 10);
const results = [];
console.log("entities | write: arena / rkyv / protobuf (µs) | read: arena / rkyv / protobuf (µs)");
for (const count of [100, 1_000, 10_000, 50_000]) {
  const r = await measure(count, count >= 10_000 ? 15 : 60);
  results.push(r);
  const f = (x) => x.toFixed(0);
  console.log(
    `${String(count).padStart(8)} | ${f(r.arenaWrite)} / ${f(r.rkyvWrite)} / ${f(r.protobufWrite)} | ${f(r.arenaRead)} / ${f(r.rkyvRead)} / ${f(r.protobufRead)}`,
  );
}
if (process.env.RESULTS) writeFileSync(process.env.RESULTS, JSON.stringify(results, null, 2));
process.exit(0);
