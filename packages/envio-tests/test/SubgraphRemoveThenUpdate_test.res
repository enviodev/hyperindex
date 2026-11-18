// graph-node's own remove-then-update integration test
// (tests/integration-tests/remove-then-update): saving an entity removed
// earlier in the same handler overwrites it — graph-node's EntityOp turns
// Remove + Update into Overwrite — so a field the new save leaves unset is
// null, not the removed entity's value.
let manifest = `
specVersion: 1.0.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Contract
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Contract
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.8
      language: wasm/assemblyscript
      entities:
        - Foo
      abis:
        - name: Contract
          file: ./abis/Contract.json
      eventHandlers:
        - event: Trigger(uint16)
          handler: handleTrigger
      file: ./src/mapping.ts
`

let schema = `
type Foo @entity {
  id: ID!
  value: String
  removed: Boolean!
}
`

let abi = `[{"type":"event","name":"Trigger","anonymous":false,"inputs":[{"name":"x","type":"uint16","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Contract.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Contract.json", abi),
    ("generated/.gitkeep", ""),
    (
      "src/mapping.ts",
      `
import { Trigger } from "../generated/Contract/Contract";
import { store } from "@graphprotocol/graph-ts";
import { Foo } from "../generated/schema";

export function handleTrigger(event: Trigger): void {
  if (event.params.x == 0) {
    create();
  } else if (event.params.x == 1) {
    store.remove("Foo", "0");

    let obj = new Foo("0");
    obj.removed = true;
    obj.save();

    obj = <Foo>Foo.load("0");
    assert(obj.value == null);
  }
}

function create(): void {
  let obj = new Foo("0");
  obj.value = "bla";
  obj.removed = false;
  obj.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("an entity removed and saved again", () => {
  it("keeps none of the removed fields", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Contract", event: "Trigger", params: { x: 0n } },
            { contract: "Contract", event: "Trigger", params: { x: 1n } },
          ],
        },
      },
    });
    t.expect(await indexer.Foo.getAll()).toEqual([{ id: "0", value: null, removed: true }]);
  });
});
`,
)
