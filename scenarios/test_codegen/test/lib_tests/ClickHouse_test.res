open Vitest

describe("Test makeClickHouseEntitySchema", () => {
  Async.it("Should serialize Date fields using getTime() instead of ISO string", async t => {
    let entityConfig = MockIndexer.entityConfig(EntityWithAllTypes)

    // Create a schema using makeClickHouseEntitySchema
    let clickHouseSchema = ClickHouse.makeClickHouseEntitySchema(entityConfig.table)

    // Create a test entity with nullable timestamp
    let testDate = Date.fromTime(1234567890123.0)
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

    t.expect(serialized, ~message="Entity should be serialized with timestamps as numbers").toEqual(
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
    )
  })
})

describe("Test ClickHouse SQL generation functions", () => {
  describe("makeCreateCheckpointsTableQuery", () => {
    Async.it(
      "Should create SQL for checkpoints table",
      async t => {
        let query = ClickHouse.makeCreateCheckpointsTableQuery(~database="test_db")

        let expectedQuery = `CREATE TABLE IF NOT EXISTS test_db.\`envio_checkpoints\` (
  \`id\` UInt64,
  \`chain_id\` Int32,
  \`block_number\` Int32,
  \`block_hash\` Nullable(String),
  \`events_processed\` UInt64
)
ENGINE = MergeTree()
ORDER BY (id)`

        t.expect(query, ~message="Checkpoints table SQL should match exactly").toBe(expectedQuery)
      },
    )
  })

  describe("makeCreateHistoryTableQuery", () => {
    Async.it(
      "Should create SQL for A entity history table",
      async t => {
        let entityConfig = MockIndexer.entityConfig(EntityWithAllTypes)
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
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (id, envio_checkpoint_id)`

        t.expect(query, ~message="A entity history table SQL should match exactly").toBe(
          expectedQuery,
        )
      },
    )
  })

  describe("makeCreateViewQuery", () => {
    Async.it(
      "Should create SQL for A entity view",
      async t => {
        let entity = MockIndexer.entityConfig(EntityWithAllTypes)
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

        t.expect(query, ~message="A entity view SQL should match exactly").toBe(expectedQuery)
      },
    )
  })
})

describe("Test collectChanges", () => {
  Async.it(
    "Flattens every update into its history changes followed by the latest change",
    async t => {
      let entity = (id): Internal.entity =>
        {"id": id}->(Utils.magic: {"id": string} => Internal.entity)
      let set = (~id, ~checkpointId): Change.t<Internal.entity> =>
        Change.Set({entityId: id, entity: entity(id), checkpointId: BigInt.fromInt(checkpointId)})
      let delete = (~id, ~checkpointId): Change.t<Internal.entity> =>
        Change.Delete({entityId: id, checkpointId: BigInt.fromInt(checkpointId)})

      let aV1 = set(~id="a", ~checkpointId=1)
      let aV2 = set(~id="a", ~checkpointId=2)
      let aV3 = set(~id="a", ~checkpointId=3)
      let bDelete = delete(~id="b", ~checkpointId=4)

      let updates: array<Internal.inMemoryStoreEntityUpdate> = [
        {latestChange: aV3, history: [aV1, aV2]},
        {latestChange: bDelete, history: []},
      ]

      t.expect(
        updates->ClickHouse.collectChanges(~convertOrThrow=change =>
          change->Change.getCheckpointId->BigInt.toString
        ),
        ~message="Should convert all history changes in order, then the latest change",
      ).toEqual(["1", "2", "3", "4"])
    },
  )
})
