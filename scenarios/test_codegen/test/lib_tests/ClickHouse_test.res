open RescriptMocha

describe("Test makeClickHouseEntitySchema", () => {
  Async.it("Should serialize Date fields using getTime() instead of ISO string", async () => {
    let entityConfig = Mock.entityConfig(EntityWithAllTypes)

    // Create a schema using makeClickHouseEntitySchema
    let clickHouseSchema = ClickHouse.makeClickHouseEntitySchema(entityConfig.table)

    // Create a test entity with nullable timestamp
    let testDate = Js.Date.fromFloat(1234567890123.0)
    let testEntity: Indexer.Entities.EntityWithAllTypes.t = {
      id: "test-id",
      string: "test",
      optString: None,
      arrayOfStrings: [],
      int_: 1,
      optInt: None,
      arrayOfInts: [],
      float_: 1.0,
      optFloat: None,
      arrayOfFloats: [],
      bool: true,
      optBool: None,
      bigInt: BigInt.fromInt(1),
      optBigInt: None,
      arrayOfBigInts: [],
      bigDecimal: BigDecimal.fromFloat(1.0),
      optBigDecimal: None,
      bigDecimalWithConfig: BigDecimal.fromFloat(1.0),
      arrayOfBigDecimals: [],
      timestamp: testDate,
      optTimestamp: Some(testDate),
      json: %raw(`{}`),
      enumField: ADMIN,
      optEnumField: None,
    }

    // Serialize the entity using the ClickHouse schema
    let serialized =
      testEntity
      ->(Utils.magic: Indexer.Entities.EntityWithAllTypes.t => Internal.entity)
      ->S.reverseConvertToJsonOrThrow(clickHouseSchema)

    Assert.deepEqual(
      serialized,
      %raw(`{
          "id": "test-id",
          "string": "test",
          "optString": null,
          "arrayOfStrings": [],
          "int_": 1,
          "optInt": null,
          "arrayOfInts": [],
          "float_": 1.0,
          "optFloat": null,
          "arrayOfFloats": [],
          "bool": true,
          "optBool": null,
          "bigInt": "1",
          "optBigInt": null,
          "arrayOfBigInts": [],
          "bigDecimal": "1",
          "optBigDecimal": null,
          "bigDecimalWithConfig": "1",
          "arrayOfBigDecimals": [],
          "timestamp": 1234567890123.0,
          "optTimestamp": 1234567890123.0,
          "json": {},
          "enumField": "ADMIN",
          "optEnumField": null
        }`),
      ~message="Entity should be serialized with timestamps as numbers",
    )
  })
})

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
        let entityConfig = Mock.entityConfig(EntityWithAllTypes)
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
        let entity = Mock.entityConfig(EntityWithAllTypes)
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
