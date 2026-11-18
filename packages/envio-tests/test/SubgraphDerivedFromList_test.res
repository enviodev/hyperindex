// A field derived from a list field (`Account.tokens @derivedFrom(field:
// "owners")` over `Token.owners: [Account!]!`) holds every entity whose list
// contains the id on graph-node. envio's lookups only match a column equal to a
// value, so loading it silently read an empty list; it is refused instead.
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
        - Account
        - Token
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(string,address)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Account @entity {
  id: ID!
  tokens: [Token!]! @derivedFrom(field: "owners")
}

type Token @entity {
  id: ID!
  owners: [Account!]!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"name","type":"string","indexed":false},{"name":"owner","type":"address","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { BigInt, Bytes, Entity, store, Value } from "@graphprotocol/graph-ts";

// The shape \`graph codegen\` emits for every entity a derived field points at.
class Loader extends Entity {
  _entity: string;
  _id: string;
  _field: string;

  constructor(entity: string, id: string, field: string) {
    super();
    this._entity = entity;
    this._id = id;
    this._field = field;
  }

  load(): Entity[] {
    return store.loadRelated(this._entity, this._id, this._field);
  }
}

export function handleNewOwner(event: any): void {
  let account = new Entity();
  store.set("Account", "a1", account);
  let token = new Entity();
  token.set("owners", Value.fromStringArray(["a1"]));
  store.set("Token", "t1", token);
  new Loader("Account", "a1", "tokens").load();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("a field derived from a list field", () => {
  it("is refused when loaded rather than read as empty", async (t) => {
    await t
      .expect(
        createTestIndexer().process({
          chains: {
            1: {
              simulate: [
                { contract: "Registry", event: "NewOwner", params: { name: "d", owner: Addresses.mockAddresses[1] } },
              ],
            },
          },
        }),
      )
      .rejects.toThrow(/doesn't support loading Account.tokens, derived from the list field Token.owners/);
  });
});
`,
)
