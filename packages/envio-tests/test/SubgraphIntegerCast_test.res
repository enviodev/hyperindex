// `x as i32` converts. revert-univ3 casts a call result (a class) to i32 and
// hands it to BigInt.fromI32: JavaScript made that NaN and the mapping died;
// AssemblyScript reads the reference's address, a number.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Cast
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Cast @entity {
  id: ID!
  wrapped: BigInt!
  unsigned: BigInt!
  narrow: BigInt!
  reference: BigInt!
  nothing: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { BigInt, Entity, store } from "@graphprotocol/graph-ts";

export function handleNewOwner(event: any): void {
  let big: i64 = 4294967297;
  let negative: i64 = -1;
  let wide: i64 = 300;
  let reference = event.params.nonce;
  let missing = null;
  let cast = new Entity();
  cast.setBigInt("wrapped", BigInt.fromI32(big as i32));
  cast.setBigInt("unsigned", BigInt.fromU32(negative as u32));
  cast.setBigInt("narrow", BigInt.fromI32(wide as u8));
  cast.setBigInt("reference", BigInt.fromI32(reference as i32));
  cast.setBigInt("nothing", BigInt.fromI32(missing as i32));
  store.set("Cast", "c1", cast);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("an integer cast", () => {
  it("wraps an integer, and reads a reference or null as a number", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { nonce: 1n } }] },
      },
    });

    t.expect(await indexer.Cast.getOrThrow("c1")).toEqual({
      id: "c1",
      wrapped: 1n,
      unsigned: 4294967295n,
      narrow: 44n,
      reference: 0n,
      nothing: 0n,
    });
  });
});
`,
)
