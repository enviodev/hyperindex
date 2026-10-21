// Without graph-cli, `envio start` writes generated/ with the bundled codegen
// before the runtime loads, and the runtime then warned that it was running
// "the generated code as it is" because graph-cli can't rebuild it — on every
// start, about a tree envio had written a moment before. A tree that is what
// the bundled codegen writes for this manifest can't be stale; only one that
// differs gets the warning.
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

let abis = ["abis/Margin.json", "abis/ERC20.json", "abis/Registry.json"]

let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", `http://127.0.0.1:${FreePort.pick()}`)]),
  ~manifest=fixture("subgraph.yaml"),
  ~schema=fixture("schema.graphql"),
  ~files=Dict.fromArray(abis->Array.map(file => ("./" ++ file, fixture(file)))),
  ~mappings=Dict.fromArray(
    [
      ("subgraph.yaml", fixture("subgraph.yaml")),
      ("schema.graphql", fixture("schema.graphql")),
      ("src/mapping.ts", fixture("src/mapping.ts")),
      ("src/registry.ts", fixture("src/registry.ts")),
      ("generated/Margin/Margin.ts", fixture("generated-bundled/Margin/Margin.ts")),
      ("generated/Margin/ERC20.ts", fixture("generated-bundled/Margin/ERC20.ts")),
      ("generated/Registry/Registry.ts", fixture("generated-bundled/Registry/Registry.ts")),
      ("generated/schema.ts", fixture("generated-bundled/schema.ts")),
    ]->Array.concat(abis->Array.map(file => (file, fixture(file)))),
  ),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { getLogger, setLogger } from "envio/src/Logging.res.mjs";

const lines: string[] = [];
let installed: unknown;

beforeAll(() => {
  installed = getLogger();
  const capture: any = { level: "info", child: () => capture, isLevelEnabled: () => true };
  for (const level of ["trace", "debug", "info", "warn", "error", "fatal", "udebug", "uinfo", "uwarn", "uerror"]) {
    capture[level] = (params: unknown, message?: string) => {
      lines.push(level + " " + (message ?? (typeof params === "string" ? params : JSON.stringify(params))));
    };
  }
  setLogger(capture);
});

afterAll(() => setLogger(installed));

describe("a generated tree the bundled codegen wrote", () => {
  it("runs without the stale-tree warning", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [] } } });
    t.expect(lines.filter((line) => line.includes("as it is"))).toEqual([]);
  });
});
`,
)
