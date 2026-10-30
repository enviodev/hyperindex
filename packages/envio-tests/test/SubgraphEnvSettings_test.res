// `ENVIO_SUBGRAPH_RPC`, `ENVIO_SUBGRAPH_NETWORK` and `ENVIO_API_TOKEN` are read
// from the project's `.env` as from the environment, as every envio setting
// is. `ENVIO_SUBGRAPH_BATCH_SIZE` and `ENVIO_SUBGRAPH_BLOCK_LAG` were read from
// the process environment alone, so one set in `.env` did nothing.
open Vitest

// A block handler that reads its block's header in a subgraph with templates
// makes the chain trail its head by the reorg depth; a mapping that calls no
// contract gets envio's batch size.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Clock
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Clock
      startBlock: 100
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Tick
      abis:
        - name: Clock
          file: ./abis/Clock.json
      eventHandlers:
        - event: Tick(uint256)
          handler: handleTick
      blockHandlers:
        - handler: handleBlock
      file: ./src/clock.ts
templates:
  - kind: ethereum/contract
    name: Hand
    network: mainnet
    source:
      abi: Clock
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Tick
      abis:
        - name: Clock
          file: ./abis/Clock.json
      eventHandlers:
        - event: Tick(uint256)
          handler: handleTick
      file: ./src/clock.ts
`

let schema = `
type Tick @entity {
  id: ID!
  gasUsed: BigInt!
}
`

let abi = `[{"type":"event","name":"Tick","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`

let mapping = `
import { Entity, ethereum, store } from "@graphprotocol/graph-ts";

export function handleTick(event: ethereum.Event): void {}

export function handleBlock(block: ethereum.Block): void {
  let tick = new Entity();
  tick.setBigInt("gasUsed", block.gasUsed);
  store.set("Tick", block.number.toString(), tick);
}
`

let settings = (config: Config.t) => {
  let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
  {"batchSize": config.batchSize, "blockLag": chain.blockLag}
}

describe("ENVIO_SUBGRAPH_BATCH_SIZE and ENVIO_SUBGRAPH_BLOCK_LAG", () => {
  it("are read from the project's .env", t => {
    let {config} = InternalTestIndexer.fromSubgraph(
      ~manifest="",
      ~schema="",
      ~fromProjectFiles=true,
      ~mappings=Dict.fromArray([
        ("subgraph.yaml", manifest),
        ("schema.graphql", schema),
        ("abis/Clock.json", abi),
        ("src/clock.ts", mapping),
        (".env", "ENVIO_SUBGRAPH_BATCH_SIZE=7\nENVIO_SUBGRAPH_BLOCK_LAG=0\n"),
      ]),
    )
    t.expect(settings(config)).toEqual({"batchSize": 7, "blockLag": 0})
  })

  it("are read from the environment a subgraph is parsed with", t => {
    let {config} = InternalTestIndexer.fromSubgraph(
      ~env=Dict.fromArray([("ENVIO_SUBGRAPH_BATCH_SIZE", "9"), ("ENVIO_SUBGRAPH_BLOCK_LAG", "3")]),
      ~manifest,
      ~schema,
      ~files=Dict.fromArray([("abis/Clock.json", abi)]),
      ~mappings=Dict.fromArray([("src/clock.ts", mapping)]),
    )
    t.expect(settings(config)).toEqual({"batchSize": 9, "blockLag": 3})
  })
})
