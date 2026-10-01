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

let mockRawEventRow: InternalTable.RawEvents.t = {
  chain_id: 1->ChainId.fromInt,
  event_id: 1234567890n,
  contract_name: "NftFactory",
  event_name: "SimpleNftCreated",
  block_number: 1000,
  log_index: 10,
  transaction_fields: %raw(`{"transactionIndex": 20, "hash": "0x1234567890abcdef"}`),
  src_address: "0x0123456789abcdef0123456789abcdef0123456"->Utils.magic,
  block_hash: "0x9876543210fedcba9876543210fedcba987654321",
  block_timestamp: 1620720000,
  block_fields: %raw(`{}`),
  params: {
    "foo": "bar",
    "baz": 42,
  }->Utils.magic,
}

describe("Raw Events Table Migrations", () => {
  scenario->Scenario.it(
    "Raw events table should migrate successfully",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source as _) => {
      let {sql, pgSchema} = indexer.pg
      let rawEventsColumnsRes: array<{
        "column_name": string,
        "data_type": string,
      }> = await sql->Postgres.unsafe(
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

  //Since the rework of rollbacks in v2.8, rollbacks are not supported for raw events
  //Duplicates are allowed to stop inserts breaking on rollbacks. If these need to be handled
  //in the future, raw events can be converted into an entity (with managed history) like dynamic
  //contracts.
  scenario->Scenario.it(
    "Inserting 2 rows with the same pk should pass",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t as _, ~indexer, ~source as _) => {
      let {sql, pgSchema} = indexer.pg
      // Shared across both inserts, so the second one exercises the cached
      // query the way a storage instance would.
      let setQueryCache = PgStorage.makeSetQueryCache()
      let insert = () =>
        sql->PgStorage.setOrThrow(
          ~items=[mockRawEventRow],
          ~table=InternalTable.RawEvents.table,
          ~itemSchema=InternalTable.RawEvents.schema,
          ~pgSchema,
          ~setQueryCache,
        )

      await insert()
      await insert()
    },
  )
})
