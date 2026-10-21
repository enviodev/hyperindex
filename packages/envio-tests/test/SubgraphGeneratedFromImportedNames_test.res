// balancer/cow-amm-subgraph's factory mapping imports LOG_NEW_POOL from
// src/types/Factory/Factory, from when its data source "Factory" named its ABI
// "Factory" (file abis/BFactory.json). The manifest now has data sources
// Factory3 and Factory4 with that ABI named BFactory, so graph codegen writes
// src/types/Factory3/BFactory.ts and src/types/Factory4/BFactory.ts, and
// `graph build` fails on a clean checkout. No manifest has a data source
// "Factory" or an ABI "Factory"; the one generated module the imported name
// comes from is that ABI's (the same code under both data sources), so envio
// writes the file as a re-export of it, with a warning.
let manifest = `
specVersion: 1.0.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory3
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: BFactory
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pool
      abis:
        - name: BFactory
          file: ./abis/BFactory.json
      eventHandlers:
        - event: LOG_NEW_POOL(indexed address,indexed address)
          handler: handleNewPool
      file: ./src/mappings/factory.ts
  - kind: ethereum/contract
    name: Factory4
    network: mainnet
    source:
      address: "0x2222222222222222222222222222222222222222"
      abi: BFactory
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pool
      abis:
        - name: BFactory
          file: ./abis/BFactory.json
      eventHandlers:
        - event: LOG_NEW_POOL(indexed address,indexed address)
          handler: handleNewPool
      file: ./src/mappings/factory.ts
`

let schema = `
type Pool @entity {
  id: Bytes!
  factory: Bytes!
}
`

let abi = `[{"type":"event","name":"LOG_NEW_POOL","anonymous":false,"inputs":[{"name":"caller","type":"address","indexed":true},{"name":"pool","type":"address","indexed":true}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/BFactory.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/BFactory.json", abi),
    (
      "src/mappings/factory.ts",
      `
import { LOG_NEW_POOL } from "../types/Factory/Factory";
import { Pool } from "../types/schema";

export function handleNewPool(event: LOG_NEW_POOL): void {
  let pool = new Pool(event.params.pool);
  pool.factory = event.address;
  pool.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("generated code under a data source and ABI name no manifest has", () => {
  it("re-exports the one generated module with the imported names", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Factory4",
              event: "LOG_NEW_POOL",
              srcAddress: "0x2222222222222222222222222222222222222222",
              params: {
                caller: "0x3333333333333333333333333333333333333333",
                pool: "0x4444444444444444444444444444444444444444",
              },
            },
          ],
        },
      },
    });

    t.expect((await indexer.Pool.getAll()).map((pool) => pool.id)).toEqual([
      "0x4444444444444444444444444444444444444444",
    ]);
  });
});
`,
)
