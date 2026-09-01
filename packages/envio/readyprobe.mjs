import { createServer as createTcp } from "node:net";
import { createResolverPool } from "./src/resolvers/db.js";
import { startResolverServer } from "./src/resolvers/server.js";
const accepted = [];
const bh = createTcp((s) => { s.on("error", () => {}); accepted.push(s); });
await new Promise(r => bh.listen(0, "127.0.0.1", r));
const pool = createResolverPool({
  connection: { host: "127.0.0.1", port: bh.address().port, username: "postgres", password: "t", database: "d" },
  entities: {}, pgSchema: "public", poolSize: 1,
});
const srv = await startResolverServer({ resolvers: [], pool, port: 0 });
const mark = (label, t0) => console.log(label, Date.now() - t0, "ms");
let t0 = Date.now();
const res = await fetch(`http://127.0.0.1:${srv.port}/readyz`);
mark(`readyz ${res.status} ${JSON.stringify(await res.json())}`, t0);
t0 = Date.now(); await srv.close(); mark("server close", t0);
t0 = Date.now(); await pool.end().catch(() => {}); mark("pool end", t0);
t0 = Date.now(); for (const s of accepted) s.destroy(); await new Promise(r => bh.close(r)); mark("blackhole close", t0);
process.exit(0);
