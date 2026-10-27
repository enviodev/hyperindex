open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: raw-events-migration
raw_events: true
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
)

describe("Raw Events Table Migrations", () => {
  scenario->Scenario.it(
    "Raw events table should migrate successfully",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source as _) => {
      let {sql, pgSchema} = indexer.pg
      let rawEventsColumnsRes: array<{
        "column_name": string,
        "data_type": string,
      }> = await sql->Sql.queryForTests(
        `SELECT COLUMN_NAME AS column_name, DATA_TYPE AS data_type
           FROM INFORMATION_SCHEMA.COLUMNS
           WHERE TABLE_SCHEMA = '${pgSchema}'
             AND TABLE_NAME = 'raw_events'
           ORDER BY ORDINAL_POSITION;`,
      )

      t.expect(rawEventsColumnsRes).toEqual([
        {"column_name": "chain_id", "data_type": "integer"},
        {"column_name": "event_id", "data_type": "bigint"},
        {"column_name": "event_name", "data_type": "text"},
        {"column_name": "contract_name", "data_type": "text"},
        {"column_name": "block_number", "data_type": "integer"},
        {"column_name": "log_index", "data_type": "integer"},
        {"column_name": "src_address", "data_type": "text"},
        {"column_name": "block_hash", "data_type": "text"},
        {"column_name": "block_timestamp", "data_type": "integer"},
        {"column_name": "block_fields", "data_type": "jsonb"},
        {"column_name": "transaction_fields", "data_type": "jsonb"},
        {"column_name": "params", "data_type": "jsonb"},
        {"column_name": "serial", "data_type": "bigint"},
      ])
    },
  )
})
