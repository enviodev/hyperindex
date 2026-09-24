// Executes real `graph codegen` output (test/fixtures/subgraph-codegen).
// That is the surface a mapping imports — `result[0].toTuple()` plus a
// generated Tuple subclass — not a hand-written SmartContract stub.
@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external importMetaUrl: string = "import.meta.url"

let fixture = relativePath =>
  readFileSync(
    pathJoin([
      pathDirname(fileURLToPath(importMetaUrl)),
      "fixtures",
      "subgraph-codegen",
      relativePath,
    ]),
    "utf8",
  )

let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:8602")]),
  ~manifest=fixture("subgraph.yaml"),
  ~schema=fixture("schema.graphql"),
  ~files=Dict.fromArray([
    ("./abis/Margin.json", fixture("abis/Margin.json")),
    ("./abis/ERC20.json", fixture("abis/ERC20.json")),
    ("./abis/Registry.json", fixture("abis/Registry.json")),
  ]),
  ~mappings=Dict.fromArray([
    ("src/mapping.ts", fixture("src/mapping.ts")),
    ("src/registry.ts", fixture("src/registry.ts")),
    ("generated/Margin/Margin.ts", fixture("generated/Margin/Margin.ts")),
    ("generated/Margin/ERC20.ts", fixture("generated/Margin/ERC20.ts")),
    ("generated/Registry/Registry.ts", fixture("generated/Registry/Registry.ts")),
    ("generated/schema.ts", fixture("generated/schema.ts")),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const RATIO_SELECTOR = "0x4f3c1542";
const RATIO_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000064";
const DECIMALS_SELECTOR = "0x313ce567";
const DECIMALS_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000012";

let server: Server;

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      const data: string = request.params?.[0]?.data ?? "";
      if (request.method === "eth_call" && data.startsWith(RATIO_SELECTOR)) {
        res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: RATIO_RESULT }));
        return;
      }
      if (request.method === "eth_call" && data.startsWith(DECIMALS_SELECTOR)) {
        res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: DECIMALS_RESULT }));
        return;
      }
      res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: "0x1" }));
    });
  });
  await new Promise<void>((resolve) => server.listen(8602, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("graph codegen goldens", () => {
  // The ERC-20 binding redeclares its \`value\` parameter in every try_ call,
  // legal AssemblyScript and a syntax error as JavaScript, and its getters
  // are reached through changetype — both exactly as graph codegen wrote them.
  it("runs generated bindings as graph codegen wrote them", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Margin", event: "LogSetMarginRatio", params: { marginRatio: 1n } },
            {
              contract: "Registry",
              event: "Registered",
              params: {
                members: [
                  "0x00000000000000000000000000000000000000aa",
                  "0x00000000000000000000000000000000000000bb",
                ],
                _1: 7n,
              },
            },
          ],
        },
      },
    });
    t.expect(await indexer.Probe.getAll()).toEqual([
      { id: "ratio", name: "100" },
      { id: "decimals", name: "18" },
      { id: "members", name: "0x00000000000000000000000000000000000000bb/7" },
      { id: "parameters", name: "2" },
      { id: "kinds", name: "8,0,4|9,0,7" },
    ]);
  });
});
`,
)
