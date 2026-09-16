// Storage benchmark. Not part of the test run — `node bench.mjs`.
//
// Measures the CPU an indexer process spends on a fixed amount of Postgres
// work. Meant to be run on two checkouts and compared, which is what it was
// written for: the commit before Postgres moved into the addon against the one
// after. `test/BenchAdapter.res` is the only file that has to change between
// them.
//
// Both sides need a release addon — a debug build is slow enough to drown out
// what is being measured:
//
//   SVM_TARGET_PLATFORM=linux-amd64 cargo build --release --lib
//   cp target/release/libenvio.so node_modules/envio-linux-x64/envio.node
//
// and the two tables it writes into, which it does not create itself so that
// both sides start from exactly the same schema:
//
//   psql -h localhost -p 5433 -U postgres -d envio-dev -f bench-schema.sql
//
// `process.cpuUsage()` counts every thread of the process, so the work the
// addon does on its own runtime is counted too — the point is the indexer's
// total cost, not which thread paid it.
import { run } from "./test/WriteBench.res.mjs";
await run();
