// A derived field is a query, not a column: `graph codegen` turns it into a
// loader that calls `store.loadRelated(<owner>, <owner id>, <field>)`, and the
// loader answers with an array whether the field is written as a list or as the
// one-to-one `Registration @derivedFrom(...)` the ENS subgraph uses.
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
        - Domain
        - Registration
        - Transfer
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(string,address)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Domain @entity {
  id: ID!
  owner: Bytes!
  registration: Registration @derivedFrom(field: "domain")
  transfers: [Transfer!]! @derivedFrom(field: "domain")
}

type Registration @entity {
  id: ID!
  domain: Domain!
  cost: BigInt!
}

type Transfer @entity {
  id: ID!
  domain: Domain!
  index: Int!
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
  let domain = new Entity();
  domain.setBytes("owner", event.params.owner);
  store.set("Domain", "d1", domain);

  let registration = new Entity();
  registration.setString("domain", "d1");
  registration.setBigInt("cost", BigInt.fromI32(7));
  store.set("Registration", "r1", registration);

  for (let i = 0; i < 2; i++) {
    let transfer = new Entity();
    transfer.setString("domain", "d1");
    transfer.setI32("index", i);
    store.set("Transfer", "t" + i.toString(), transfer);
  }

  // The one-to-one derived field loads as an array too, so a mapping reads it
  // as \`.load()[0]\`.
  let registrations = new Loader("Domain", "d1", "registration").load();
  let transfers = new Loader("Domain", "d1", "transfers").load();

  let probe = new Entity();
  probe.setBytes("owner", event.params.owner);
  probe.setString(
    "id",
    registrations.length.toString() +
      "|" +
      registrations[0].getBigInt("cost").toString() +
      "|" +
      transfers.length.toString(),
  );
  store.set("Domain", probe.getString("id"), probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("a derived field", () => {
  it("loads through the owner, list or one-to-one", async (t) => {
    const indexer = createTestIndexer();
    const owner = Addresses.mockAddresses[1];

    await indexer.process({
      chains: {
        1: {
          simulate: [{ contract: "Registry", event: "NewOwner", params: { name: "d", owner } }],
        },
      },
    });

    t.expect((await indexer.Domain.getAll()).map((domain) => domain.id).sort()).toEqual([
      "1|7|2",
      "d1",
    ]);
  });
});
`,
)
