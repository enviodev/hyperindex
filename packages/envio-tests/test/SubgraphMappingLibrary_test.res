// A mapping library is AssemblyScript too — OpenZeppelin's subgraphs pull in
// @amxx/graphprotocol-utils, which declares `class string extends String` in a
// namespace; @protofire/subgraph-toolkit puts `@inline` on top-level
// functions; some files import the same graph-ts name twice. envio only ran its
// AssemblyScript pass on the project's own files, and Node refuses even to
// strip types under node_modules, so such a mapping never loaded.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: NounsToken
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: NounsToken
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Seed
      abis:
        - name: NounsToken
          file: ./abis/NounsToken.json
      eventHandlers:
        - event: NounCreated(indexed uint256,(uint48,uint48,uint48,uint48,uint48))
          handler: handleNounCreated
        - event: Batch((uint48,address)[])
          handler: handleBatch
      file: ./src/token.ts
`,
  ~schema=`
type Seed @entity {
  id: ID!
  values: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/NounsToken.json",
      `[{"type":"event","name":"NounCreated","anonymous":false,"inputs":[{"name":"tokenId","type":"uint256","indexed":true},{"name":"seed","type":"tuple","indexed":false,"internalType":"struct INounsSeeder.Seed","components":[{"name":"background","type":"uint48"},{"name":"body","type":"uint48"},{"name":"accessory","type":"uint48"},{"name":"head","type":"uint48"},{"name":"glasses","type":"uint48"}]}]},{"type":"event","name":"Batch","anonymous":false,"inputs":[{"name":"items","type":"tuple[]","indexed":false,"components":[{"name":"id","type":"uint48"},{"name":"owner","type":"address"}]}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "node_modules/@amxx/graphprotocol-utils/package.json",
      `{"name":"@amxx/graphprotocol-utils","version":"1.1.0","main":"index.ts"}`,
    ),
    (
      "node_modules/@amxx/graphprotocol-utils/index.ts",
      `
import { BigInt } from "@graphprotocol/graph-ts";
import { log } from "@graphprotocol/graph-ts";
import { log } from "@graphprotocol/graph-ts";

export namespace persistent {
  export class string extends String {}
}

// @ts-ignore
@inline
export function describe(value: BigInt): string {
  log.debug("describing {}", [value.toString()]);
  return "seed:" + value.toString();
}
`,
    ),
    (
      "src/token.ts",
      `
import { BigInt, Entity, ethereum, store } from "@graphprotocol/graph-ts";
import { describe } from "@amxx/graphprotocol-utils";

export function handleNounCreated(event: ethereum.Event): void {
  let tokenId: BigInt = event.parameters[0].value.toBigInt();
  let entity = new Entity();
  entity.setString("values", describe(tokenId));
  store.set("Seed", tokenId.toString(), entity);
}

export function handleBatch(event: ethereum.Event): void {}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const owner = "0x2222222222222222222222222222222222222222";

describe("a mapping library in node_modules", () => {
  it("loads through the AssemblyScript pass", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "NounsToken",
              event: "NounCreated",
              params: { tokenId: 7n, seed: { background: 1n, body: 14n, accessory: 3n, head: 200n, glasses: 9n } },
              block: { number: 10 },
            },
            {
              contract: "NounsToken",
              event: "Batch",
              params: { items: [{ id: 5n, owner }, { id: 6n, owner }] },
              block: { number: 11 },
            },
          ].slice(0, 1),
        },
      },
    });

    t.expect(await indexer.Seed.getAll()).toEqual([{ id: "7", values: "seed:7" }]);
  });
});
`,
)
