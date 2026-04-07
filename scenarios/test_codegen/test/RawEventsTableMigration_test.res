open Vitest

describe("Raw Events Table Migrations", () => {
  Async.it("Raw events table should migrate successfully", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let _indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sourceConfig: Config.CustomSources([sourceMock.source]),
        },
      ],
      ~enableRawEvents=true,
    )

    let sql = PgStorage.makeClient()
    let rawEventsColumnsRes: array<{"column_name": string, "data_type": string}> =
      await sql->Postgres.unsafe(
        `SELECT COLUMN_NAME AS column_name, DATA_TYPE AS data_type
         FROM INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_NAME = 'raw_events'
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
  })

  //Since the rework of rollbacks in v2.8, rollbacks are not supported for raw events
  //Duplicates are allowed to stop inserts breaking on rollbacks. If these need to be handled
  //in the future, raw events can be converted into an entity (with managed history) like dynamic
  //contracts.
  Async.it("Inserting 2 rows with the same pk should pass", async _t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let _indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sourceConfig: Config.CustomSources([sourceMock.source]),
        },
      ],
      ~enableRawEvents=true,
    )

    let sql = PgStorage.makeClient()
    let insert = () =>
      sql->PgStorage.setOrThrow(
        ~items=[MockIndexer.mockRawEventRow],
        ~table=InternalTable.RawEvents.table,
        ~itemSchema=InternalTable.RawEvents.schema,
        ~pgSchema=Env.Db.publicSchema,
      )

    await insert()
    await insert()
  })
})
