open Vitest

let yaml = `
name: mock-handlers
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`

let schema = `
type Account {
  id: ID!
  balance: BigInt!
}
`

describe("InternalTestIndexer handler type-checking", () => {
  it("accepts handlers that match the generated indexer types", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~schema,
      ~handlers=`
import { indexer } from "envio";
import type { Address } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  expectType<TypeEqual<typeof event.params.value, bigint>>(true);
  expectType<TypeEqual<typeof event.params.from, Address>>(true);
  context.Account.set({ id: event.params.to, balance: event.params.value });
});
`,
      ~configYaml=yaml,
    )
    t.expect(config.name).toBe("mock-handlers")
  })

  // https://github.com/enviodev/hyperindex/issues/1478
  // Lowercase schema entity names keep their original casing for the GraphQL
  // schema and the physical Postgres/ClickHouse tables, while the handler
  // context accessor is capitalized to match the generated types.
  it("capitalizes the context accessor but keeps physical names lowercase", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~schema=`
type pool_snapshots {
  id: ID!
  value: BigInt!
  owner: user_account!
}

type user_account {
  id: ID!
  snapshots: [pool_snapshots!]! @derivedFrom(field: "owner")
}
`,
      ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.User_account.set({ id: event.params.to });
  context.Pool_snapshots.set({
    id: event.params.to,
    value: event.params.value,
    owner_id: event.params.to,
  });
});
`,
      ~configYaml=yaml,
    )
    let poolSnapshots = config.userEntitiesByName->Dict.getUnsafe("Pool_snapshots")
    let userAccount = config.userEntitiesByName->Dict.getUnsafe("User_account")
    t.expect({
      "accessorKeys": config.userEntitiesByName->Dict.keysToArray->Array.toSorted(String.compare),
      "physicalNames": [poolSnapshots.name, userAccount.name]->Array.toSorted(String.compare),
      "tableNames": [poolSnapshots.table.tableName, userAccount.table.tableName]->Array.toSorted(
        String.compare,
      ),
      "linkedEntities": poolSnapshots.table
      ->Table.getLinkedEntityFields
      ->Array.map(((_, linkedEntityName)) => linkedEntityName),
      "derivedFromEntities": userAccount.table
      ->Table.getDerivedFromFields
      ->Array.map(df => df.derivedFromEntity),
    }).toEqual({
      "accessorKeys": ["Pool_snapshots", "User_account"],
      "physicalNames": ["pool_snapshots", "user_account"],
      "tableNames": ["pool_snapshots", "user_account"],
      "linkedEntities": ["user_account"],
      "derivedFromEntities": ["pool_snapshots"],
    })
  })

  it("throws the exact diagnostic on a nonexistent event", t => {
    t.expect(
      () =>
        InternalTestIndexer.fromUserApi(
          ~schema,
          ~handlers=`
import { indexer } from "envio";
indexer.onEvent({ contract: "Token", event: "Nonexistent" }, async () => {});
`,
          ~configYaml=yaml,
        )->ignore,
    ).toThrowError(`Type '"Nonexistent"' is not assignable to type '"Transfer"'`)
  })
})
