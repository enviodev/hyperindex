import { afterEach, describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";
import * as Core from "envio/src/Core.res.mjs";
import * as Config from "envio/src/Config.res.mjs";
import { BigDecimal } from "envio";
import { createIndexerClient, testIndexerClient, type EntityMetaInput } from "envio/sidecar";
import { fakeGraphql, tableResponder, type HasuraType } from "./fakeHasura.js";

const configYaml = `
name: sidecar-numbers
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
type Priced {
  id: ID!
  usd: Float!
  maybeUsd: Float
  block: Int!
  wad: BigInt!
  rate: BigDecimal!
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

const types: Readonly<Record<string, HasuraType>> = {
  Priced: { columns: ["id", "usd", "maybeUsd", "block", "wad", "rate"] },
};
// What `envio dev` and hosted Hasura answer: HASURA_GRAPHQL_STRINGIFY_NUMERIC_TYPES
// turns float8 (Float) into strings too, not only numeric (BigInt, BigDecimal).
const tables = {
  Priced: [
    { id: "a", usd: "50.4", maybeUsd: "1e-7", block: 7, wad: "1000000000000000000", rate: "0.5" },
    { id: "b", usd: "3", maybeUsd: null, block: 8, wad: "2", rate: "1.25" },
  ],
};

type Priced = {
  readonly id: string;
  readonly usd: number;
  readonly maybeUsd: number | undefined;
  readonly block: number;
  readonly wad: bigint;
  readonly rate: BigDecimal;
};
type Entities = { Priced: Priced };

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

const readAll = async (client: ReturnType<typeof createIndexerClient<Entities>>) => {
  const iterated: Priced[] = [];
  for await (const row of client.Priced.iterate()) iterated.push(row);
  return {
    one: await client.Priced.get("a"),
    where: await client.Priced.getWhere({ id: { _eq: "b" } }),
    iterated,
    narrowed: await client.Priced.getAll({ orderBy: { id: "asc" }, fields: ["usd", "maybeUsd"] }),
  };
};

const normalise = (value: unknown): unknown =>
  JSON.parse(JSON.stringify(value, (_key, v) => (typeof v === "bigint" ? `${v}n` : v)));
const isBigDecimal = (value: unknown) => value instanceof BigDecimal;

describe("read client on Float fields", () => {
  // Found running the T-010 demo against envio dev's Hasura: every typed read of
  // an entity with a Float field threw "Expected number | null, received \"41.61\"".
  it("decodes Float columns Hasura sends as strings, like the test indexer returns them", async () => {
    const graphql = await fakeGraphql(tableResponder(tables), { types });
    cleanups.push(graphql.close);
    const overGraphql = await readAll(createIndexerClient<Entities>({ url: graphql.url, entities }));

    ConfigApi.prime(publicConfig);
    const ti = createTestIndexer() as unknown as Record<string, { set: (entity: unknown) => void }>;
    ti.Priced?.set({ id: "a", usd: 50.4, maybeUsd: 1e-7, block: 7, wad: 10n ** 18n, rate: new BigDecimal("0.5") });
    ti.Priced?.set({ id: "b", usd: 3, maybeUsd: undefined, block: 8, wad: 2n, rate: new BigDecimal("1.25") });
    const overTestIndexer = await readAll(testIndexerClient<Entities>(ti));

    const a = { id: "a", usd: 50.4, maybeUsd: 1e-7, block: 7, wad: "1000000000000000000n", rate: "0.5" };
    const b = { id: "b", usd: 3, block: 8, wad: "2n", rate: "1.25" };
    const narrowed = [
      { id: "a", usd: 50.4, maybeUsd: 1e-7 },
      { id: "b", usd: 3 },
    ];
    expect({
      overGraphql: normalise(overGraphql),
      sameAsTestIndexer: normalise(overTestIndexer),
      rateIsBigDecimal: [isBigDecimal(overGraphql.one?.rate), isBigDecimal(overTestIndexer.one?.rate)],
    }).toEqual({
      overGraphql: { one: a, where: [b], iterated: [a, b], narrowed },
      sameAsTestIndexer: { one: a, where: [b], iterated: [a, b], narrowed },
      rateIsBigDecimal: [true, true],
    });
  });
});
