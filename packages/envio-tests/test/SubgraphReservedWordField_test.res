// graph-cli's codegen names a member after a reserved word with a trailing `_`
// (packages/cli/src/codegen/util.ts `handleReservedWord`): a `class` field is
// `account.class_`, and so is an event parameter called `class`. A loaded
// entity reaches the mapping without its generated prototype (`changetype` in
// the generated `load`), and that read was refused.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Account
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: Opened(string)
          handler: handleOpened
      file: ./src/registry.ts
`

let schema = `
type Account @entity {
  id: ID!
  class: String!
}
`

let abi = `[{"type":"event","name":"Opened","anonymous":false,"inputs":[{"name":"class","type":"string","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Registry.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Registry.json", abi),
    ("generated/.gitkeep", ""),
    (
      "src/registry.ts",
      `
import { Opened } from "../generated/Registry/Registry";
import { Account } from "../generated/schema";

export function handleOpened(event: Opened): void {
  let account = new Account("a");
  account.class_ = event.params.class_;
  account.save();
  let loaded = Account.load("a")!;
  loaded.class_ = loaded.class_ + "!";
  loaded.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a field named after a reserved word", () => {
  it("is read and written as graph-cli names it, on a loaded entity too", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Registry", event: "Opened", params: { class: "gold" } }] } },
    });
    t.expect(await indexer.Account.getAll()).toEqual([{ id: "a", class: "gold!" }]);
  });
});
`,
)
