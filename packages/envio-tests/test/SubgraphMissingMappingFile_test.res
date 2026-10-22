// A manifest naming a mapping file the repo doesn't have (YieldForge's
// `src/vestk.ts`, a pharma tracker's `src/contract.ts`) fails `graph build` with
// "File does not exist". envio reported Node's "Cannot find module … imported
// from runtime.ts", which reads like its own bug; it now names the manifest's
// file.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Vest
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Vest
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Vest
          file: ./abis/Vest.json
      eventHandlers:
        - event: Vested(uint256)
          handler: handleVested
      file: ./src/vestk.ts
`

let schema = `
type Probe @entity {
  id: ID!
}
`

let abi = `[{"type":"event","name":"Vested","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Vest.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Vest.json", abi),
    ("src/vest.ts", `export function handleVested(event: any): void {}
`),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a manifest naming a mapping file the repo lacks", () => {
  it("says which file", async (t) => {
    const indexer = createTestIndexer();
    const message = await indexer
      .process({ chains: { 1: { simulate: [] } } })
      .then(() => "processed", (error) => String(error.message).replace(/\\/[^\\s']*envio-subgraph-[^/\\s'.]+/g, "<root>"));

    t.expect(message).toBe(
      "Envio Subgraph failed to load the mapping ./src/vestk.ts: the manifest names it as a data source's " +
        "mapping file, and there is no such file under <root>. graph-cli refuses the manifest the same way " +
        '("File does not exist").',
    );
  });
});
`,
)
