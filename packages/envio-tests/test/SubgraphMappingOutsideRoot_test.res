// StakeWise keeps its manifest, schema and mappings in `src/` and lets graph
// codegen write `generated/` beside package.json, one level up. Node refuses
// the AssemblyScript in it ("Identifier 'value' has already been declared")
// unless the load hook treats every TypeScript file outside node_modules as the
// project's, not only the files under the manifest's directory.
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
  back: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Core.json",
      `[{"type":"event","name":"PoolInitialized","anonymous":false,"inputs":[{"name":"poolId","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~projectDir="src",
  ~mappings=Dict.fromArray([
    (
      "generated/helper.ts",
      `
export function twice(value: i32): i32 {
  let value = value * 2;
  return value;
}
`,
    ),
    (
      "src/src/core.ts",
      `
import { BigInt, Entity, store } from "@graphprotocol/graph-ts";
import { twice } from "../../generated/helper";

export function handlePoolInitialized(event: any): void {
  let entity = new Entity();
  entity.setBigInt("back", BigInt.fromI32(twice(23)));
  store.set("Init", "one", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a mapping importing AssemblyScript from outside the manifest's directory", () => {
  it("loads it", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Core",
              event: "PoolInitialized",
              params: { poolId: 1n },
              block: { number: 258, timestamp: 1760400000 },
              logIndex: 3,
            },
          ],
        },
      },
    });
    t.expect(await indexer.Init.getAll()).toEqual([{ id: "one", back: 46n }]);
  });
});
`,
)
