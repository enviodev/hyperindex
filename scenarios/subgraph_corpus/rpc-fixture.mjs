// The RPC a corpus entry's mappings call, so a run costs no RPC queries and
// can't flake on a provider. Answers come from a fixture of an archive node's
// real answers when the entry has one (recording forwards each request to that
// node and keeps what it answered), else from `fake` (fake-calls.mjs). A
// request neither answers is a miss the runner fails the entry on.
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

// What the subgraph runtime asks at a block number, so the answer never
// changes. Anything else (heights, logs) would make the endpoint a sync
// source: it is refused, and HyperSync stays the chain's only one.
const FIXED_AT_BLOCK = new Set([
  "eth_call",
  "eth_getBalance",
  "eth_getCode",
  "eth_getBlockByNumber",
  "eth_getTransactionReceipt",
]);

export async function startRpcFixture({ chainId, file, upstream, fake }) {
  const answers = !upstream && file && existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
  const misses = [];
  let synthesized = 0;
  // Recording: what the node answered, and its failures by HTTP status.
  const upstreamStats = { answered: 0, failed: {} };

  const forward = async ({ method, params }) => {
    const response = await fetch(upstream, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    if (!response.ok) return { status: response.status };
    const { result, error } = await response.json();
    return error ? { error } : { result };
  };

  const synthetic = ({ method, params }) => {
    if (method === "eth_getBalance") return { result: "0x1" };
    if (method === "eth_getCode") return { result: "0x6001" };
    const result = method === "eth_call" ? fake(params[0].data ?? params[0].input) : undefined;
    return result === undefined ? undefined : { result };
  };

  const answer = async (request) => {
    if (request.method === "eth_chainId") return { result: `0x${chainId.toString(16)}` };
    if (!FIXED_AT_BLOCK.has(request.method)) {
      return { error: { code: -32601, message: `${request.method} is not served by the corpus RPC fixture` } };
    }
    const key = JSON.stringify([request.method, request.params ?? []]);
    // A node's failure is passed on with its status, so the runtime backs off
    // on a 429 as it would against the node itself; the runner's per-entry
    // deadline bounds a node that never recovers.
    if (upstream) {
      const reply = await forward(request).catch(() => ({ status: 503 }));
      if ("status" in reply) {
        upstreamStats.failed[reply.status] = (upstreamStats.failed[reply.status] ?? 0) + 1;
        return reply;
      }
      upstreamStats.answered++;
      answers[key] = reply;
      return reply;
    }
    if (key in answers) return answers[key];
    const made = fake && synthetic(request);
    if (made) {
      synthesized++;
      return made;
    }
    misses.push(key);
    return undefined;
  };

  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", async () => {
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch {
        res.writeHead(400).end();
        return;
      }
      const requests = Array.isArray(parsed) ? parsed : [parsed];
      const replies = await Promise.all(requests.map(answer));
      // A miss or an upstream failure answers like a failing node, which the
      // runtime retries rather than handing a mapping a revert.
      if (replies.some((reply) => reply === undefined || "status" in reply)) {
        const limited = replies.some((reply) => reply?.status === 429);
        res.writeHead(limited ? 429 : 503).end();
        return;
      }
      const wrapped = replies.map((reply, index) => ({ jsonrpc: "2.0", id: requests[index].id, ...reply }));
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(Array.isArray(parsed) ? wrapped : wrapped[0]));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));

  return {
    url: `http://127.0.0.1:${server.address().port}`,
    misses,
    synthesized: () => synthesized,
    upstreamStats: () => upstreamStats,
    async close() {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      if (upstream && Object.keys(answers).length > 0) {
        mkdirSync(path.dirname(file), { recursive: true });
        const sorted = Object.fromEntries(Object.entries(answers).sort(([a], [b]) => a.localeCompare(b)));
        writeFileSync(file, `${JSON.stringify(sorted, null, 1)}\n`);
      }
    },
  };
}
