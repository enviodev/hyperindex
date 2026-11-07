// graph codegen writes, for an entity with a field named `entries`, a class
// whose `entries` accessor overrides graph-ts' TypedMap field of that name
// (Kiln's PeriodRewardSummary). `rs.entries = []` must reach the accessor and
// store the field. The shim kept TypedMap's storage in a plain `entries`
// property, which the assignment replaced: the entity lost its id and
// `save()` failed with "Cannot save ... entity without an ID".
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Core
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Core
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Init
      abis:
        - name: Core
          file: ./abis/Core.json
      eventHandlers:
        - event: PoolInitialized(uint256)
          handler: handlePoolInitialized
      file: ./src/core.ts
`,
  ~schema=`
type Init @entity {
  id: ID!
  entries: [String!]!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Core.json",
      `[{"type":"event","name":"PoolInitialized","anonymous":false,"inputs":[{"name":"poolId","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/core.ts",
      `
import { Entity, Value, store } from "@graphprotocol/graph-ts";

class Init extends Entity {
  constructor(id: string) {
    super();
    this.set("id", Value.fromString(id));
  }
  get entries(): string[] {
    return this.get("entries")!.toStringArray();
  }
  set entries(value: string[]) {
    this.set("entries", Value.fromStringArray(value));
  }
  save(): void {
    let id = this.get("id");
    assert(id != null, "Cannot save Init entity without an ID");
    store.set("Init", id!.toString(), this);
  }
}

export function handlePoolInitialized(event: any): void {
  let init = new Init("one");
  init.entries = ["a", "b"];
  init.save();
  init.entries = init.entries.concat(["c"]);
  init.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("an entity with a field called entries", () => {
  it("keeps its id and stores the field", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Core",
              event: "PoolInitialized",
              params: { poolId: 37n },
              block: { number: 258, timestamp: 1760400000 },
              logIndex: 3,
            },
          ],
        },
      },
    });
    t.expect(await indexer.Init.getAll()).toEqual([{ id: "one", entries: ["a", "b", "c"] }]);
  });
});
`,
)
