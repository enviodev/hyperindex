import { afterEach, describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";
import * as Core from "envio/src/Core.res.mjs";
import * as Config from "envio/src/Config.res.mjs";
import { createIndexerClient, testIndexerClient, type EntityMetaInput } from "envio/sidecar";
import { fakeGraphql, tableResponder, type HasuraType } from "./fakeHasura.js";

// The entity configs `envio sidecar` hands the read client come from a real
// config.yaml and schema.graphql, parsed the way the indexer parses them.
const configYaml = `
name: sidecar-relations
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Registry
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Registered(address indexed owner, uint256 id)
`;
const schema = `
type AccountStat {
  id: ID!
  volume: BigInt!
  positions: [Position!]! @derivedFrom(field: "accountStat")
}
type Position {
  id: ID!
  size: BigInt!
  accountStat: AccountStat!
  previous: Position
}
`;

type Parsed = { readonly config: string };
const parsed = (Core as unknown as { fromUserApi: (...args: unknown[]) => Parsed }).fromUserApi(
  schema,
  undefined,
  undefined,
  false,
  configYaml,
);
const publicConfig: unknown = JSON.parse(parsed.config);
const ConfigApi = Config as unknown as {
  fromPublic: (json: unknown) => unknown;
  getPgUserEntities: (config: unknown) => EntityMetaInput[];
  prime: (json: unknown) => void;
};
const entities = ConfigApi.getPgUserEntities(ConfigApi.fromPublic(publicConfig));

// What Hasura tracks for that schema: references as `<field>_id` columns plus an
// object relationship under the field name; `@derivedFrom` as an array relationship.
const types: Readonly<Record<string, HasuraType>> = {
  AccountStat: { columns: ["id", "volume"], arrayRelations: ["positions"] },
  Position: { columns: ["id", "size", "accountStat_id", "previous_id"], objectRelations: ["accountStat", "previous"] },
};
const tables = {
  AccountStat: [{ id: "a", volume: "500" }],
  Position: [
    { id: "p1", size: "1", accountStat_id: "a", previous_id: null },
    { id: "p2", size: "2", accountStat_id: "a", previous_id: "p1" },
  ],
};

type AccountStat = { readonly id: string; readonly volume: bigint };
type Position = { readonly id: string; readonly size: bigint; readonly accountStat_id: string; readonly previous_id: string | undefined };
type Entities = { AccountStat: AccountStat; Position: Position };

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

const readAll = async (client: ReturnType<typeof createIndexerClient<Entities>>) => {
  const iterated: Position[] = [];
  for await (const position of client.Position.iterate()) iterated.push(position);
  return {
    position: await client.Position.get("p2"),
    stat: await client.AccountStat.getOrThrow("a"),
    byStat: await client.Position.getWhere({ accountStat_id: { _eq: "a" } }, { orderBy: { id: "asc" } }),
    all: await client.Position.getAll({ orderBy: { size: "desc" } }),
    iterated,
  };
};

describe("read client on entities with relation and @derivedFrom fields", () => {
  // Reported from the GMX dogfood (T-030): Hasura answered "missing selection set"
  // to every typed read of an entity with a relation field.
  it("selects relations as <field>_id, skips derived fields and returns what the test indexer returns", async () => {
    const graphql = await fakeGraphql(tableResponder(tables), { types });
    cleanups.push(graphql.close);
    const overGraphql = await readAll(createIndexerClient<Entities>({ url: graphql.url, entities }));

    ConfigApi.prime(publicConfig);
    const ti = createTestIndexer() as unknown as Record<string, { set: (entity: unknown) => void }>;
    ti.AccountStat?.set({ id: "a", volume: 500n });
    ti.Position?.set({ id: "p1", size: 1n, accountStat_id: "a", previous_id: undefined });
    ti.Position?.set({ id: "p2", size: 2n, accountStat_id: "a", previous_id: "p1" });
    const overTestIndexer = await readAll(testIndexerClient<Entities>(ti));

    const p1 = { id: "p1", size: 1n, accountStat_id: "a", previous_id: undefined };
    const p2 = { id: "p2", size: 2n, accountStat_id: "a", previous_id: "p1" };
    expect({
      overGraphql,
      sameAsTestIndexer: overTestIndexer,
      selections: [...new Set(graphql.requests.map((request) => /\{ (\w+)\(.*\) \{ ([^}]*) \} \}$/.exec(request.query)?.slice(1).join(": ")))],
    }).toEqual({
      overGraphql: { position: p2, stat: { id: "a", volume: 500n }, byStat: [p1, p2], all: [p2, p1], iterated: [p1, p2] },
      sameAsTestIndexer: { position: p2, stat: { id: "a", volume: 500n }, byStat: [p1, p2], all: [p2, p1], iterated: [p1, p2] },
      selections: ["Position: id size accountStat_id previous_id", "AccountStat: id volume"],
    });
  });

  it("introspection (no entity configs) selects the same columns and returns raw values", async () => {
    const graphql = await fakeGraphql(tableResponder(tables), { types });
    cleanups.push(graphql.close);
    const client = createIndexerClient<Entities>({ url: graphql.url });
    expect(await readAll(client)).toEqual({
      position: { id: "p2", size: "2", accountStat_id: "a", previous_id: "p1" },
      stat: { id: "a", volume: "500" },
      byStat: [
        { id: "p1", size: "1", accountStat_id: "a", previous_id: null },
        { id: "p2", size: "2", accountStat_id: "a", previous_id: "p1" },
      ],
      all: [
        { id: "p2", size: "2", accountStat_id: "a", previous_id: "p1" },
        { id: "p1", size: "1", accountStat_id: "a", previous_id: null },
      ],
      iterated: [
        { id: "p1", size: "1", accountStat_id: "a", previous_id: null },
        { id: "p2", size: "2", accountStat_id: "a", previous_id: "p1" },
      ],
    });
  });
});
