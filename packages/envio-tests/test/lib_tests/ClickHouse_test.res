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

// The staging path writes each column by its position in this list, so what
// crosses to Rust is pinned whole rather than column by column.
describe("ClickHouse checkpoints columns", () => {
  Async.it("register in the order a batch's values are written", async t => {
    t.expect(
      ClickHouse.checkpointColumnSpecs->Array.map(({name, fieldType}) => (name, fieldType)),
    ).toEqual([
      ("id", "UInt64"),
      ("chain_id", "ChainId"),
      ("block_number", "Int32"),
      ("block_hash", "String"),
      // Wider than the Int32 Postgres keeps the count in.
      ("events_processed", "UInt64"),
    ])
  })
})
