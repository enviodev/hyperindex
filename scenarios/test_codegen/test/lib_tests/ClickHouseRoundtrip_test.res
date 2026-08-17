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

// Half of a surrogate pair each. ReScript rejects a lone surrogate as a string
// literal escape, so they are built from their code units.
let highSurrogate = String.fromCharCode(0xD800)
let lowSurrogate = String.fromCharCode(0xDC00)

let entity: Indexer.Entities.EntityWithAllTypes.t = {
  id: "roundtrip-1",
  // Not ASCII on purpose: the sink hands Rust one concatenated string per column
  // plus each value's UTF-16 length, and Rust has to re-split it over UTF-8
  // bytes. "é" is one UTF-16 unit over two bytes, "😀" is two units over four.
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

      let sink = ClickHouseSink.make(~url=host, ~username, ~password, ~database, ~onWarning=ignore)
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
  // The chain-id column widens to UInt64 in Int64 mode, which is a different
  // wire kind — a chain id past Int32 has to survive it.
  Async.it_skipIf(chHost->Option.isNone)(
    "Stores a chain id beyond Int32 when the config widens the column",
    async t => {
      let host = chHost->Option.getUnsafe
      let database = "test_codegen_roundtrip_int64"
      // Past Int32, so it needs the widened column; ReScript's `int` cannot
      // hold it, which is why it comes in through the chain-id schema.
      let bigChainId = "4294967296"->ChainId.normalizeOrThrow

      let client = ClickHouse.createClient({url: host, username, password})
      await client->ClickHouse.exec({query: `DROP DATABASE IF EXISTS ${database}`})
      await client->ClickHouse.exec({query: `CREATE DATABASE ${database}`})
      await client->ClickHouse.exec({
        query: ClickHouse.makeCreateCheckpointsTableQuery(~database, ~chainIdMode=Int64),
      })

      let sink = ClickHouseSink.make(~url=host, ~username, ~password, ~database, ~onWarning=ignore)
      await ClickHouse.setCheckpointsOrThrow(
        sink,
        ~batch={
          totalBatchSize: 1,
          items: [],
          progressedChainsById: Dict.make(),
          isInReorgThreshold: false,
          checkpointIds: [18446744073709551615n],
          checkpointChainIds: [bigChainId],
          checkpointBlockNumbers: [123],
          checkpointBlockHashes: [Null.make("0xabc")],
          checkpointEventsProcessed: [7],
        },
        ~chainIdMode=Int64,
      )

      let result = await client->ClickHouse.query({
        query: `SELECT toString(id) AS id, toString(chain_id) AS chain_id, block_number, block_hash, toString(events_processed) AS events_processed FROM ${database}.envio_checkpoints`,
      })
      let rows = (await result->ClickHouse.json)["data"]
      await client->ClickHouse.exec({query: `DROP DATABASE ${database}`})
      await client->ClickHouse.close

      t.expect(rows).toEqual(
        %raw(`[
          {
            id: "18446744073709551615",
            chain_id: "4294967296",
            block_number: 123,
            block_hash: "0xabc",
            events_processed: "7"
          }
        ]`),
      )
    },
  )

  // The indexer's error handling matches on StorageError, so both ways a value
  // can be rejected have to arrive as one: the entity schema refuses it while
  // building the columns, or the RowBinary encoder refuses it in Rust.
  Async.it_skipIf(chHost->Option.isNone)(
    "Reports a value neither side can encode as a StorageError",
    async t => {
      let host = chHost->Option.getUnsafe
      let database = "test_codegen_roundtrip_reject"
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
      let sink = ClickHouseSink.make(~url=host, ~username, ~password, ~database, ~onWarning=ignore)

      let attempt = async rogue => {
        switch await ClickHouse.setUpdatesOrThrow(
          sink,
          ~cache=Dict.make(),
          ~changes=[
            Set({
              entityId: entity.id->EntityId.unsafeOfString,
              checkpointId: 1n,
              entity: rogue->(Utils.magic: Indexer.Entities.EntityWithAllTypes.t => Internal.entity),
            }),
          ],
          ~entityConfig,
          ~scope=CrossChain,
          ~chainIdMode=Int32,
        ) {
        | () => ("no error", "")
        | exception Persistence.StorageError({message, reason}) => (
            message,
            reason->(Utils.magic: exn => {"message": string})->(r => r["message"]),
          )
        | exception _ => ("not a StorageError", "")
        }
      }

      // Outside the schema's enum, so the entity schema rejects it first.
      let (schemaMessage, schemaReason) = await attempt({
        ...entity,
        enumField: "NOT_A_VARIANT"->(Utils.magic: string => Indexer.Enums.AccountType.t),
      })
      // Valid BigDecimal, but past what `Decimal(10, 8)` accepts. RowBinary
      // carries the raw integer, so only the encoder can catch it — the server
      // would store whatever the bytes happen to mean.
      let (encoderMessage, encoderReason) = await attempt({
        ...entity,
        bigDecimalWithConfig: BigDecimal.fromStringUnsafe("1e5"),
      })

      await client->ClickHouse.exec({query: `DROP DATABASE ${database}`})
      await client->ClickHouse.close

      t.expect((
        schemaMessage,
        schemaReason->String.includes("NOT_A_VARIANT"),
        encoderMessage,
        encoderReason->String.includes("out of range for a Decimal"),
      )).toEqual((
        `Failed to convert items for ClickHouse table "${tableName}"`,
        true,
        `Failed to insert items into ClickHouse table "${tableName}"`,
        true,
      ))
    },
  )
  // Values reach Rust as one concatenated string per column plus each value's
  // UTF-16 length. A lone surrogate is not a character and napi substitutes
  // U+FFFD for one, which costs a value nothing on its own — but a value ending
  // in a high surrogate next to one starting with a low surrogate spells a real
  // pair across the seam, which encodes as a single character where the lengths
  // claim two. The whole column then fails to split, and no retry can help
  // because the batch is unchanged.
  Async.it_skipIf(chHost->Option.isNone)(
    "Stores values whose lone surrogates would pair across the concatenation",
    async t => {
      let host = chHost->Option.getUnsafe
      let database = "test_codegen_roundtrip_surrogate"
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

      let sink = ClickHouseSink.make(~url=host, ~username, ~password, ~database, ~onWarning=ignore)
      await ClickHouse.setUpdatesOrThrow(
        sink,
        ~cache=Dict.make(),
        ~changes=[
          Set({
            entityId: "surrogate-1"->EntityId.unsafeOfString,
            checkpointId: 1n,
            entity: {...entity, id: "surrogate-1", string: "ends" ++ highSurrogate}->(
              Utils.magic: Indexer.Entities.EntityWithAllTypes.t => Internal.entity
            ),
          }),
          Set({
            entityId: "surrogate-2"->EntityId.unsafeOfString,
            checkpointId: 2n,
            entity: {...entity, id: "surrogate-2", string: lowSurrogate ++ "starts"}->(
              Utils.magic: Indexer.Entities.EntityWithAllTypes.t => Internal.entity
            ),
          }),
        ],
        ~entityConfig,
        ~scope=CrossChain,
        ~chainIdMode=Int32,
      )

      let result = await client->ClickHouse.query({
        query: `SELECT id, string FROM ${database}.\`${tableName}\` ORDER BY envio_checkpoint_id`,
      })
      let rows = (await result->ClickHouse.json)["data"]
      await client->ClickHouse.exec({query: `DROP DATABASE ${database}`})
      await client->ClickHouse.close

      // Each lone surrogate becomes U+FFFD, which is what napi would have stored
      // for either value on its own.
      t.expect(rows).toEqual(
        %raw(`[
          { id: "surrogate-1", string: "ends�" },
          { id: "surrogate-2", string: "�starts" }
        ]`),
      )
    },
  )

  // An array's elements travel as JSON rather than in a typed array, so they
  // reach the encoder by a different route than a scalar of the same type — and
  // used to be coerced where a scalar would have been rejected.
  Async.it_skipIf(chHost->Option.isNone)(
    "Rejects array elements a scalar of the same type would be rejected for",
    async t => {
      let host = chHost->Option.getUnsafe
      let database = "test_codegen_roundtrip_elements"
      let entityConfig = MockIndexer.entityConfig("EntityWithAllTypes")

      let client = ClickHouse.createClient({url: host, username, password})
      await client->ClickHouse.exec({query: `DROP DATABASE IF EXISTS ${database}`})
      await client->ClickHouse.exec({query: `CREATE DATABASE ${database}`})
      await client->ClickHouse.exec({
        query: ClickHouse.makeCreateHistoryTableQuery(~entityConfig, ~database),
      })
      let sink = ClickHouseSink.make(~url=host, ~username, ~password, ~database, ~onWarning=ignore)

      let attempt = async rogue =>
        switch await ClickHouse.setUpdatesOrThrow(
          sink,
          ~cache=Dict.make(),
          ~changes=[
            Set({
              entityId: entity.id->EntityId.unsafeOfString,
              checkpointId: 1n,
              entity: rogue->(Utils.magic: Indexer.Entities.EntityWithAllTypes.t => Internal.entity),
            }),
          ],
          ~entityConfig,
          ~scope=CrossChain,
          ~chainIdMode=Int32,
        ) {
        | () => "stored without complaint"
        | exception Persistence.StorageError({reason}) =>
          reason->(Utils.magic: exn => {"message": string})->(r => r["message"])
        | exception _ => "not a StorageError"
        }

      // Truncated to 1 before; the scalar `int_` path has always refused this.
      let fractional = await attempt({
        ...entity,
        arrayOfInts: [1.5]->(Utils.magic: array<float> => array<int>),
      })
      // Stored as the four-character string "null" before.
      let nullElement = await attempt({
        ...entity,
        arrayOfStrings: [Null.null]->(Utils.magic: array<Null.t<string>> => array<string>),
      })

      await client->ClickHouse.exec({query: `DROP DATABASE ${database}`})
      await client->ClickHouse.close

      t.expect((
        fractional->String.includes("is not an integer"),
        nullElement->String.includes("null is not a value"),
      )).toEqual((true, true))
    },
  )

  // A UInt64 column's values reach Rust in a BigUint64Array, which reduces an
  // out-of-range bigint modulo 2^64 on the way in rather than refusing it —
  // the one wire kind whose values Rust never gets the chance to bounds-check.
  Async.it_skipIf(chHost->Option.isNone)(
    "Rejects a checkpoint id the UInt64 column cannot hold",
    async t => {
      let host = chHost->Option.getUnsafe
      let database = "test_codegen_roundtrip_uint64"

      let client = ClickHouse.createClient({url: host, username, password})
      await client->ClickHouse.exec({query: `DROP DATABASE IF EXISTS ${database}`})
      await client->ClickHouse.exec({query: `CREATE DATABASE ${database}`})
      await client->ClickHouse.exec({
        query: ClickHouse.makeCreateCheckpointsTableQuery(~database),
      })
      let sink = ClickHouseSink.make(~url=host, ~username, ~password, ~database, ~onWarning=ignore)

      let message = switch await ClickHouse.setCheckpointsOrThrow(
        sink,
        ~batch={
          totalBatchSize: 1,
          items: [],
          progressedChainsById: Dict.make(),
          isInReorgThreshold: false,
          // Wrapped to 18446744073709551615 before, landing a checkpoint far
          // past the head that the current-state view would then read up to.
          checkpointIds: [-1n],
          checkpointChainIds: [1->ChainId.fromInt],
          checkpointBlockNumbers: [1],
          checkpointBlockHashes: [Null.null],
          checkpointEventsProcessed: [1],
        },
        ~chainIdMode=Int32,
      ) {
      | () => "stored without complaint"
      | exception Persistence.StorageError({reason}) =>
        reason->(Utils.magic: exn => {"message": string})->(r => r["message"])
      | exception _ => "not a StorageError"
      }

      await client->ClickHouse.exec({query: `DROP DATABASE ${database}`})
      await client->ClickHouse.close

      t.expect(message->String.includes("out of range for a UInt64 column")).toEqual(true)
    },
  )

  // Naming every column in the INSERT is what lets a table carry columns envio
  // does not write. The server fills them, so a DEFAULT expression is evaluated
  // rather than replaced by the type's zero value, and a column whose type the
  // encoder has never heard of is simply not its business.
  Async.it_skipIf(chHost->Option.isNone)(
    "Leaves columns it does not write to the server",
    async t => {
      let host = chHost->Option.getUnsafe
      let database = "test_codegen_roundtrip_extra"
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
      // A column with a default expression, and one of a type the RowBinary
      // encoder cannot represent at all.
      await client->ClickHouse.exec({
        query: `ALTER TABLE ${database}.\`${tableName}\` ADD COLUMN ingested_by String DEFAULT 'envio'`,
      })
      await client->ClickHouse.exec({
        query: `ALTER TABLE ${database}.\`${tableName}\` ADD COLUMN trace UUID DEFAULT generateUUIDv4()`,
      })

      let sink = ClickHouseSink.make(~url=host, ~username, ~password, ~database, ~onWarning=ignore)
      await ClickHouse.setUpdatesOrThrow(
        sink,
        ~cache=Dict.make(),
        ~changes=[
          Set({
            entityId: entity.id->EntityId.unsafeOfString,
            checkpointId: 1n,
            entity: entity->(Utils.magic: Indexer.Entities.EntityWithAllTypes.t => Internal.entity),
          }),
        ],
        ~entityConfig,
        ~scope=CrossChain,
        ~chainIdMode=Int32,
      )

      let result = await client->ClickHouse.query({
        query: `SELECT id, ingested_by, trace != toUUID('00000000-0000-0000-0000-000000000000') AS has_trace FROM ${database}.\`${tableName}\``,
      })
      let rows = (await result->ClickHouse.json)["data"]
      await client->ClickHouse.exec({query: `DROP DATABASE ${database}`})
      await client->ClickHouse.close

      t.expect(rows).toEqual(
        %raw(`[{ id: "roundtrip-1", ingested_by: "envio", has_trace: 1 }]`),
      )
    },
  )
})
