open RescriptMocha

describe("Test ClickHouse SQL generation functions", () => {
  describe("makeCreateHistoryTableQuery", () => {
    Async.it(
      "Should create SQL for A entity history table",
      async () => {
        let entityConfig = module(Entities.A)->Entities.entityModToInternal
        let query = ClickHouse.makeCreateHistoryTableQuery(~entityConfig, ~database="test_db")

        let expectedQuery = `CREATE TABLE IF NOT EXISTS test_db.\`envio_history_A\` (
  \`b_id\` String,
  \`id\` String,
  \`optionalStringToTestLinkedEntities\` Nullable(String),
  \`envio_checkpoint_id\` UInt32,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (id, envio_checkpoint_id)`

        Assert.equal(
          query,
          expectedQuery,
          ~message="A entity history table SQL should match exactly",
        )
      },
    )
  })
})
