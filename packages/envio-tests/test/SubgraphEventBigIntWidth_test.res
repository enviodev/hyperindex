// graph-node hands a mapping `event.logIndex` (and `transactionLogIndex`) as a
// BigInt built from the log's U256 index, so its bytes are the minimal two's
// complement (chain/ethereum/src/runtime/abi.rs, `BigInt::from_unsigned_u256`,
// stored as `to_signed_bytes_le`). The shim built it with `fromI32`, four bytes,
// so PaulieB14/aave-v4-omnigraph's ids `txHash.concat(Bytes.fromBigInt(
// event.logIndex))` ended in `bd000000` where its live deployment's end in
// `bd00`: every one of 176k event entities had another id.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Spoke
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Spoke
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Activity
      abis:
        - name: Spoke
          file: ./abis/Spoke.json
      eventHandlers:
        - event: Supply(uint256)
          handler: handleSupply
      file: ./src/spoke.ts
`,
  ~schema=`
type Activity @entity(immutable: true) {
  id: Bytes!
  note: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Spoke.json",
      `[{"type":"event","name":"Supply","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/spoke.ts",
      `
import { Bytes, Entity, store } from "@graphprotocol/graph-ts";

export function handleSupply(event: any): void {
  let id = event.transaction.hash.concat(Bytes.fromByteArray(Bytes.fromBigInt(event.logIndex)));
  let activity = new Entity();
  activity.setBytes("id", id);
  activity.setString(
    "note",
    [
      event.logIndex.byteLength.toString(),
      Bytes.fromBigInt(event.transactionLogIndex).toHexString(),
      Bytes.fromBigInt(event.block.number).toHexString(),
    ].join(" "),
  );
  store.set("Activity", id.toHexString(), activity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("event.logIndex bytes", () => {
  it("are graph-node's minimal two's complement", async (t) => {
    const indexer = createTestIndexer();
    const hash = "0x" + "ab".repeat(32);
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Spoke",
              event: "Supply",
              params: { amount: 1n },
              block: { number: 258, timestamp: 1760400000 },
              transaction: { hash },
              logIndex: 189,
            },
            {
              contract: "Spoke",
              event: "Supply",
              params: { amount: 2n },
              block: { number: 258, timestamp: 1760400000 },
              transaction: { hash },
              logIndex: 126,
            },
          ],
        },
      },
    });
    const rows = await indexer.Activity.getAll();
    t.expect(rows.map((row) => [row.id, row.note]).sort()).toEqual([
      [hash + "7e", "1 0x7e 0x0201"],
      [hash + "bd00", "2 0xbd00 0x0201"],
    ]);
  });
});
`,
)
