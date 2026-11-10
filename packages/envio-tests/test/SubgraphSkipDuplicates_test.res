// graph-node v0.43 adds `@entity(immutable: true, skipDuplicates: true)`
// (graph/src/schema/input/mod.rs `SKIP_DUPLICATES`): an insert of an id the
// store already holds from an earlier block is skipped instead of failing the
// subgraph (relational.rs inserts with ON CONFLICT DO NOTHING, and an update
// of such a row is dropped), so the first block's write stands. Saves within
// one block merge in the entity cache first, as for any entity. The argument
// was refused as unknown.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 1.3.0
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
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities:
        - Mint
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Minted(string,uint256)
          handler: handleMinted
      file: ./src/token.ts
`,
  ~schema=`
type Mint @entity(immutable: true, skipDuplicates: true) {
  id: ID!
  amount: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Minted","anonymous":false,"inputs":[{"name":"key","type":"string","indexed":false},{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleMinted(event: any): void {
  let mint = new Entity();
  mint.setBigInt("amount", event.params.amount);
  store.set("Mint", event.params.key, mint);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const minted = (block: number, logIndex: number, key: string, amount: bigint) => ({
  contract: "Token",
  event: "Minted",
  params: { key, amount },
  block: { number: block },
  logIndex,
});

describe("skipDuplicates on an immutable entity", () => {
  it("keeps the first block's write and merges saves within a block", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [minted(1, 0, "a", 1n)] } } });
    await indexer.process({
      chains: {
        1: {
          simulate: [
            minted(2, 0, "a", 2n),
            minted(3, 0, "b", 3n),
            minted(3, 1, "b", 4n),
            minted(4, 0, "b", 5n),
          ],
        },
      },
    });
    const rows = await indexer.Mint.getAll();
    t.expect(Object.fromEntries(rows.map((row: any) => [row.id, row.amount]))).toEqual({ a: 1n, b: 4n });
  });
});
`,
)
