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
  ~handlers=`
import { indexer, BigDecimal } from "envio";

const timestamp = new Date(1234567890123);

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ context }) => {
  context.EveryType.set({
    id: "0x5c4f2e1d9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d",
    // Not ASCII on purpose: RowBinary prefixes a string with its length in UTF-8
    // bytes, which is not the length JS reports for anything outside Latin-1. "é"
    // is one UTF-16 unit over two bytes, "😀" is two units over four. Both values
    // also run past the length where staging copies a string in bulk instead of
    // character by character, which is where a mis-sized reservation would show.
    string: "héllo 😀 and the quick brown fox jumps over the lazy dog",
    optString: undefined,
    arrayOfStrings: ["a", "日本"],
    int_: -7,
    optInt: 3,
    arrayOfInts: [1, 2],
    float_: 1.5,
    optFloat: undefined,
    arrayOfFloats: [0.5, 2.5],
    bool: true,
    optBool: false,
    bigInt: 123456789012345678901234567890n,
    optBigInt: undefined,
    arrayOfBigInts: [1n, 2n],
    bigDecimal: new BigDecimal("1.25"),
    optBigDecimal: undefined,
    bigDecimalWithConfig: new BigDecimal("12.00000001"),
    arrayOfBigDecimals: [new BigDecimal("3.5")],
    timestamp,
    optTimestamp: timestamp,
    json: { nested: [1, 2] },
    optJson: undefined,
    optJsonNull: null,
    // The case a String element has to hold something that is not a string,
    // which the column takes as the element's JSON text.
    arrayOfJson: [{ a: 1 }, 2, true, "s"],
    enumField: "ADMIN",
    optEnumField: undefined,
  });
});
`,
  ~unsupported=[{backend: #postgres, reason: "asserts against a ClickHouse server"}],
)

describe("ClickHouse stores every schema type", () => {
  scenario->Scenario.it("reads back each column as it was written", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let source = source(1)
    source.resolveGetHeightOrThrow(10)

    await source.expectItemsQueries([
      {
        fromBlock: 0,
        toBlock: Unbounded,
        reply: Respond({
          items: [{event: "Token.Transfer", blockNumber: 5, logIndex: 0}],
          latestFetchedBlockNumber: 10,
        }),
      },
    ])
    await indexer.getBatchWritePromise()

    let database = TestClickHouse.currentDatabase()
    let rows = await TestClickHouse.query(
      `SELECT * FROM \`${database}\`.\`EveryType\` FORMAT JSONEachRow`,
    )

    t.expect(rows->String.trim->JSON.parseOrThrow).toStrictEqual(
      %raw(`{
          id: "0x5c4f2e1d9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d",
          string: "héllo 😀 and the quick brown fox jumps over the lazy dog",
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
