open Vitest

let config = InternalTestIndexer.fromUserApi(
  ~schema=`
type Snapshot {
  id: ID!
  transactionIndex: Int! @index
  tokenOwner: User!
}

type User {
  id: ID!
}
`,
  ~configYaml=`
name: column-names
storage:
  postgres:
    default: true
    column_name_format: snake_case
  clickhouse:
    default: true
    column_name_format: original
chains:
  - id: 1
    start_block: 0
`,
).config

let reverseFormatConfig = InternalTestIndexer.fromUserApi(
  ~schema=`
type Token {
  id: ID!
  tokenId: Int!
}
`,
  ~configYaml=`
name: reverse-column-names
storage:
  postgres:
    default: true
    column_name_format: original
  clickhouse:
    default: true
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
`,
).config
let snapshotEntity = config.userEntitiesByName->Dict.getUnsafe("Snapshot")

// The entity record keeps the API field names from schema.graphql
type snapshot = {
  id: string,
  transactionIndex: int,
  tokenOwner_id: string,
}
let snapshot1 = {id: "1", transactionIndex: 5, tokenOwner_id: "user-1"}

describe("Storage column naming (snake_case)", () => {
  it("keeps API field names in the entity schema", t => {
    let json =
      snapshot1
      ->(Utils.magic: snapshot => Internal.entity)
      ->S.reverseConvertToJsonOrThrow(snapshotEntity.schema)
    t.expect(json).toEqual(%raw(`{ "id": "1", "transactionIndex": 5, "tokenOwner_id": "user-1" }`))
  })

  // The names the addon creates and writes the table with.

  it("keeps API field names in ClickHouse when only Postgres renames columns", t => {
    // The spec is what crosses to Rust, so the column names it carries are the
    // ones the history table is created with and written to.
    let spec = ClickHouse.entitySpec(~entityConfig=snapshotEntity)
    t.expect(spec.columns->Array.map(({name}) => name)).toEqual([
      "id",
      "transactionIndex",
      "tokenOwner_id",
    ])
  })

  it("renames ClickHouse columns independently from Postgres", t => {
    let tokenEntity = reverseFormatConfig.userEntitiesByName->Dict.getUnsafe("Token")
    t.expect({
      "postgres": tokenEntity.table
      ->Table.getFields
      ->Array.map(field => (field->PgStorage.pgColumnInput).name),
      "clickhouse": ClickHouse.entitySpec(~entityConfig=tokenEntity).columns->Array.map(
        ({name}) => name,
      ),
    }).toEqual({
      "postgres": ["id", "tokenId"],
      "clickhouse": ["id", "token_id"],
    })
  })

  it("exposes renamed columns in Hasura under the original field name", t => {
    let columnConfigs = Hasura.makeColumnConfigs(snapshotEntity.table)
    t.expect(columnConfigs->(Utils.magic: dict<Hasura.columnConfig> => JSON.t)).toEqual(
      %raw(`{
        "transaction_index": { "customName": "transactionIndex" },
        "token_owner_id": { "customName": "tokenOwner_id" }
      }`),
    )
  })
})
