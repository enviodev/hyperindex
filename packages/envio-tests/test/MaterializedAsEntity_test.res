open Vitest

// A table is stored and queryable whether or not it opts in; `as_entity` only
// decides whether handlers see it, and under what name. Test-indexer accessors
// are always there — output has to be assertable — so this fixture reads both
// tables from the test but only one from the handler.
let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: as-entity
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  # Hidden from handlers: the default.
  hidden_totals:
    from: evm.events
    select:
      id: params.to
      total:
        _sum: params.value
  # The name handlers use. The table keeps its own name in the database and
  # in GraphQL.
  renamed_totals:
    as_entity: Receipt
    from: evm.events
    select:
      id: params.to
      total:
        _sum: params.value
`,
  ~handlers=`
import { indexer } from "envio";

declare global {
  var seen: string[];
}
globalThis.seen = [];

indexer.onEvent({ contract: "ERC20", event: "Transfer" }, async ({ event, context }) => {
  if (context.isPreload) return;
  // Readable under the name \`as_entity\` gave it.
  const renamed = await context.Receipt.get(event.params.to);
  // The hidden one isn't on the context at all — reaching it needs a cast, and
  // the runtime rejects the access rather than handing back a silent undefined.
  let hiddenError = "reachable";
  try {
    const reach = context as never as Record<string, { get: (id: string) => unknown }>;
    reach["Hidden_totals"]!.get(event.params.to);
  } catch (error) {
    hiddenError = (error as Error).message;
  }
  globalThis.seen.push(\`\${renamed?.total ?? "none"}/\${hiddenError}\`);
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers, type Receipt } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[0];

declare global {
  var seen: string[];
}

describe("as_entity", () => {
  it("materializes every table but only exposes the ones that opted in", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              params: { from: Addresses.defaultAddress, to: alice, value: 8n },
            },
          ],
        },
      },
    });

    // The renamed table's TS type is exported under the \`as_entity\` name.
    const expectedRenamed: (Receipt & { chainId: number })[] = [
      { id: alice, total: 8n, chainId: 1 },
    ];

    t.expect({
      hidden: await indexer.Hidden_totals.getAll(),
      renamed: await indexer.Receipt.getAll(),
      seen: globalThis.seen,
    }).toEqual({
      hidden: [{ id: alice, total: 8n, chainId: 1 }],
      renamed: expectedRenamed,
      seen: [
        "8/context.Hidden_totals is unavailable: config.yaml writes the table " +
          "\`hidden_totals\` but doesn't expose it to handlers. Add " +
          "\`as_entity: Hidden_totals\` to it in config.yaml to read it here.",
      ],
    });
  });
});
`,
)

// A table nobody named is still a GraphQL citizen — it's just queried as a set.
// `<table>_by_pk` only makes sense for a table whose ids a caller can name, so
// Hasura gets an explicit root-field list for the ones that stayed hidden.
describe("as_entity and the GraphQL roots", () => {
  let permissionOf = tableName => {
    let entityConfig =
      config.userEntities
      ->Array.find((e: Internal.entityConfig) => e.table.tableName === tableName)
      ->Option.getOrThrow
    Hasura.makeSelectPermission(
      ~responseLimit=None,
      ~allowAggregations=true,
      ~hideByPk=entityConfig.hiddenFromHandlers,
    )->(Utils.magic: dict<JSON.t> => JSON.t)
  }

  it("Drops by_pk for a table without as_entity, and keeps every root for one with it", t => {
    t.expect(
      {
        "hidden": permissionOf("hidden_totals"),
        "renamed": permissionOf("renamed_totals"),
      }->(Utils.magic: 'actual => JSON.t),
    ).toEqual(
      {
        "hidden": {
          "columns": "*",
          "filter": Object.make(),
          "limit": None,
          "allow_aggregations": true,
          "query_root_fields": Some(["select", "select_aggregate"]),
          "subscription_root_fields": Some(["select", "select_aggregate"]),
        },
        "renamed": {
          "columns": "*",
          "filter": Object.make(),
          "limit": None,
          "allow_aggregations": true,
          "query_root_fields": None,
          "subscription_root_fields": None,
        },
      }->(Utils.magic: 'expected => JSON.t),
    )
  })

  it("Only lists select when aggregations are off", t => {
    t.expect(
      Hasura.makeSelectPermission(
        ~responseLimit=Some(100),
        ~allowAggregations=false,
        ~hideByPk=true,
      )->(Utils.magic: dict<JSON.t> => JSON.t),
    ).toEqual(
      {
        "columns": "*",
        "filter": Object.make(),
        "limit": 100,
        "allow_aggregations": false,
        "query_root_fields": ["select"],
        "subscription_root_fields": ["select"],
      }->(Utils.magic: 'off => JSON.t),
    )
  })
})
