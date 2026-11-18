// A subgraph's `id: Bytes!` is stored as bytes, as graph-node stores it, and so
// is every relation and stored list pointing at such an entity. A mapping
// still names the entity by its hex id: graph-ts' store is keyed by string.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Token
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Account
        - Transfer
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Transfer(address,uint256)
          handler: handleTransfer
      file: ./src/token.ts
`,
  ~schema=`
type Account @entity {
  id: Bytes!
  balance: BigInt!
  transferCount: Int!
  transfers: [Transfer!]! @derivedFrom(field: "from")
  peers: [Account!]!
}

type Transfer @entity {
  id: Bytes!
  from: Account!
  amount: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Transfer","anonymous":false,"inputs":[{"name":"from","type":"address","indexed":false},{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { BigInt, Bytes, Entity, Value, store } from "@graphprotocol/graph-ts";

export function handleTransfer(event: any): void {
  let from: Bytes = event.params.from;
  let transfer = new Entity();
  transfer.setBytes("id", Bytes.fromI32(event.logIndex.toI32()));
  transfer.setBytes("from", from);
  transfer.setBigInt("amount", event.params.amount);
  store.set("Transfer", Bytes.fromI32(event.logIndex.toI32()).toHexString(), transfer);

  let account = store.get("Account", from.toHexString());
  if (account == null) {
    account = new Entity();
    account.setBytes("id", from);
    account.setBigInt("balance", BigInt.zero());
  }
  account.setBigInt("balance", account.getBigInt("balance").plus(event.params.amount));
  account.setI32("transferCount", store.loadRelated("Account", from.toHexString(), "transfers").length);
  account.set("peers", Value.fromBytesArray([from]));
  store.set("Account", from.toHexString(), account);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const FROM = "0x00000000000000000000000000000000000000aa";
const bytes = (hex: string) => Uint8Array.from(Buffer.from(hex.slice(2), "hex"));

describe("a subgraph entity with a Bytes id", () => {
  it("is stored with its id, relations and lists as bytes", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Token", event: "Transfer", params: { from: FROM, amount: 2n }, block: { number: 1 }, logIndex: 1 },
            { contract: "Token", event: "Transfer", params: { from: FROM, amount: 3n }, block: { number: 2 }, logIndex: 2 },
          ],
        },
      },
    });
    const transfers = await indexer.Transfer.getAll();
    t.expect({
      accounts: await indexer.Account.getAll(),
      transfers: transfers.toSorted((a: any, b: any) => a.id[3] - b.id[3]),
    }).toEqual({
      accounts: [{ id: bytes(FROM), balance: 5n, transferCount: 2, peers: [bytes(FROM)] }],
      transfers: [
        { id: bytes("0x01000000"), from_id: bytes(FROM), amount: 2n },
        { id: bytes("0x02000000"), from_id: bytes(FROM), amount: 3n },
      ],
    });
  });
});
`,
)
