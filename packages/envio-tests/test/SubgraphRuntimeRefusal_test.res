// The §7 rows that can only be reached while a mapping runs, plus the two
// store-boundary conversions the schema translation set up: Timestamp
// microseconds and a Bytes id.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Factory
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pair
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: PairCreated(address,uint256)
          handler: handlePairCreated
        - event: Probe(uint256)
          handler: handleProbe
      file: ./src/factory.ts
templates:
  - kind: ethereum/contract
    name: Pair
    network: mainnet
    source:
      abi: Factory
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: []
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Probe(uint256)
          handler: handleProbe
      file: ./src/pair.ts
`,
  ~schema=`
type Pair @entity {
  id: Bytes!
  createdAt: Timestamp!
  score: Int8!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Factory.json",
      `[{"type":"event","name":"PairCreated","anonymous":false,"inputs":[{"name":"pair","type":"address","indexed":false},{"name":"nonce","type":"uint256","indexed":false}]},{"type":"event","name":"Probe","anonymous":false,"inputs":[{"name":"kind","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/factory.ts",
      `
import { BigInt, DataSourceTemplate, Entity, ethereum, Value, store } from "@graphprotocol/graph-ts";

export function handlePairCreated(event: any): void {
  DataSourceTemplate.create("Pair", [event.params.pair.toHexString()]);

  let pair = new Entity();
  // graph-ts sees a Timestamp as an i64 of microseconds.
  pair.set("createdAt", Value.fromTimestamp(BigInt.fromString("1700000000000000").valueOf()));
  pair.setBigInt("score", BigInt.fromI32(7));
  store.set("Pair", event.params.pair.toHexString(), pair);
}

// Each nonce picks one refusal, so a single mapping covers every §7 row that
// only shows up at access time.
export function handleProbe(event: any): void {
  let kind = event.params.kind.toI32();
  if (kind === 1) {
    event.transactionLogIndex;
  } else if (kind === 2) {
    (store as any).timeTravel();
  } else if (kind === 3) {
    let entity = new Entity();
    entity.sprinkle();
  } else if (kind === 4) {
    // Reached in the register pass too, where no create() has happened.
    ethereum.getBalance(event.address);
  }
}
`,
    ),
    (
      "src/pair.ts",
      `
export { handleProbe } from "./factory.ts";
`,
    ),
  ]),
  ~test=`
import { describe, expect, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const pair = Addresses.mockAddresses[2];

const probe = (kind: bigint) => ({
  chains: {
    1: { simulate: [{ contract: "Factory" as const, event: "Probe" as const, params: { kind } }] },
  },
});

describe("subgraph runtime", () => {
  it("registers a template and round-trips a Timestamp and a Bytes id", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Factory",
              event: "PairCreated",
              params: { pair, nonce: 1n },
            },
          ],
        },
      },
    });

    const stored = await indexer.Pair.getOrThrow(pair.toLowerCase());
    t.expect({
      id: stored.id,
      createdAt: stored.createdAt.toISOString(),
      score: stored.score,
    }).toEqual({
      id: pair.toLowerCase(),
      createdAt: "2023-11-14T22:13:20.000Z",
      score: 7n,
    });
  });

  it("refuses event.transactionLogIndex", async () => {
    await expect(createTestIndexer().process(probe(1n))).rejects.toThrow(
      /doesn't support event.transactionLogIndex yet/,
    );
  });

  it("refuses an unknown graph-ts namespace member", async () => {
    await expect(createTestIndexer().process(probe(2n))).rejects.toThrow(
      /doesn't know the graph-ts API store.timeTravel/,
    );
  });

  it("refuses an unknown entity member", async () => {
    await expect(createTestIndexer().process(probe(3n))).rejects.toThrow(
      /doesn't know the entity member sprinkle/,
    );
  });

  it("refuses a host op reached before dataSource.create()", async () => {
    await expect(createTestIndexer().process(probe(4n))).rejects.toThrow(
      "before dataSource.create() in a handler that creates templates",
    );
  });
});
`,
)
