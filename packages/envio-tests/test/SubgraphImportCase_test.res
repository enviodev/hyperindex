// Omni-DeFi's subgraphs import `../generated/staking/staking`, and graph
// codegen writes `generated/Staking/Staking.ts` for the data source `Staking`.
// asc resolves it on macOS, where the subgraph builds and deploys from; Node
// on Linux didn't find the module.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Staking
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Staking
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Staking
          file: ./abis/Staking.json
      eventHandlers:
        - event: Staked(uint256)
          handler: handleStaked
      file: ./src/staking.ts
`

let abi = `[{"type":"event","name":"Staked","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let schema = `
type Probe @entity {
  id: ID!
  amount: BigInt!
}
`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("./abis/Staking.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Staking.json", abi),
    (
      "src/staking.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { Staked } from "../generated/staking/staking";

export function handleStaked(event: Staked): void {
  let probe = new Entity();
  probe.setBigInt("amount", event.params.amount);
  store.set("Probe", "staked", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("an import of generated code in another case than codegen writes it", () => {
  it("loads the module the filesystem has", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Staking", event: "Staked", params: { amount: 7n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "staked", amount: 7n }]);
  });
});
`,
)
