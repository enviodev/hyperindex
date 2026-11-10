// A data source's block handler that runs on every block gets a register pass
// at every block, so it gets one only when its code surely reaches a template's
// generated class: the create analysis counts anything it can't follow as a
// create, and kiln's vsuite handleBlock, which verifies BLS signatures in a
// module the analysis can't follow and creates nothing, redid the verification
// at every block of the pass and stalled the indexer. A create such a handler
// makes anyway (here through graph-ts's own DataSourceTemplate) is refused where
// it runs, as a template's unfiltered handler's is.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Block
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Events
      startBlock: 1
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Events
          file: ./abis/Events.json
      blockHandlers:
        - handler: handleBlock
      file: ./src/block.ts
templates:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      abi: Events
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Events
          file: ./abis/Events.json
      eventHandlers:
        - event: Epoch(uint256)
          handler: handleEpoch
      file: ./src/block.ts
`,
  ~schema=`
type Probe @entity {
  id: ID!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Events.json",
      `[{"type":"event","name":"Epoch","anonymous":false,"inputs":[{"name":"id","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/block.ts",
      `
import { DataSourceTemplate, ethereum } from "@graphprotocol/graph-ts";

export function handleBlock(block: ethereum.Block): void {
  if (block.number.toI32() == 5) {
    DataSourceTemplate.create("Pool", ["0x3333333333333333333333333333333333333333"]);
  }
}

export function handleEpoch(event: ethereum.Event): void {}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("an unfiltered block handler whose create the analysis isn't sure of", () => {
  it("has no register pass, and its create is refused where it runs", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(indexer.process({ chains: { 1: { startBlock: 1, endBlock: 10, simulate: [] } } }))
      .rejects.toThrow(
        '  Found in data source "Block" → blockHandlers → "handleBlock", which created Pool ' +
          "0x3333333333333333333333333333333333333333 at block 5.",
      );
  });
});
`,
)
