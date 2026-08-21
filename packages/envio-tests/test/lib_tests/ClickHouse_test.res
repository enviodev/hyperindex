open Vitest

// `EntityWithAllTypes` covers every scalar, list and enum column the schema
// language offers, so one entity pins the ClickHouse type mapping for all of
// them. Parsed straight from the user API rather than through `Scenario`: these
// cases assert on generated DDL, so the backend must not reshape the config.
let allTypesConfig = InternalTestIndexer.fromUserApi(
  ~schema=`
enum AccountType {
  ADMIN
  USER
}

type EntityWithAllTypes {
  id: ID!
  string: String!
  optString: String
  arrayOfStrings: [String!]!
  int_: Int!
  optInt: Int
  arrayOfInts: [Int!]!
  float_: Float!
  optFloat: Float
  arrayOfFloats: [Float!]!
  bool: Boolean!
  optBool: Boolean
  bigInt: BigInt!
  optBigInt: BigInt
  arrayOfBigInts: [BigInt!]!
  bigDecimal: BigDecimal!
  optBigDecimal: BigDecimal
  bigDecimalWithConfig: BigDecimal! @config(precision: 10, scale: 8)
  arrayOfBigDecimals: [BigDecimal!]!
  timestamp: Timestamp!
  optTimestamp: Timestamp
  json: Json!
  enumField: AccountType!
  optEnumField: AccountType
}
`,
  ~configYaml=`
name: clickhouse-all-types
chains:
  - id: 1
    start_block: 0
`,
).config

let allTypesEntityConfig = allTypesConfig.userEntitiesByName->Dict.getUnsafe("EntityWithAllTypes")

// The generated entity record, restated. Enum columns are plain strings here —
// the variant only exists in a generated project.
type entityWithAllTypes = {
  id: string,
  string: string,
  optString: option<string>,
  arrayOfStrings: array<string>,
  int_: int,
  optInt: option<int>,
  arrayOfInts: array<int>,
  float_: float,
  optFloat: option<float>,
  arrayOfFloats: array<float>,
  bool: bool,
  optBool: option<bool>,
  bigInt: bigint,
  optBigInt: option<bigint>,
  arrayOfBigInts: array<bigint>,
  bigDecimal: BigDecimal.t,
  optBigDecimal: option<BigDecimal.t>,
  bigDecimalWithConfig: BigDecimal.t,
  arrayOfBigDecimals: array<BigDecimal.t>,
  timestamp: Date.t,
  optTimestamp: option<Date.t>,
  json: JSON.t,
  enumField: string,
  optEnumField: option<string>,
}

describe("Test makeClickHouseEntitySchema", () => {
  Async.it("Should serialize Date fields using getTime() instead of ISO string", async t => {
    let entityConfig = allTypesEntityConfig

    // Create a schema using makeClickHouseEntitySchema
    let clickHouseSchema = ClickHouse.makeClickHouseEntitySchema(entityConfig.table)

    // Create a test entity with nullable timestamp
    let testDate = Date.fromTime(1234567890123.0)
    let testEntity: entityWithAllTypes = {
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
      enumField: "ADMIN",
      optEnumField: None,
    }

    // Serialize the entity using the ClickHouse schema
    let serialized =
      testEntity
      ->(Utils.magic: entityWithAllTypes => Internal.entity)
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

describe("databaseEngineName", () => {
  Async.it("Should strip arguments and a trailing SETTINGS clause", async t => {
    let names =
      [
        "Replicated('/clickhouse/databases/db', '{shard}', '{replica}')",
        "Replicated('/clickhouse/databases/db', '{shard}', '{replica}') SETTINGS max_broken_tables_ratio=1",
        "Replicated SETTINGS max_broken_tables_ratio=1",
        "  Replicated  ",
        "Atomic",
      ]->Array.map(ClickHouse.databaseEngineName)

    t.expect(names).toEqual(["Replicated", "Replicated", "Replicated", "Replicated", "Atomic"])
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

    Async.it(
      "Should add ON CLUSTER and ReplicatedMergeTree when replicated",
      async t => {
        let query = ClickHouse.makeCreateCheckpointsTableQuery(
          ~database="test_db",
          ~replicated=true,
          ~onCluster=true,
        )

        let expectedQuery = `CREATE TABLE IF NOT EXISTS test_db.\`envio_checkpoints\` ON CLUSTER '{cluster}' (
  \`id\` UInt64,
  \`chain_id\` Int32,
  \`block_number\` Int32,
  \`block_hash\` Nullable(String),
  \`events_processed\` UInt64
)
ENGINE = ReplicatedMergeTree
ORDER BY (id)
SETTINGS replicated_deduplication_window = 0`

        t.expect(query, ~message="Replicated checkpoints table SQL should match exactly").toBe(
          expectedQuery,
        )
      },
    )

    Async.it(
      "Should use ReplicatedMergeTree without ON CLUSTER for Replicated database engine",
      async t => {
        let query = ClickHouse.makeCreateCheckpointsTableQuery(
          ~database="test_db",
          ~replicated=true,
        )

        let expectedQuery = `CREATE TABLE IF NOT EXISTS test_db.\`envio_checkpoints\` (
  \`id\` UInt64,
  \`chain_id\` Int32,
  \`block_number\` Int32,
  \`block_hash\` Nullable(String),
  \`events_processed\` UInt64
)
ENGINE = ReplicatedMergeTree
ORDER BY (id)
SETTINGS replicated_deduplication_window = 0`

        t.expect(
          query,
          ~message="Replicated-engine checkpoints table SQL should match exactly",
        ).toBe(expectedQuery)
      },
    )
  })

  describe("makeCreateHistoryTableQuery", () => {
    Async.it(
      "Should create SQL for A entity history table",
      async t => {
        let entityConfig = allTypesEntityConfig
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

    Async.it(
      "Should add ON CLUSTER and ReplicatedMergeTree when replicated",
      async t => {
        let entityConfig = allTypesEntityConfig
        let query = ClickHouse.makeCreateHistoryTableQuery(
          ~entityConfig,
          ~database="test_db",
          ~replicated=true,
          ~onCluster=true,
        )

        let expectedQuery = `CREATE TABLE IF NOT EXISTS test_db.\`envio_history_EntityWithAllTypes\` ON CLUSTER '{cluster}' (
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
ENGINE = ReplicatedMergeTree
ORDER BY (id, envio_checkpoint_id)
SETTINGS replicated_deduplication_window = 0`

        t.expect(query, ~message="Replicated entity history table SQL should match exactly").toBe(
          expectedQuery,
        )
      },
    )
  })

  describe("makeCreateHistoryTableQuery with @storage(clickhouse: {...}) table options", () => {
    Async.it(
      "Should apply partitionBy, orderBy and ttl to the history table SQL",
      async t => {
        let config = InternalTestIndexer.fromUserApi(
          ~schema=`
type Transfer @storage(clickhouse: {
  partitionBy: "toYYYYMM(timestamp)",
  orderBy: ["timestamp"],
  ttl: "timestamp + INTERVAL 2 YEAR"
}) {
  id: ID!
  timestamp: Timestamp!
  amount: BigInt!
}
`,
          ~configYaml=`
name: clickhouse-options
storage:
  postgres:
    default: true
  clickhouse: true
chains:
  - id: 1
    start_block: 0
`,
        ).config
        let entityConfig = config.userEntitiesByName->Dict.getUnsafe("Transfer")

        let query = ClickHouse.makeCreateHistoryTableQuery(~entityConfig, ~database="test_db")

        t.expect(
          {
            "storage": entityConfig.storage,
            "query": query,
          },
          ~message="Table options should reach the entity storage and the history table SQL",
        ).toEqual({
          "storage": (
            {
              postgres: false,
              clickhouse: true,
              clickhouseOptions: {
                partitionBy: "toYYYYMM(timestamp)",
                orderBy: ["timestamp"],
                ttl: "timestamp + INTERVAL 2 YEAR",
              },
            }: Internal.entityStorage
          ),
          "query": `CREATE TABLE IF NOT EXISTS test_db.\`envio_history_Transfer\` (
  \`id\` String,
  \`timestamp\` DateTime64(3, 'UTC'),
  \`amount\` String,
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(\`timestamp\`)
ORDER BY (\`timestamp\`, envio_checkpoint_id)
TTL \`timestamp\` + INTERVAL 2 YEAR`,
        })
      },
    )

    Async.it(
      "Should resolve orderBy field names to renamed and linked-entity columns",
      async t => {
        let config = InternalTestIndexer.fromUserApi(
          ~schema=`
type Trade @storage(clickhouse: {orderBy: ["baseToken", "tradeTime"]}) {
  id: ID!
  baseToken: Token!
  tradeTime: Timestamp!
}

type Token @storage(clickhouse: true) {
  id: ID!
}
`,
          ~configYaml=`
name: clickhouse-order-by
storage:
  postgres:
    default: true
  clickhouse:
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
`,
        ).config
        let entityConfig = config.userEntitiesByName->Dict.getUnsafe("Trade")

        let query = ClickHouse.makeCreateHistoryTableQuery(~entityConfig, ~database="test_db")

        t.expect(
          query,
          ~message="orderBy should use the ClickHouse column names, not the schema field names",
        ).toBe(`CREATE TABLE IF NOT EXISTS test_db.\`envio_history_Trade\` (
  \`id\` String,
  \`base_token_id\` String,
  \`trade_time\` DateTime64(3, 'UTC'),
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (\`base_token_id\`, \`trade_time\`, envio_checkpoint_id)`)
      },
    )

    Async.it(
      "Should resolve schema field names inside partitionBy and ttl expressions to columns",
      async t => {
        let config = InternalTestIndexer.fromUserApi(
          ~schema=`
type Trade @storage(clickhouse: {
  partitionBy: "toYYYYMM(tradeTime)",
  ttl: "tradeTime + INTERVAL 1 YEAR DELETE WHERE baseToken != ''"
}) {
  id: ID!
  baseToken: Token!
  tradeTime: Timestamp!
}

type Token @storage(clickhouse: true) {
  id: ID!
}
`,
          ~configYaml=`
name: clickhouse-expression-columns
storage:
  postgres:
    default: true
  clickhouse:
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
`,
        ).config
        let entityConfig = config.userEntitiesByName->Dict.getUnsafe("Trade")

        let query = ClickHouse.makeCreateHistoryTableQuery(~entityConfig, ~database="test_db")

        t.expect(
          query,
          ~message="partitionBy/ttl field references should resolve to ClickHouse columns, leaving functions, keywords and string literals untouched",
        ).toBe(`CREATE TABLE IF NOT EXISTS test_db.\`envio_history_Trade\` (
  \`id\` String,
  \`base_token_id\` String,
  \`trade_time\` DateTime64(3, 'UTC'),
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(\`trade_time\`)
ORDER BY (id, envio_checkpoint_id)
TTL \`trade_time\` + INTERVAL 1 YEAR DELETE WHERE \`base_token_id\` != ''`)
      },
    )

    Async.it(
      "Should emit data skipping indexes with expressions resolved to columns",
      async t => {
        // https://github.com/enviodev/hyperindex/issues/1524
        let config = InternalTestIndexer.fromUserApi(
          ~schema=`
type Transfer @storage(clickhouse: {
  orderBy: ["timestamp"],
  skippingIndexes: [
    { name: "idx_from", expr: "fromAddress", type: "bloom_filter(0.01)", granularity: 4 },
    { name: "idx_amount", expr: "amount", type: "minmax" }
  ]
}) {
  id: ID!
  fromAddress: String!
  timestamp: Timestamp!
  amount: BigInt!
}
`,
          ~configYaml=`
name: clickhouse-skipping-indexes
storage:
  postgres:
    default: true
  clickhouse:
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
`,
        ).config
        let entityConfig = config.userEntitiesByName->Dict.getUnsafe("Transfer")

        let query = ClickHouse.makeCreateHistoryTableQuery(~entityConfig, ~database="test_db")

        t.expect(
          {
            "storage": entityConfig.storage,
            "query": query,
          },
          ~message="Skipping indexes should reach the entity storage and the history table SQL",
        ).toEqual({
          "storage": (
            {
              postgres: false,
              clickhouse: true,
              clickhouseOptions: {
                orderBy: ["timestamp"],
                skippingIndexes: [
                  {
                    name: "idx_from",
                    expr: "fromAddress",
                    type_: "bloom_filter(0.01)",
                    granularity: 4,
                  },
                  {name: "idx_amount", expr: "amount", type_: "minmax"},
                ],
              },
            }: Internal.entityStorage
          ),
          "query": `CREATE TABLE IF NOT EXISTS test_db.\`envio_history_Transfer\` (
  \`id\` String,
  \`from_address\` String,
  \`timestamp\` DateTime64(3, 'UTC'),
  \`amount\` String,
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE'),
  INDEX \`idx_from\` \`from_address\` TYPE bloom_filter(0.01) GRANULARITY 4,
  INDEX \`idx_amount\` \`amount\` TYPE minmax
)
ENGINE = MergeTree()
ORDER BY (\`timestamp\`, envio_checkpoint_id)`,
        })
      },
    )

    Async.it(
      "Should create the declared skipping indexes on a live ClickHouse",
      async t => {
        let config = InternalTestIndexer.fromUserApi(
          ~schema=`
type Transfer @storage(clickhouse: {
  skippingIndexes: [
    { name: "idx_from", expr: "fromAddress", type: "bloom_filter(0.01)", granularity: 4 },
    { name: "idx_amount", expr: "amount", type: "minmax" }
  ]
}) {
  id: ID!
  fromAddress: String!
  amount: BigInt!
}
`,
          ~configYaml=`
name: clickhouse-skipping-indexes-live
storage:
  postgres:
    default: true
  clickhouse: true
chains:
  - id: 1
    start_block: 0
`,
        ).config
        let entityConfig = config.userEntitiesByName->Dict.getUnsafe("Transfer")

        let database = TestClickHouse.make()
        let client = ClickHouse.createClient({
          url: TestClickHouse.host(),
          username: TestClickHouse.username(),
          password: TestClickHouse.password(),
        })
        let indices = try {
          await ClickHouse.initialize(client, ~database, ~entities=[entityConfig], ~enums=[])
          await TestClickHouse.query(
            `SELECT name, type_full, toUInt32(granularity) AS granularity
FROM system.data_skipping_indices
WHERE database = '${database}' AND table = 'envio_history_Transfer'
ORDER BY name
FORMAT JSONCompactEachRow`,
          )
        } catch {
        | exn =>
          await TestClickHouse.drop(~database)
          await ClickHouse.close(client)
          throw(exn)
        }
        await TestClickHouse.drop(~database)
        await ClickHouse.close(client)

        t.expect(indices).toBe(`["idx_amount", "minmax", 1]
["idx_from", "bloom_filter(0.01)", 4]
`)
      },
    )
  })

  describe("makeCreateViewQuery", () => {
    Async.it(
      "Should create SQL for A entity view",
      async t => {
        let entity = allTypesEntityConfig
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

    Async.it(
      "Should add ON CLUSTER when replicated",
      async t => {
        let entity = allTypesEntityConfig
        let query = ClickHouse.makeCreateViewQuery(
          ~entityConfig=entity,
          ~database="test_db",
          ~onCluster=true,
        )

        let expectedQuery = `CREATE VIEW IF NOT EXISTS test_db.\`EntityWithAllTypes\` ON CLUSTER '{cluster}' AS
SELECT \`id\`, \`string\`, \`optString\`, \`arrayOfStrings\`, \`int_\`, \`optInt\`, \`arrayOfInts\`, \`float_\`, \`optFloat\`, \`arrayOfFloats\`, \`bool\`, \`optBool\`, \`bigInt\`, \`optBigInt\`, \`arrayOfBigInts\`, \`bigDecimal\`, \`optBigDecimal\`, \`bigDecimalWithConfig\`, \`arrayOfBigDecimals\`, \`timestamp\`, \`optTimestamp\`, \`json\`, \`enumField\`, \`optEnumField\`
FROM (
  SELECT \`id\`, \`string\`, \`optString\`, \`arrayOfStrings\`, \`int_\`, \`optInt\`, \`arrayOfInts\`, \`float_\`, \`optFloat\`, \`arrayOfFloats\`, \`bool\`, \`optBool\`, \`bigInt\`, \`optBigInt\`, \`arrayOfBigInts\`, \`bigDecimal\`, \`optBigDecimal\`, \`bigDecimalWithConfig\`, \`arrayOfBigDecimals\`, \`timestamp\`, \`optTimestamp\`, \`json\`, \`enumField\`, \`optEnumField\`, \`envio_change\`
  FROM test_db.\`envio_history_EntityWithAllTypes\`
  WHERE \`envio_checkpoint_id\` <= (SELECT max(id) FROM test_db.\`envio_checkpoints\`)
  ORDER BY \`envio_checkpoint_id\` DESC
  LIMIT 1 BY \`id\`
)
WHERE \`envio_change\` = 'SET'`

        t.expect(query, ~message="Replicated entity view SQL should match exactly").toBe(
          expectedQuery,
        )
      },
    )
  })
})
