// graph codegen's `load()` is `changetype<Stat | null>(store.get(...))`, which
// the shim doesn't retag, so a loaded entity answers through graph-ts' own
// prototype. For a field called `entries` that prototype has TypedMap's
// storage accessor, and `stat.entries.plus(ONE)` read the map's entry list
// instead (hunch-vpm's MarketDayStat: "stat.entries.plus is not a function").
// graph-node runs the generated accessor, which reads and writes the field.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Book
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Book
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Stat
      abis:
        - name: Book
          file: ./abis/Book.json
      eventHandlers:
        - event: Entered(uint256)
          handler: handleEntered
      file: ./src/book.ts
`,
  ~schema=`
type Stat @entity {
  id: ID!
  entries: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Book.json",
      `[{"type":"event","name":"Entered","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/book.ts",
      `
import { BigInt, Entity, Value, ValueKind, store } from "@graphprotocol/graph-ts";

class Stat extends Entity {
  constructor(id: string) {
    super();
    this.set("id", Value.fromString(id));
  }
  save(): void {
    let id = this.get("id");
    assert(id != null, "Cannot save Stat entity without an ID");
    store.set("Stat", id!.toString(), this);
  }
  static load(id: string): Stat | null {
    return changetype<Stat | null>(store.get("Stat", id));
  }
  get entries(): BigInt {
    let value = this.get("entries");
    if (!value || value.kind == ValueKind.NULL) {
      throw new Error("Cannot return null for a required field.");
    } else {
      return value.toBigInt();
    }
  }
  set entries(value: BigInt) {
    this.set("entries", Value.fromBigInt(value));
  }
}

export function handleEntered(event: any): void {
  let stat = Stat.load("day");
  if (stat == null) {
    stat = new Stat("day");
    stat.entries = BigInt.zero();
  }
  stat.entries = stat.entries.plus(BigInt.fromI32(1));
  stat.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a loaded entity with a field called entries", () => {
  it("reads and writes the field, not the map's storage", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Book",
              event: "Entered",
              params: { amount: 1n },
              block: { number: 258, timestamp: 1760400000 },
              logIndex: 3,
            },
            {
              contract: "Book",
              event: "Entered",
              params: { amount: 2n },
              block: { number: 259, timestamp: 1760400012 },
              logIndex: 0,
            },
          ],
        },
      },
    });
    t.expect(await indexer.Stat.getAll()).toEqual([{ id: "day", entries: 2n }]);
  });
});
`,
)
