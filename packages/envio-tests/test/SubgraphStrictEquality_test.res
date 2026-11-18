// AssemblyScript can't overload `===`: it compares two references by identity
// and two numbers by value (asc 0.19.10 `compileBinaryExpression`, "can't
// overload '==='"). A string the host returns is a new allocation, so Kiln's
// `dataSource.network() === 'mainnet'` never holds on graph-node; a literal is
// one static segment however often it is written (`ensureStaticStringPtr`
// deduplicates), so Marlin's `action === "add"` holds when the caller passed
// the literal.
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
        - Check
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(address,uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Check @entity {
  id: ID!
  hostIsLiteral: Boolean!
  hostIsNotLiteral: Boolean!
  hostLocalIsLiteral: Boolean!
  hexIsLiteral: Boolean!
  passedLiteral: Boolean!
  passedOtherLiteral: Boolean!
  constantIsLiteral: Boolean!
  hostLocalIsItself: Boolean!
  i64IsNumber: Boolean!
  unsetFieldIsNull: Boolean!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"owner","type":"address","indexed":false},{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Entity, dataSource, store } from "@graphprotocol/graph-ts";

const MAINNET = "mainnet";

class Holder {
  value: string | null;
}

function isAdd(action: string): bool {
  return action === "add";
}

export function handleNewOwner(event: any): void {
  let network = dataSource.network();
  let check = new Entity();
  check.setBoolean("hostIsLiteral", dataSource.network() === "mainnet");
  check.setBoolean("hostIsNotLiteral", dataSource.network() !== "mainnet");
  check.setBoolean("hostLocalIsLiteral", network === MAINNET);
  check.setBoolean("hexIsLiteral", event.params.owner.toHexString() === "0x2222222222222222222222222222222222222222");
  check.setBoolean("passedLiteral", isAdd("add"));
  check.setBoolean("passedOtherLiteral", isAdd("withdraw"));
  check.setBoolean("constantIsLiteral", MAINNET === "mainnet");
  check.setBoolean("hostLocalIsItself", network === network);
  check.setBoolean("i64IsNumber", event.params.nonce.toI64() === 7);
  check.setBoolean("unsetFieldIsNull", new Holder().value === null);
  store.set("Check", "c1", check);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("strict equality", () => {
  it("compares references by identity and numbers by value, as AssemblyScript does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Registry",
              event: "NewOwner",
              params: { owner: "0x2222222222222222222222222222222222222222", nonce: 7n },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Check.getOrThrow("c1")).toEqual({
      id: "c1",
      hostIsLiteral: false,
      hostIsNotLiteral: true,
      hostLocalIsLiteral: false,
      hexIsLiteral: false,
      passedLiteral: true,
      passedOtherLiteral: false,
      constantIsLiteral: true,
      hostLocalIsItself: true,
      i64IsNumber: true,
      unsetFieldIsNull: true,
    });
  });
});
`,
)
