// NNS imports generated/NNSController/NNSController after renaming that data
// source's ABI IController (so graph codegen now writes NNSController/
// IController.ts), and zerolend's blast points generated/USDBVToken/USDBVToken
// after naming that ABI ERC20: `graph build` fails on a clean checkout, the
// developer's tree had the file from when the ABI bore the data source's name.
// The file is the data source's own ABI under that name, so envio writes it, with
// a warning: its handlers' event classes come from that ABI.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: NNSController
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: IController
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Stake
      abis:
        - name: IController
          file: ./abis/IController.json
      eventHandlers:
        - event: TokenStaked(uint256)
          handler: handleTokenStaked
      file: ./src/staker.ts
`

let schema = `
type Stake @entity {
  id: ID!
}
`

let abi = `[{"type":"event","name":"TokenStaked","anonymous":false,"inputs":[{"name":"tokenId","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/IController.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/IController.json", abi),
    (
      "src/staker.ts",
      `
import { TokenStaked } from "../generated/NNSController/NNSController";
import { Stake } from "../generated/schema";

export function handleTokenStaked(event: TokenStaked): void {
  new Stake(event.params.tokenId.toString()).save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("generated code under an ABI's former name", () => {
  it("is written from the data source's ABI", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "NNSController", event: "TokenStaked", params: { tokenId: 9n } }] } },
    });

    t.expect(await indexer.Stake.getAll()).toEqual([{ id: "9" }]);
  });
});
`,
)
