// A repo whose own dependency install failed (a dead git dependency in an old
// graph-cli lockfile, a vanished gluegun fork) has no node_modules: no
// graph-cli to run codegen, no mapping library the mappings import. envio
// fetches both into a cache of its own: the library at the version the repo's
// package.json declares (the newest in that range, not the newest overall),
// and a graph-cli, and the repo is left as it was. The registry here is a
// local one the test serves, so no network is needed.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Pool
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.4
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Created(uint256)
          handler: handleCreated
      file: ./src/pool.ts
`

let schema = `
type Probe @entity {
  id: ID!
  value: String!
}
`

let mapping = `
import { Entity, store } from "@graphprotocol/graph-ts";
import { label } from "fake-mapping-lib";
import { codegenSaw } from "../generated/schema";

export function handleCreated(event: any): void {
  let probe = new Entity();
  probe.setString("value", label() + "|" + codegenSaw);
  store.set("Probe", "fetched", probe);
}
`

let test = `
import { describe, it } from "vitest";
import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createTestIndexer } from "envio";

// name -> version -> files
const registry: Record<string, Record<string, Record<string, string>>> = {
  "fake-mapping-lib": {
    "1.2.0": {
      "package.json": '{"name":"fake-mapping-lib","version":"1.2.0","main":"index.ts"}',
      "index.ts": 'export function label(): string { return "lib-1.2.0"; }',
    },
    "2.0.0": {
      "package.json": '{"name":"fake-mapping-lib","version":"2.0.0","main":"index.ts"}',
      "index.ts": 'export function label(): string { return "lib-2.0.0"; }',
    },
  },
  "@graphprotocol/graph-cli": {
    "0.51.0": {
      "package.json": '{"name":"@graphprotocol/graph-cli","version":"0.51.0","type":"module"}',
      "dist/commands/codegen.js": [
        'import { mkdirSync, writeFileSync } from "node:fs";',
        'import path from "node:path";',
        "export default class CodegenCommand {",
        "  static async run(argv) {",
        '    const outputDir = argv[argv.indexOf("--output-dir") + 1];',
        "    mkdirSync(outputDir, { recursive: true });",
        "    // The manifest it reads says apiVersion 0.0.5, which is what 0.5x demands.",
        '    const manifest = (await import("node:fs")).readFileSync(argv[0], "utf8");',
        '    const api = manifest.split("apiVersion: ")[1].slice(0, 5);',
        '    writeFileSync(path.join(outputDir, "schema.ts"), "export const codegenSaw = " + JSON.stringify("graph-cli 0.51.0, apiVersion " + api) + ";");',
        "  }",
        "}",
      ].join(String.fromCharCode(10)),
    },
  },
};

const work = mkdtempSync(path.join(tmpdir(), "envio-registry-"));
const tarballs = new Map<string, string>();
for (const [name, versions] of Object.entries(registry)) {
  for (const [version, files] of Object.entries(versions)) {
    const dir = path.join(work, "src", name.replace("/", "_"), version, "package");
    for (const [file, content] of Object.entries(files)) {
      mkdirSync(path.dirname(path.join(dir, file)), { recursive: true });
      writeFileSync(path.join(dir, file), content);
    }
    const tgz = path.join(work, name.replace("/", "_") + "-" + version + ".tgz");
    execFileSync("tar", ["czf", tgz, "-C", path.dirname(dir), "package"]);
    tarballs.set(name.replace("/", "_") + "-" + version + ".tgz", tgz);
  }
}

describe("a repo whose own install failed", () => {
  it("runs with the mapping library and graph-cli envio fetches", async (t) => {
    const requests: string[] = [];
    const server = createServer((req, res) => {
      const url = decodeURIComponent(req.url ?? "");
      requests.push(url);
      const file = tarballs.get(url.slice(1));
      if (file) {
        res.setHeader("content-type", "application/octet-stream");
        res.end(readFileSync(file));
        return;
      }
      const versions = registry[url.slice(1)];
      if (!versions) {
        res.statusCode = 404;
        res.end("{}");
        return;
      }
      const base = "http://127.0.0.1:" + (server.address() as any).port;
      res.setHeader("content-type", "application/json");
      res.end(
        JSON.stringify({
          name: url.slice(1),
          "dist-tags": { latest: Object.keys(versions).at(-1) },
          versions: Object.fromEntries(
            Object.keys(versions).map((version) => [
              version,
              {
                name: url.slice(1),
                version,
                dist: { tarball: base + "/" + url.slice(1).replace("/", "_") + "-" + version + ".tgz" },
              },
            ]),
          ),
        }),
      );
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    process.env.npm_config_registry = "http://127.0.0.1:" + (server.address() as any).port;
    process.env.ENVIO_SUBGRAPH_CACHE_DIR = path.join(work, "cache");
    try {
      const indexer = createTestIndexer();
      await indexer.process({
        chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 1n } }] } },
      });
      // ^1.0.0 is 1.2.0, not the 2.0.0 that is newest; the manifest was raised to apiVersion 0.0.5 for codegen only.
      t.expect(await indexer.Probe.getAll()).toEqual([
        { id: "fetched", value: "lib-1.2.0|graph-cli 0.51.0, apiVersion 0.0.5" },
      ]);
      // Fetched into the cache envio owns, not into the repo.
      t.expect(existsSync(path.join(work, "cache", "packages"))).toBe(true);
      t.expect(existsSync(path.join(work, "cache", "graph-cli", "0.51.0"))).toBe(true);
    } finally {
      server.close();
    }
  }, 120_000);
});
`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([
    (
      "abis/Pool.json",
      `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    ("package.json", `{"name":"pool","dependencies":{"fake-mapping-lib":"^1.0.0"}}`),
    ("subgraph.yaml", manifest),
    ("src/pool.ts", mapping),
  ]),
  ~test,
)
