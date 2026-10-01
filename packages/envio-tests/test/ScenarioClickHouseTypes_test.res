open Vitest

// Drives an indexer that writes one entity of every schema type into ClickHouse
// and reads it back through the current-state view.
//
// The RowBinary encoder decides byte layout per column type and the server
// accepts whatever it is handed, so a wrong Decimal scale, enum number or
// DateTime64 tick is stored silently and shows up nowhere but the stored value.
// Going through a real run also covers what a unit test cannot: the table
// registration the sink does at startup, the checkpoint ordering the view reads
// through, and the entity serializers.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-types
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
enum AccountType {
  ADMIN
  USER
}

type EveryType {
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
  optJson: Json
  optJsonNull: Json
  arrayOfJson: [Json!]!
  enumField: AccountType!
  optEnumField: AccountType
}
`,
  ~unsupported=[{backend: #postgres, reason: "asserts against a ClickHouse server"}],
)

type everyType = {
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
  optJson: option<JSON.t>,
  optJsonNull: option<JSON.t>,
  arrayOfJson: array<JSON.t>,
  enumField: string,
  optEnumField: option<string>,
}
type everyTypeOps = {set: everyType => unit}
type handlerContext = {@as("EveryType") everyType: everyTypeOps}

let timestamp = Date.fromTime(1234567890123.0)

// Not ASCII on purpose: RowBinary prefixes a string with its length in UTF-8
// bytes, which is not the length JS reports for anything outside Latin-1. "é"
// is one UTF-16 unit over two bytes, "😀" is two units over four.
let entity = {
  id: "every-1",
  string: "héllo 😀",
  optString: None,
  arrayOfStrings: ["a", "日本"],
  int_: -7,
  optInt: Some(3),
  arrayOfInts: [1, 2],
  float_: 1.5,
  optFloat: None,
  arrayOfFloats: [0.5, 2.5],
  bool: true,
  optBool: Some(false),
  bigInt: 123456789012345678901234567890n,
  optBigInt: None,
  arrayOfBigInts: [1n, 2n],
  bigDecimal: BigDecimal.fromStringUnsafe("1.25"),
  optBigDecimal: None,
  bigDecimalWithConfig: BigDecimal.fromStringUnsafe("12.00000001"),
  arrayOfBigDecimals: [BigDecimal.fromStringUnsafe("3.5")],
  timestamp,
  optTimestamp: Some(timestamp),
  json: %raw(`{"nested": [1, 2]}`),
  optJson: None,
  optJsonNull: Some(%raw(`null`)),
  // The case a String element has to hold something that is not a string,
  // which the column takes as the element's JSON text.
  arrayOfJson: %raw(`[{"a": 1}, 2, true, "s"]`),
  enumField: "ADMIN",
  optEnumField: None,
}

describe("ClickHouse stores every schema type", () => {
  scenario->Scenario.it("reads back each column as it was written", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let source = source(1)
    source.resolveGetHeightOrThrow(10)

    source.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 5,
          logIndex: 0,
          handler: async args => {
            let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
            context.everyType.set(entity)
          },
        },
      ],
      ~latestFetchedBlockNumber=10,
    )
    await indexer.getBatchWritePromise()

    let database = TestClickHouse.currentDatabase()
    let rows = await TestClickHouse.query(
      `SELECT * FROM \`${database}\`.\`EveryType\` FORMAT JSONEachRow`,
    )

    t.expect(rows->String.trim->JSON.parseOrThrow).toStrictEqual(
      %raw(`{
          id: "every-1",
          string: "héllo 😀",
          optString: null,
          arrayOfStrings: ["a", "日本"],
          int_: -7,
          optInt: 3,
          arrayOfInts: [1, 2],
          float_: 1.5,
          optFloat: null,
          arrayOfFloats: [0.5, 2.5],
          bool: true,
          optBool: false,
          // Wider than Decimal(38) holds, so the column is a String.
          bigInt: "123456789012345678901234567890",
          optBigInt: null,
          arrayOfBigInts: ["1", "2"],
          bigDecimal: "1.25",
          optBigDecimal: null,
          // A bounded BigDecimal is a real Decimal(10, 8) column, which JSON
          // renders as a number — the unbounded ones above fall back to String.
          bigDecimalWithConfig: 12.00000001,
          arrayOfBigDecimals: ["3.5"],
          timestamp: "2009-02-13 23:31:30.123",
          optTimestamp: "2009-02-13 23:31:30.123",
          json: '{"nested":[1,2]}',
          // A Json column is a String holding the document's text whether or
          // not the field is nullable, so both ways of holding no document read
          // back as the text of JSON null rather than as an absent value.
          optJson: "null",
          optJsonNull: "null",
          // A String element holds whatever text it is given.
          arrayOfJson: ['{"a":1}', "2", "true", "s"],
          enumField: "ADMIN",
          optEnumField: null,
        }`),
    )
  })
})
