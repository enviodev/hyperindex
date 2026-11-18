// graph-node stores a list field whose elements may be null (`[String]`,
// QuickSwap's Token.whitelist) as a Postgres array, nulls and all. envio's
// store holds list elements that aren't null, and translation refused every
// such field. Such a list is now stored as the list of its values, and a save
// that puts a null into it is refused, naming the field, where graph-node
// would store the null.
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
        - Token
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Step(uint256)
          handler: handleStep
      file: ./src/factory.ts
`,
  ~schema=`
type Token @entity {
  id: ID!
  whitelist: [String]
  amounts: [BigInt]!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Factory.json",
      `[{"type":"event","name":"Step","anonymous":false,"inputs":[{"name":"kind","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/factory.ts",
      `
import { BigInt, Entity, Value, store } from "@graphprotocol/graph-ts";

export function handleStep(event: any): void {
  const kind = event.params.kind.toI32();
  const token = new Entity();
  token.set("amounts", Value.fromBigIntArray([BigInt.fromI32(kind)]));
  if (kind == 1) {
    token.set("whitelist", Value.fromStringArray(["0xpair1", "0xpair2"]));
  } else {
    token.set("whitelist", Value.fromArray([Value.fromString("0xpair3"), Value.fromNull()]));
  }
  store.set("Token", kind == 1 ? "t1" : "t2", token);
}
`,
    ),
  ]),
  ~test=`
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";

const step = (kind: bigint) => ({ contract: "Factory" as const, event: "Step" as const, params: { kind } });

describe("a list field whose elements may be null", () => {
  it("stores its values, and refuses a null element", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1: { simulate: [step(1n)] } } });
    t.expect(await indexer.Token.getOrThrow("t1")).toEqual({
      id: "t1",
      whitelist: ["0xpair1", "0xpair2"],
      amounts: [1n],
    });

    await expect(indexer.process({ chains: { 1: { simulate: [step(2n)] } } })).rejects.toThrow(
      "Envio Subgraph doesn't support a null element in a list field yet: graph-node stores Token.whitelist ([String]) with the null in it, and envio's store holds list elements that aren't null.\\n  Found in Token[t2].whitelist.",
    );
  });
});
`,
)
