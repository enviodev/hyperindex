// graph-node validates every save against the schema (EntityCache::set calls
// Entity::validate, merging with the stored entity when the update alone is
// incomplete) and fails the handler on "Entity T[id]: missing value for
// non-nullable field `f`". kalidao/kali-subgraph's tribute mapping saves a
// Proposal with only two fields, swaap-labs/swaap-subgraph-v1 never sets its
// Transaction's gasUsed, mememan-anon/launchpad-subgraph its PandaPool's
// tokens: envio wrote them and failed the batch in Postgres ("Cannot read
// properties of null", a NOT NULL violation) instead.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Dao
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Dao
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Proposal
      abis:
        - name: Dao
          file: ./abis/Dao.json
      eventHandlers:
        - event: Step(uint256)
          handler: handleStep
      file: ./src/dao.ts
`,
  ~schema=`
type Proposal @entity {
  id: ID!
  serial: BigInt!
  sponsor: Bytes
  status: Boolean!
  votes: [Vote!]! @derivedFrom(field: "proposal")
}

type Vote @entity {
  id: ID!
  proposal: Proposal!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Dao.json",
      `[{"type":"event","name":"Step","anonymous":false,"inputs":[{"name":"kind","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/dao.ts",
      `
import { BigInt, Entity, Value, store } from "@graphprotocol/graph-ts";

export function handleStep(event: any): void {
  const kind = event.params.kind.toI32();
  const proposal = new Entity();
  if (kind == 1) {
    // Complete, with a nullable field left unset.
    proposal.set("serial", Value.fromBigInt(BigInt.fromI32(1)));
    proposal.set("status", Value.fromBoolean(false));
  } else if (kind == 2) {
    // A partial update of the stored entity: valid once merged.
    proposal.set("status", Value.fromBoolean(true));
  } else {
    // A new entity missing \`serial\` and \`status\`.
    proposal.set("sponsor", Value.fromBytes(event.address));
  }
  store.set("Proposal", kind == 3 ? "p2" : "p1", proposal);
}
`,
    ),
  ]),
  ~test=`
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";

const step = (kind: bigint) => ({ contract: "Dao" as const, event: "Step" as const, params: { kind } });

describe("a save missing a non-nullable field", () => {
  it("fails the handler as graph-node does, merged with the stored entity first", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1: { simulate: [step(1n), step(2n)] } } });
    t.expect(await indexer.Proposal.getOrThrow("p1")).toEqual({
      id: "p1",
      serial: 1n,
      sponsor: null,
      status: true,
    });

    await expect(indexer.process({ chains: { 1: { simulate: [step(3n)] } } })).rejects.toThrow(
      "Entity Proposal[p2]: missing value for non-nullable field \`serial\`",
    );
  });
});
`,
)
