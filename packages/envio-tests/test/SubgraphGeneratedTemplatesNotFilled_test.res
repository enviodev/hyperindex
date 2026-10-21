// graph codegen writes generated/templates.ts only for a manifest with
// templates, and generated/schema.ts from the schema: neither is an ABI's
// module. A mapping that imports a template class from a manifest declaring no
// templates fails `graph build`, and must fail to load, even when an ABI
// binding of the same name (the contract class `Pool`) is in the tree: the
// fill that re-exports a generated module for a stale import doesn't stand an
// ABI module in for templates.ts or schema.ts.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Factory
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Factory
          file: ./abis/Factory.json
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: PoolCreated(address)
          handler: handlePoolCreated
      file: ./src/factory.ts
`

let factoryAbi = `[{"type":"event","name":"PoolCreated","anonymous":false,"inputs":[{"name":"pool","type":"address","indexed":false}]}]`

let poolAbi = `[{"type":"event","name":"Swap","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let schema = `
type Probe @entity {
  id: ID!
}
`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Factory.json", factoryAbi), ("abis/Pool.json", poolAbi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Factory.json", factoryAbi),
    ("abis/Pool.json", poolAbi),
    (
      "src/factory.ts",
      `
import { PoolCreated } from "../generated/Factory/Factory";
import { Pool } from "../generated/templates";

export function handlePoolCreated(event: PoolCreated): void {
  Pool.create(event.params.pool);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a template class imported from a manifest without templates", () => {
  it("fails to load rather than reading an ABI binding of that name", async (t) => {
    const indexer = createTestIndexer();
    const message = await indexer
      .process({ chains: { 1: { simulate: [] } } })
      .then(() => "processed", (error) => String(error.message));

    t.expect(message.includes("Cannot find module") && message.includes("generated/templates'")).toBe(true);
  });
});
`,
)
