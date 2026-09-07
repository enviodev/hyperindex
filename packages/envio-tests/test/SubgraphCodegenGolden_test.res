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

@module("./fixtures/subgraph-codegen/retag.ts")
external retagChangetypeCalls: string => string = "retagChangetypeCalls"

let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:8602")]),
  ~manifest=`
specVersion: 0.0.2
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Margin
    network: ethereum
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Margin
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Margin
          file: ./abis/Margin.json
      eventHandlers:
        - event: LogSetMarginRatio(uint256)
          handler: handleLogSetMarginRatio
      file: ./src/mapping.ts
`,
  ~schema=fixture("schema.graphql"),
  ~files=Dict.fromArray([("abis/Margin.json", fixture("abis/Margin.json"))]),
  ~mappings=Dict.fromArray([
    ("src/mapping.ts", fixture("src/mapping.ts")),
    ("generated/Margin/Margin.ts", fixture("generated/Margin/Margin.ts")->retagChangetypeCalls),
    ("generated/schema.ts", fixture("generated/schema.ts")),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const RATIO_SELECTOR = "0x4f3c1542";
const RATIO_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000064";

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
      res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: "0x1" }));
    });
  });
  await new Promise<void>((resolve) => server.listen(8602, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("graph codegen goldens", () => {
  it("runs generated getMarginRatio() including toTuple()", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Margin", event: "LogSetMarginRatio", params: { marginRatio: 1n } },
          ],
        },
      },
    });
    t.expect(await indexer.Probe.getOrThrow("ratio")).toEqual({
      id: "ratio",
      name: "100",
    });
  });
});
`,
)
