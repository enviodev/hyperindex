open RescriptMocha

describe("Test ClickHouse SQL generation functions", () => {
  describe("makeCreateHistoryTableQuery", () => {
    Async.it(
      "Should create SQL for A entity history table",
      async () => {
        let entityConfig = module(Entities.EntityWithAllTypes)->Entities.entityModToInternal
        let query = ClickHouse.makeCreateHistoryTableQuery(~entityConfig, ~database="test_db")

        let expectedQuery = `CREATE TABLE IF NOT EXISTS test_db.\`envio_history_EntityWithAllTypes\` (
  \`arrayOfBigDecimals\` Array(String),
  \`arrayOfBigInts\` Array(String),
  \`arrayOfFloats\` Array(Float64),
  \`arrayOfInts\` Array(Int32),
  \`arrayOfStrings\` Array(String),
  \`bigDecimal\` String,
  \`bigDecimalWithConfig\` Decimal(10,8),
  \`bigInt\` String,
  \`bool\` Bool,
  \`enumField\` Enum8('ADMIN', 'USER'),
  \`float_\` Float64,
  \`id\` String,
  \`int_\` Int32,
  \`json\` String,
  \`optBigDecimal\` Nullable(String),
  \`optBigInt\` Nullable(String),
  \`optBool\` Nullable(Bool),
  \`optEnumField\` Nullable(Enum8('ADMIN', 'USER')),
  \`optFloat\` Nullable(Float64),
  \`optInt\` Nullable(Int32),
  \`optString\` Nullable(String),
  \`optTimestamp\` Nullable(DateTime64(3, 'UTC')),
  \`string\` String,
  \`timestamp\` DateTime64(3, 'UTC'),
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
SELECT \`arrayOfBigDecimals\`, \`arrayOfBigInts\`, \`arrayOfFloats\`, \`arrayOfInts\`, \`arrayOfStrings\`, \`bigDecimal\`, \`bigDecimalWithConfig\`, \`bigInt\`, \`bool\`, \`enumField\`, \`float_\`, \`id\`, \`int_\`, \`json\`, \`optBigDecimal\`, \`optBigInt\`, \`optBool\`, \`optEnumField\`, \`optFloat\`, \`optInt\`, \`optString\`, \`optTimestamp\`, \`string\`, \`timestamp\`
FROM (
  SELECT \`arrayOfBigDecimals\`, \`arrayOfBigInts\`, \`arrayOfFloats\`, \`arrayOfInts\`, \`arrayOfStrings\`, \`bigDecimal\`, \`bigDecimalWithConfig\`, \`bigInt\`, \`bool\`, \`enumField\`, \`float_\`, \`id\`, \`int_\`, \`json\`, \`optBigDecimal\`, \`optBigInt\`, \`optBool\`, \`optEnumField\`, \`optFloat\`, \`optInt\`, \`optString\`, \`optTimestamp\`, \`string\`, \`timestamp\`, \`envio_change\`
  FROM test_db.\`envio_history_EntityWithAllTypes\`
  ORDER BY \`envio_checkpoint_id\` DESC
  LIMIT 1 BY \`id\`
)
WHERE \`envio_change\` = 'SET'`

        Assert.equal(query, expectedQuery, ~message="A entity view SQL should match exactly")
      },
    )
  })
})
