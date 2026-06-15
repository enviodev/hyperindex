open Vitest

// A row shaped like ClickHouse query output for EntityWithAllTypes (timestamps
// in the default 'simple' format, quoted decimals and 64-bit integers, plus
// the envio_change column) and the entity it should parse into
let makeClickHouseRow: string => dict<unknown> = %raw(`(id) => ({
  "id": id,
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
  "timestamp": "2009-02-13 23:31:30.123",
  "optTimestamp": "2009-02-13 23:31:30.123",
  "json": "{}",
  "enumField": "ADMIN",
  "optEnumField": null,
  "envio_change": "SET"
})`)

let makeParsedEntity = (~id): Indexer.Entities.EntityWithAllTypes.t => {
  let testDate = Date.fromTime(1234567890123.0)
  {
    id,
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
    // The Json field round-trips as the string stored in the ClickHouse
    // String column
    json: %raw(`"{}"`),
    enumField: ADMIN,
    optEnumField: None,
  }
}

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

  describe("makeGetRollbackModifiedIdsQuery", () => {
    Async.it(
      "Should create SQL returning ids modified after the rollback target",
      async t => {
        let entityConfig = MockIndexer.entityConfig(EntityWithAllTypes)
        let query = ClickHouse.makeGetRollbackModifiedIdsQuery(
          ~entityConfig,
          ~database="test_db",
          ~rollbackTargetCheckpointId=100n,
        )

        let expectedQuery = `SELECT DISTINCT \`id\`
FROM test_db.\`envio_history_EntityWithAllTypes\`
WHERE \`envio_checkpoint_id\` > 100`

        t.expect(query, ~message="Modified ids SQL should match exactly").toBe(expectedQuery)
      },
    )
  })

  describe("makeGetRollbackRestoredEntitiesQuery", () => {
    Async.it(
      "Should create SQL returning the latest state at or before the rollback target",
      async t => {
        let entityConfig = MockIndexer.entityConfig(EntityWithAllTypes)
        let query = ClickHouse.makeGetRollbackRestoredEntitiesQuery(
          ~entityConfig,
          ~database="test_db",
          ~rollbackTargetCheckpointId=100n,
        )

        let expectedQuery = `SELECT \`id\`, \`string\`, \`optString\`, \`arrayOfStrings\`, \`int_\`, \`optInt\`, \`arrayOfInts\`, \`float_\`, \`optFloat\`, \`arrayOfFloats\`, \`bool\`, \`optBool\`, \`bigInt\`, \`optBigInt\`, \`arrayOfBigInts\`, \`bigDecimal\`, \`optBigDecimal\`, \`bigDecimalWithConfig\`, \`arrayOfBigDecimals\`, \`timestamp\`, \`optTimestamp\`, \`json\`, \`enumField\`, \`optEnumField\`, \`envio_change\`
FROM test_db.\`envio_history_EntityWithAllTypes\`
WHERE \`envio_checkpoint_id\` <= 100
  AND \`id\` IN (
    SELECT DISTINCT \`id\` FROM test_db.\`envio_history_EntityWithAllTypes\`
    WHERE \`envio_checkpoint_id\` > 100
  )
ORDER BY \`envio_checkpoint_id\` DESC
LIMIT 1 BY \`id\`
SETTINGS output_format_json_quote_decimals = 1`

        t.expect(query, ~message="Restored entities SQL should match exactly").toBe(expectedQuery)
      },
    )
  })
})

describe("Test getRollbackDataOrThrow", () => {
  let makeFakeClient = (
    ~modifiedRows: array<dict<unknown>>,
    ~restoredRows: array<dict<unknown>>,
  ): ClickHouse.client => {
    {
      "query": (params: ClickHouse.queryParams) =>
        Promise.resolve({
          "json": () =>
            Promise.resolve({
              "data": params.query->String.includes("LIMIT 1 BY") ? restoredRows : modifiedRows,
            }),
        }),
    }->(Utils.magic: 'a => ClickHouse.client)
  }

  Async.it("Should split modified ids into removed and restored", async t => {
    let entityConfig = MockIndexer.entityConfig(EntityWithAllTypes)

    let client = makeFakeClient(
      ~modifiedRows=[
        %raw(`{"id": "restored-id"}`),
        %raw(`{"id": "deleted-at-target-id"}`),
        %raw(`{"id": "created-after-target-id"}`),
      ],
      ~restoredRows=[
        makeClickHouseRow("restored-id"),
        // The latest change at or before the target is a DELETE, so the
        // entity didn't exist at the rollback point
        %raw(`{"id": "deleted-at-target-id", "envio_change": "DELETE"}`),
      ],
    )

    let (removedIds, restoredEntities) = await ClickHouse.getRollbackDataOrThrow(
      client,
      ~database="test_db",
      ~entityConfig,
      ~rollbackTargetCheckpointId=100n,
    )

    t.expect(
      {"removedIds": removedIds, "restoredEntities": restoredEntities},
      ~message="DELETE-at-target and created-after-target ids should be removed, the rest restored",
    ).toEqual({
      "removedIds": [{"id": "deleted-at-target-id"}, {"id": "created-after-target-id"}],
      "restoredEntities": [
        makeParsedEntity(~id="restored-id")->(
          Utils.magic: Indexer.Entities.EntityWithAllTypes.t => Internal.entity
        ),
      ],
    })
  })
})

describe("Test makeClickHouseEntitySchema parsing", () => {
  Async.it("Should parse a ClickHouse history row back into an entity", async t => {
    let entityConfig = MockIndexer.entityConfig(EntityWithAllTypes)
    let clickHouseSchema = ClickHouse.makeClickHouseEntitySchema(entityConfig.table)

    // The schema should ignore the row's envio_change column
    let parsed = makeClickHouseRow("test-id")->S.parseOrThrow(clickHouseSchema)
    let expectedEntity = makeParsedEntity(~id="test-id")

    t.expect(parsed, ~message="Row should parse back into the entity").toEqual(
      expectedEntity->(Utils.magic: Indexer.Entities.EntityWithAllTypes.t => Internal.entity),
    )
  })

  Async.it("Should parse every ClickHouse DateTime output format", async t => {
    let parse = value => value->S.parseOrThrow(Utils.Schema.clickHouseDate)

    t.expect(
      [
        %raw(`"2009-02-13 23:31:30.123"`)->parse,
        %raw(`"2009-02-13T23:31:30.123Z"`)->parse,
        %raw(`1234567890.5`)->parse,
      ],
      ~message="simple, iso and unix_timestamp formats should all parse",
    ).toEqual([
      Date.fromTime(1234567890123.0),
      Date.fromTime(1234567890123.0),
      Date.fromTime(1234567890500.0),
    ])
  })

  Async.it("Should throw on an invalid ClickHouse DateTime value", async t => {
    t.expect(() =>
      %raw(`"not a date"`)->S.parseOrThrow(Utils.Schema.clickHouseDate)->ignore
    ).toThrow()
  })
})
