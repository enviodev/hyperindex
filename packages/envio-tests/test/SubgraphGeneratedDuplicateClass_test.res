// graph codegen names an ABI's contract binding after the ABI and each event
// class after its event, so osr21/arc-relay-bridge's ABI "Memo", which has an
// event Memo, gets two `export class Memo` in generated/MemoContract/Memo.ts.
// asc refuses the file (TS2300 Duplicate identifier), so `graph build` fails on
// it too; envio failed with Node's "Identifier '__envio_define_Memo' has
// already been declared", naming neither the file nor the reason.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: MemoContract
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Memo
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - MemoEvent
      abis:
        - name: Memo
          file: ./abis/Memo.json
      eventHandlers:
        - event: Memo(indexed address,uint256)
          handler: handleMemo
      file: ./src/memo.ts
`

let schema = `
type MemoEvent @entity {
  id: ID!
}
`

let abi = `[{"type":"event","name":"Memo","anonymous":false,"inputs":[{"name":"sender","type":"address","indexed":true},{"name":"memoIndex","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Memo.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Memo.json", abi),
    (
      "src/memo.ts",
      `
import { Memo } from "../generated/MemoContract/Memo";
import { MemoEvent } from "../generated/schema";

export function handleMemo(event: Memo): void {
  new MemoEvent(event.params.memoIndex.toString()).save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a generated file that declares a class twice", () => {
  it("names the file, the class and why graph build fails too", async (t) => {
    const indexer = createTestIndexer();
    const message = await indexer
      .process({ chains: { 1: { simulate: [] } } })
      .then(() => "processed", (error) => String(error.message).replace(/\\/[^\\s']*envio-subgraph-[^/\\s']+/g, "<root>"));

    t.expect(message).toBe(
      "Envio Subgraph failed to load the mapping ./src/memo.ts.\\n" +
        "  <root>/generated/MemoContract/Memo.ts declares the class Memo twice (lines 5 and 28). " +
        "asc refuses that (TS2300 Duplicate identifier), so \`graph build\` fails on this file as well. " +
        'graph codegen names the contract binding after the ABI ("Memo") and each event class after its event, ' +
        "so an ABI with an event of its own name gets two.",
    );
  });
});
`,
)
