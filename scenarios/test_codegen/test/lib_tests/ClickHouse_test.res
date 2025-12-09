open RescriptMocha

describe("Test ClickHouse SQL generation functions", () => {
  describe("makeCreateCheckpointsTableQuery", () => {
    Async.it(
      "Should create SQL for checkpoints table",
      async () => {
        let query = ClickHouse.makeCreateCheckpointsTableQuery(~database="test_db")

        let expectedQuery = `CREATE TABLE IF NOT EXISTS test_db.\`envio_checkpoints\` (
  \`id\` Int32,
  \`chain_id\` Int32,
  \`block_number\` Int32,
  \`block_hash\` Nullable(String),
  \`events_processed\` Int32
)
ENGINE = MergeTree()
ORDER BY (id)`

        Assert.equal(query, expectedQuery, ~message="Checkpoints table SQL should match exactly")
      },
    )
  })

  describe("makeCreateHistoryTableQuery", () => {
    Async.it(
      "Should create SQL for A entity history table",
      async () => {
        let entityConfig = module(Entities.EntityWithAllTypes)->Entities.entityModToInternal
        let query = ClickHouse.makeCreateHistoryTableQuery(~entityConfig, ~database="test_db")

        let expectedQuery = `CREATE TABLE IF NOT EXISTS test_db.\`envio_history_EntityWithAllTypes\` (
  \`id\` String,
  \`string\` String,
  \`optString\` Nullable(String),
  \`arrayOfStrings\` Array(String),
  \`int_\` Int32,
  \`optInt\` Nullable(Int32),
  \`arrayOfInts\` Array(Int32),
  \`float_\` Float64,
  \`optFloat\` Nullable(Float64),
  \`arrayOfFloats\` Array(Float64),
  \`bool\` Bool,
  \`optBool\` Nullable(Bool),
  \`bigInt\` String,
  \`optBigInt\` Nullable(String),
  \`arrayOfBigInts\` Array(String),
  \`bigDecimal\` String,
  \`optBigDecimal\` Nullable(String),
  \`bigDecimalWithConfig\` Decimal(10,8),
  \`arrayOfBigDecimals\` Array(String),
  \`timestamp\` DateTime64(3, 'UTC'),
  \`optTimestamp\` Nullable(DateTime64(3, 'UTC')),
  \`json\` String,
  \`enumField\` Enum8('ADMIN', 'USER'),
  \`optEnumField\` Nullable(Enum8('ADMIN', 'USER')),
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

  describe("makeCreateViewQuery", () => {
    Async.it(
      "Should create SQL for A entity view",
      async () => {
        let entity = module(Entities.EntityWithAllTypes)->Entities.entityModToInternal
        let query = ClickHouse.makeCreateViewQuery(~entityConfig=entity, ~database="test_db")

        let expectedQuery = `CREATE VIEW IF NOT EXISTS test_db.\`EntityWithAllTypes\` AS
SELECT \`id\`, \`string\`, \`optString\`, \`arrayOfStrings\`, \`int_\`, \`optInt\`, \`arrayOfInts\`, \`float_\`, \`optFloat\`, \`arrayOfFloats\`, \`bool\`, \`optBool\`, \`bigInt\`, \`optBigInt\`, \`arrayOfBigInts\`, \`bigDecimal\`, \`optBigDecimal\`, \`bigDecimalWithConfig\`, \`arrayOfBigDecimals\`, \`timestamp\`, \`optTimestamp\`, \`json\`, \`enumField\`, \`optEnumField\`
FROM (
  SELECT \`id\`, \`string\`, \`optString\`, \`arrayOfStrings\`, \`int_\`, \`optInt\`, \`arrayOfInts\`, \`float_\`, \`optFloat\`, \`arrayOfFloats\`, \`bool\`, \`optBool\`, \`bigInt\`, \`optBigInt\`, \`arrayOfBigInts\`, \`bigDecimal\`, \`optBigDecimal\`, \`bigDecimalWithConfig\`, \`arrayOfBigDecimals\`, \`timestamp\`, \`optTimestamp\`, \`json\`, \`enumField\`, \`optEnumField\`, \`envio_change\`
  FROM test_db.\`envio_history_EntityWithAllTypes\`
  WHERE \`envio_checkpoint_id\` <= (SELECT max(id) FROM test_db.\`envio_checkpoints\`)
  ORDER BY \`envio_checkpoint_id\` DESC
  LIMIT 1 BY \`id\`
)
WHERE \`envio_change\` = 'SET'`

        Assert.equal(query, expectedQuery, ~message="A entity view SQL should match exactly")
      },
    )
  })
})
