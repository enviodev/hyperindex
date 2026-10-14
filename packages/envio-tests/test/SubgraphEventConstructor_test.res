// A mapping can build graph-ts' chain objects itself: Notional's polling block
// handler synthesizes an event, `new ethereum.Event(address, 0, 0, null, block,
// new ethereum.Transaction(...), [], null)`, and hands it to the code its event
// handlers share. The shim's `ethereum.Event` constructor was its own internal
// `(raw, kind)`, so `event.block` came back empty, and `ethereum.Block` and
// `ethereum.Transaction` had no constructor at all.
// handleOnce hands its block to a constructor, which counts as a read of the
// header; a simulated chain has no head for the resulting lag to trail.
%%raw(`process.env.ENVIO_SUBGRAPH_BLOCK_LAG = "0"`)

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.8
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 100
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Seen
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      blockHandlers:
        - handler: handleOnce
          filter:
            kind: once
      file: ./src/registry.ts
`,
  ~schema=`
type Seen @entity {
  id: ID!
  description: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"a","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Address, BigInt, Bytes, Entity, ethereum, store } from "@graphprotocol/graph-ts";

function describe(id: string, event: ethereum.Event): void {
  let entity = new Entity();
  entity.setString(
    "description",
    [
      event.address.toHexString(),
      event.logIndex.toString(),
      event.block.number.toString(),
      event.transaction.hash.toHexString(),
      event.transaction.from.toHexString(),
      event.parameters.length.toString(),
      event.receipt == null ? "no-receipt" : "receipt",
    ].join("|"),
  );
  store.set("Seen", id, entity);
}

export function handlePing(event: ethereum.Event): void {
  let entity = new Entity();
  entity.setString(
    "description",
    [event.address.toHexString(), event.logIndex.toString(), event.block.number.toString()].join("|"),
  );
  store.set("Seen", "event", entity);
}

export function handleOnce(block: ethereum.Block): void {
  let transaction = new ethereum.Transaction(
    Bytes.fromHexString("0x"),
    BigInt.zero(),
    Address.zero(),
    null,
    BigInt.zero(),
    BigInt.zero(),
    BigInt.zero(),
    Bytes.fromHexString("0x"),
    BigInt.zero(),
  );
  let synthetic = new ethereum.Event(
    Address.fromString("0x3333333333333333333333333333333333333333"),
    BigInt.fromI32(0),
    BigInt.fromI32(0),
    null,
    block,
    transaction,
    [],
    null,
  );
  describe("synthetic", synthetic);

  let built = new ethereum.Block(
    Bytes.fromHexString("0x01"),
    Bytes.fromHexString("0x02"),
    Bytes.fromHexString("0x03"),
    Address.zero(),
    Bytes.fromHexString("0x04"),
    Bytes.fromHexString("0x05"),
    Bytes.fromHexString("0x06"),
    BigInt.fromI32(7),
    BigInt.zero(),
    BigInt.zero(),
    BigInt.fromI32(8),
    BigInt.zero(),
    BigInt.zero(),
    null,
    null,
  );
  let entity = new Entity();
  entity.setString("description", built.hash.toHexString() + "|" + built.number.toString() + "|" + built.timestamp.toString());
  store.set("Seen", "block", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("graph-ts' public chain constructors", () => {
  it("build an event, a block and a transaction a mapping can read back", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 100,
          endBlock: 120,
          simulate: [{ contract: "Registry", event: "Ping", params: { a: 1n }, block: { number: 110 }, logIndex: 4 }],
        },
      },
    });

    const rows = Object.fromEntries((await indexer.Seen.getAll()).map((row: any) => [row.id, row.description]));
    t.expect(rows).toEqual({
      synthetic:
        "0x3333333333333333333333333333333333333333|0|100|0x|0x0000000000000000000000000000000000000000|0|no-receipt",
      block: "0x01|7|8",
      event: "0x1111111111111111111111111111111111111111|4|110",
    });
  });
});
`,
)
