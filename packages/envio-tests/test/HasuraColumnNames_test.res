open Vitest

// With `column_name_format: snake_case` the Postgres columns are renamed, but
// the GraphQL API keeps the names schema.graphql gave the fields: Hasura is
// told each renamed column's original name.

let config = InternalTestIndexer.fromUserApi(
  ~schema=`
type Snapshot {
  id: ID!
  transactionIndex: Int!
  tokenOwner: User!
}

type User {
  id: ID!
}
`,
  ~configYaml=`
name: hasura-column-names
storage:
  postgres:
    default: true
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
`,
).config

describe("Hasura tracking of snake_case columns", () => {
  it("exposes renamed columns under their schema field names, and nothing for the rest", t => {
    let columnConfigsOf = name =>
      Hasura.makeColumnConfigs((config.userEntitiesByName->Dict.getUnsafe(name)).table)->(
        Utils.magic: dict<Hasura.columnConfig> => JSON.t
      )
    t.expect((columnConfigsOf("Snapshot"), columnConfigsOf("User"))).toEqual((
      %raw(`{
        "transaction_index": { "customName": "transactionIndex" },
        "token_owner_id": { "customName": "tokenOwner_id" }
      }`),
      %raw(`{}`),
    ))
  })
})
