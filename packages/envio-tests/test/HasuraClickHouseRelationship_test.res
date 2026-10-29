open Vitest

// Hasura serves what Postgres keeps, so an entity kept in ClickHouse alone has
// no table a relationship could point at, and asking Hasura for one fails.

let config = Scenario.make(
  ~configYaml=`
name: hasura-clickhouse-relationships
storage:
  clickhouse: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Holder {
  id: ID!
  token: Token!
  note: Note!
}

type Note {
  id: ID!
}

type Token @storage(clickhouse: true) {
  id: ID!
}
`,
).config

describe("Hasura relationships", () => {
  it("leave out an entity kept in ClickHouse alone", t => {
    t.expect(
      Hasura.makeRelationships(
        ~userEntities=config->Config.getPgUserEntities,
        ~schema=Schema.make(config.userEntities->Array.map(entity => entity.table)),
      )->Array.map(
        relationship => (
          relationship.tableName,
          relationship.objectName,
          relationship.mappedEntity,
        ),
      ),
    ).toEqual([("Holder", "note", "Note")])
  })
})
