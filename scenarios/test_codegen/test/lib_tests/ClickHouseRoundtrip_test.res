open Vitest

// Writes one row of every schema type through the Rust sink and reads it back
// out of ClickHouse. The RowBinary encoder decides byte layout per column type,
// so nothing short of a real server confirms it: a wrong Decimal scale or enum
// value is accepted silently and only shows up in the stored value.

// Runs when ClickHouse is configured, which is what the CI job for this scenario
// and `envio dev` both provide. A developer without one gets a skip rather than a
// failure; a configured-but-unreachable server fails loudly.
let chHost = Env.ClickHouse.host()
let username = Env.ClickHouse.username()->Option.getOr("default")
let password = Env.ClickHouse.password()->Option.getOr("testing")
let database = "test_codegen_roundtrip"

let timestamp = Date.fromTime(1234567890123.0)

let entity: Indexer.Entities.EntityWithAllTypes.t = {
  id: "roundtrip-1",
  string: "hello",
  optString: None,
  arrayOfStrings: ["a", "b"],
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
  enumField: ADMIN,
  optEnumField: None,
}

describe("ClickHouse RowBinary roundtrip", () => {
  Async.it_skipIf(chHost->Option.isNone)(
    "Stores every field type as ClickHouse reads it back",
    async t => {
      let host = chHost->Option.getUnsafe
      let entityConfig = MockIndexer.entityConfig("EntityWithAllTypes")
      let tableName = EntityHistory.historyTableName(
        ~entityName=entityConfig.name,
        ~entityIndex=entityConfig.index,
      )

      let client = ClickHouse.createClient({url: host, username, password})
      await client->ClickHouse.exec({query: `DROP DATABASE IF EXISTS ${database}`})
      await client->ClickHouse.exec({query: `CREATE DATABASE ${database}`})
      await client->ClickHouse.exec({
        query: ClickHouse.makeCreateHistoryTableQuery(~entityConfig, ~database),
      })

      let sink = ClickHouseSink.make(~url=host, ~username, ~password, ~database)
      await ClickHouse.setUpdatesOrThrow(
        sink,
        ~cache=Dict.make(),
        ~changes=[
          Set({
            entityId: entity.id->EntityId.unsafeOfString,
            checkpointId: 11n,
            entity: entity->(Utils.magic: Indexer.Entities.EntityWithAllTypes.t => Internal.entity),
          }),
          // A delete row carries only its id and checkpoint; every other column
          // has to fall back to the type's ClickHouse default.
          Delete({entityId: "roundtrip-2"->EntityId.unsafeOfString, checkpointId: 12n}),
        ],
        ~entityConfig,
        ~scope=CrossChain,
        ~chainIdMode=Int32,
      )

      let result = await client->ClickHouse.query({
        query: `SELECT * FROM ${database}.\`${tableName}\` ORDER BY envio_checkpoint_id`,
      })
      let rows = (await result->ClickHouse.json)["data"]
      await client->ClickHouse.close

      t.expect(rows).toEqual(
        %raw(`[
          {
            id: "roundtrip-1",
            string: "hello",
            optString: null,
            arrayOfStrings: ["a", "b"],
            int_: -7,
            optInt: 3,
            arrayOfInts: [1, 2],
            float_: 1.5,
            optFloat: null,
            arrayOfFloats: [0.5, 2.5],
            bool: true,
            optBool: false,
            bigInt: "123456789012345678901234567890",
            optBigInt: null,
            arrayOfBigInts: ["1", "2"],
            bigDecimal: "1.25",
            optBigDecimal: null,
            bigDecimalWithConfig: 12.00000001,
            arrayOfBigDecimals: ["3.5"],
            timestamp: "2009-02-13 23:31:30.123",
            optTimestamp: "2009-02-13 23:31:30.123",
            json: "{\"nested\":[1,2]}",
            enumField: "ADMIN",
            optEnumField: null,
            envio_checkpoint_id: 11,
            envio_change: "SET"
          },
          {
            id: "roundtrip-2",
            string: "",
            optString: null,
            arrayOfStrings: [],
            int_: 0,
            optInt: null,
            arrayOfInts: [],
            float_: 0,
            optFloat: null,
            arrayOfFloats: [],
            bool: false,
            optBool: null,
            bigInt: "",
            optBigInt: null,
            arrayOfBigInts: [],
            bigDecimal: "",
            optBigDecimal: null,
            bigDecimalWithConfig: 0,
            arrayOfBigDecimals: [],
            timestamp: "1970-01-01 00:00:00.000",
            optTimestamp: null,
            json: "",
            // ClickHouse defaults an omitted Enum column to its first declared
            // variant, and AccountType declares ADMIN first.
            enumField: "ADMIN",
            optEnumField: null,
            envio_checkpoint_id: 12,
            envio_change: "DELETE"
          }
        ]`),
      )
    },
  )
})
