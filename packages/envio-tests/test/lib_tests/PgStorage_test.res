open Vitest

// Every scalar the DDL knows how to render, an entity whose name is over
// Postgres' 63-character table-name limit, and a foreign key that carries an
// index — the shapes the generated SQL below is asserted against.
let config = TestConfig.make(
  ~schema=`
enum AccountType {
  ADMIN
  USER
}

enum GravatarSize {
  SMALL
  MEDIUM
  LARGE
}

type Gravatar {
  id: ID!
  size: GravatarSize!
}

type A {
  id: ID!
  b: B! @index
  optionalStringToTestLinkedEntities: String
}

type B {
  id: ID!
  a: [A!]! @derivedFrom(field: "b")
  c: C
}

type C {
  id: ID!
  a: A!
  stringThatIsMirroredToA: String!
}

type EntityWith63LenghtName______________________________________one {
  id: ID!
}

type EntityWith63LenghtName______________________________________two {
  id: ID!
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

type EntityWithAllNonArrayTypes {
  id: ID!
  string: String!
  optString: String
  int_: Int!
  optInt: Int
  float_: Float!
  optFloat: Float
  bool: Boolean!
  optBool: Boolean
  bigInt: BigInt!
  optBigInt: BigInt
  bigDecimal: BigDecimal!
  optBigDecimal: BigDecimal
  bigDecimalWithConfig: BigDecimal! @config(precision: 10, scale: 8)
  enumField: AccountType!
  optEnumField: AccountType
  timestamp: Timestamp!
  optTimestamp: Timestamp
}
`,
)

let ecosystem = config.ecosystem
let entityConfig = (name: string): Internal.entityConfig =>
  config->IndexerRunner.entityConfigByName(name)

describe("Test PgStorage SQL generation functions", () => {
  // https://github.com/enviodev/hyperindex/pull/1595#discussion_r3861606904
  describe("historyTableName", () => {
    Async.it(
      "Keeps two truncated names apart when their entity indexes differ in length",
      async t => {
        // Both names share the 47 characters that survive truncation, and the
        // first one's next character is the leading digit of the second one's
        // index. With nothing marking where the name stops and the index
        // starts, "…B" + "11" and "…B1" + "1" are the same identifier, and
        // `CREATE TABLE IF NOT EXISTS` would quietly give both entities one
        // history table.
        let shared = "B"->String.repeat(47)
        let name = EntityHistory.historyTableName
        let first = name(~entityName=shared ++ "1AA", ~entityIndex=1)
        let second = name(~entityName=shared ++ "2BB", ~entityIndex=11)
        t.expect((first === second, first->String.length, second->String.length)).toEqual((
          false,
          Table.maxPgTableNameLength,
          Table.maxPgTableNameLength,
        ))
      },
    )
  })

  describe("Deferred schema indexes", () => {
    let entities = [entityConfig("A"), entityConfig("B")]

    Async.it(
      "Describes every promised index once",
      async t => {
        t.expect(
          PgStorage.getSchemaIndexes(~entities)->Array.map(IndexDefinition.describe),
          ~message="The @index on A.b and B's derived relationship describe the same index",
        ).toEqual(["A(b_id) using btree"])
      },
    )

    // An isolated run builds a per-chain entity's index on its own chains'
    // partitions; a run driving every chain declares it once, on the parent.
    Async.it(
      "Places a per-chain entity's index on the parent, or on the isolated chains' partitions",
      async t => {
        let perChain: Internal.entityConfig = {
          ...entityConfig("A"),
          name: "PerChain",
          table: Table.mkTable(
            "PerChain",
            ~fields=[
              Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
              Table.mkField(
                Config.chainIdFieldName,
                ChainId,
                ~fieldSchema=ChainId.schema,
                ~isPrimaryKey=true,
                ~isChainId=true,
              ),
              Table.mkField("owner", String, ~isIndex=true, ~fieldSchema=S.string),
            ],
          ),
        }

        let tableNames = (~partitionChainIds=?) =>
          PgStorage.getSchemaIndexes(~entities=[perChain], ~partitionChainIds?)->Array.map(
            definition => definition.IndexDefinition.tableName,
          )

        t.expect((
          tableNames(),
          tableNames(~partitionChainIds=[ChainId.fromInt(1), ChainId.fromInt(137)]),
        )).toEqual((["PerChain"], ["PerChain$1", "PerChain$137"]))
      },
    )

    // Config parsing rejects a Postgres entity deriving from one that isn't in
    // Postgres, so every `@derivedFrom` target here is guaranteed to resolve.
    Async.it(
      "Emits the index backing a derived relationship on the referenced table",
      async t => {
        let makeEntity = (name, ~fields): Internal.entityConfig => {
          ...entityConfig("A"),
          name,
          table: Table.mkTable(name, ~fields),
          storage: {postgres: true, clickhouse: false},
        }
        let entities = [
          makeEntity(
            "Trader",
            ~fields=[
              Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
              Table.mkDerivedFromField(
                "orders",
                ~derivedFromEntity="Order",
                ~derivedFromField="trader",
              ),
            ],
          ),
          makeEntity(
            "Order",
            ~fields=[
              Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
              Table.mkField("trader", String, ~linkedEntity="Trader", ~fieldSchema=S.string),
            ],
          ),
        ]

        t.expect(
          PgStorage.getSchemaIndexes(~entities)->Array.map(
            definition => (
              definition.IndexDefinition.tableName,
              definition.columns->Array.map(column => column.IndexDefinition.name),
            ),
          ),
        ).toEqual([("Order", ["trader_id"])])
      },
    )
  })

  describe("makeFilterCondition", () => {
    let table = Table.mkTable(
      "users",
      ~fields=[
        Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
        Table.mkField("score", Int32, ~fieldSchema=S.int),
      ],
    )

    // A bytea column binds as bytes and a bytea[] one as the array literal
    // Postgres parses itself. An `in` over a list column nests one dimension
    // deeper, and Postgres arrays are rectangular, so its candidates all have
    // the same length.
    let bytesTable = Table.mkTable(
      "blobs",
      ~fields=[
        Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
        Table.mkField("tag", Bytea, ~fieldSchema=Utils.Schema.bytes),
        Table.mkField("chunks", Bytea, ~isArray=true, ~fieldSchema=Utils.Schema.bytesArray),
      ],
    )

    let parse = (filter, ~table: Table.table) =>
      filter->EntityFilter.parseOrThrow(~entityName=table.tableName, ~table)

    Async.it(
      "Renders bytea values as hex and bytea arrays as array literals",
      async t => {
        let params = []
        let condition = PgStorage.makeFilterCondition(
          ~filter=dict{
            "tag": dict{
              "_eq": Uint8Array.fromArray([0xaa])->(Utils.magic: Uint8Array.t => unknown),
              "_in": [Uint8Array.fromArray([1, 2]), Uint8Array.fromLength(0)]->(
                Utils.magic: array<Uint8Array.t> => unknown
              ),
            },
            "chunks": dict{
              "_eq": [Uint8Array.fromArray([3])]->(Utils.magic: array<Uint8Array.t> => unknown),
              "_in": [[Uint8Array.fromArray([4])], [Uint8Array.fromArray([5])]]->(
                Utils.magic: array<array<Uint8Array.t>> => unknown
              ),
            },
          }->parse(~table=bytesTable),
          ~table=bytesTable,
          ~pgSchema="test_schema",
          ~params,
        )

        t.expect((condition, params->Sql.params)).toEqual((
          `"tag" = $1 AND "tag" = ANY($2) AND "chunks" = $3 AND ("chunks" = $4 OR "chunks" = $5)`,
          [
            Null.make(`\\xaa`),
            Null.make(`{"\\\\x0102","\\\\x"}`),
            Null.make(`{"\\\\x03"}`),
            Null.make(`{"\\\\x04"}`),
            Null.make(`{"\\\\x05"}`),
          ],
        ))
      },
    )

    Async.it(
      "Should create condition and params for loading multiple records by IDs",
      async t => {
        let params = []
        let condition = PgStorage.makeFilterCondition(
          ~filter=dict{
            "id": dict{"_in": ["1", "2"]->(Utils.magic: array<string> => unknown)},
          }->parse(~table),
          ~table,
          ~pgSchema="test_schema",
          ~params,
        )

        t.expect((condition, params)).toEqual((
          `"id" = ANY($1)`,
          [["1", "2"]->(Utils.magic: array<string> => unknown)],
        ))
      },
    )

    Async.it(
      "Should create condition and params for a scalar comparison",
      async t => {
        let params = []
        let condition = PgStorage.makeFilterCondition(
          ~filter=dict{"score": dict{"_gt": 5->(Utils.magic: int => unknown)}}->parse(~table),
          ~table,
          ~pgSchema="test_schema",
          ~params,
        )

        t.expect((condition, params)).toEqual((`"score" > $1`, [5->(Utils.magic: int => unknown)]))
      },
    )

    // These reach the query as themselves. Composing them from an equality and
    // a strict comparison, as the filter IR used to, needed a separate query
    // per operator and a cross product once a second field was filtered on.
    Async.it(
      "Should emit _gte and _lte as a single inclusive comparison",
      async t => {
        let params = []
        let condition = PgStorage.makeFilterCondition(
          ~filter=dict{
            "score": dict{"_gte": 5->(Utils.magic: int => unknown)},
            "id": dict{"_lte": "9"->(Utils.magic: string => unknown)},
          }->parse(~table),
          ~table,
          ~pgSchema="test_schema",
          ~params,
        )

        t.expect((condition, params)).toEqual((
          `"score" >= $1 AND "id" <= $2`,
          [5->(Utils.magic: int => unknown), "9"->(Utils.magic: string => unknown)],
        ))
      },
    )

    Async.it(
      "Should number params across every field and operator",
      async t => {
        let params = []
        let condition = PgStorage.makeFilterCondition(
          ~filter=dict{
            "id": dict{"_eq": "1"->(Utils.magic: string => unknown)},
            "score": dict{
              "_gt": 5->(Utils.magic: int => unknown),
              "_lt": 10->(Utils.magic: int => unknown),
            },
          }->parse(~table),
          ~table,
          ~pgSchema="test_schema",
          ~params,
        )

        t.expect((condition, params)).toEqual((
          `"id" = $1 AND "score" > $2 AND "score" < $3`,
          [
            "1"->(Utils.magic: string => unknown),
            5->(Utils.magic: int => unknown),
            10->(Utils.magic: int => unknown),
          ],
        ))
      },
    )

    // Candidates for a list column go out one equality each: Postgres arrays
    // are rectangular, so a single bound array can't hold candidates of
    // different lengths. An empty list matches nothing, and a boolean column
    // binds its candidates as one array like any other scalar.
    Async.it(
      "Expands an _in over a list column into one equality per candidate",
      async t => {
        let listTable = Table.mkTable(
          "lists",
          ~fields=[
            Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
            Table.mkField("tags", String, ~isArray=true, ~fieldSchema=S.array(S.string)),
            Table.mkField("flag", Boolean, ~fieldSchema=S.bool),
          ],
        )
        let condition = (filter: dict<dict<unknown>>) => {
          let params = []
          let condition = PgStorage.makeFilterCondition(
            ~filter=filter->parse(~table=listTable),
            ~table=listTable,
            ~pgSchema="test_schema",
            ~params,
          )
          (condition, params)
        }
        let tagsIn = candidates =>
          dict{"tags": dict{"_in": candidates->(Utils.magic: array<array<string>> => unknown)}}

        t.expect((
          condition(tagsIn([["a"], ["a", "b"]])),
          condition(tagsIn([])),
          condition(
            dict{"flag": dict{"_in": [true, false]->(Utils.magic: array<bool> => unknown)}},
          ),
        )).toEqual((
          (
            `("tags" = $1 OR "tags" = $2)`,
            [
              ["a"]->(Utils.magic: array<string> => unknown),
              ["a", "b"]->(Utils.magic: array<string> => unknown),
            ],
          ),
          ("FALSE", []),
          (`"flag" = ANY($1)`, [[true, false]->(Utils.magic: array<bool> => unknown)]),
        ))
      },
    )

    // A bound array of strings is text[], and Postgres has no equality between
    // text and an enum, so the parameter is cast the way the insert casts it.
    Async.it(
      "Casts an _in over an enum column to the enum's array type",
      async t => {
        let kind = Table.makeEnumConfig(~name="Kind", ~variants=["ZETA", "ALPHA"])
        let enumTable = Table.mkTable(
          "kinds",
          ~fields=[
            Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
            Table.mkField(
              "kind",
              Enum({config: kind->Table.fromGenericEnumConfig}),
              ~fieldSchema=kind.schema,
            ),
          ],
        )
        let params = []
        let condition = PgStorage.makeFilterCondition(
          ~filter=dict{
            "kind": dict{"_in": ["ALPHA"]->(Utils.magic: array<string> => unknown)},
          }->parse(~table=enumTable),
          ~table=enumTable,
          ~pgSchema="test_schema",
          ~params,
        )

        t.expect((condition, params)).toEqual((
          `"kind" = ANY($1::TEXT[]::"test_schema".Kind[])`,
          [["ALPHA"]->(Utils.magic: array<string> => unknown)],
        ))
      },
    )
  })
})

// Runs the validation path in makeStorageFromEnv taken only when
// `storage.clickhouse: true` in config.yaml. The vars are cleared around the
// call rather than assumed absent: the scenario's own ClickHouse tests need them
// set, so an ambient value would leave nothing missing to report.
let withoutClickHouseEnv = fn => {
  let names = [
    "ENVIO_CLICKHOUSE_HOST",
    "ENVIO_CLICKHOUSE_USERNAME",
    "ENVIO_CLICKHOUSE_PASSWORD",
    "ENVIO_CLICKHOUSE_DATABASE",
  ]
  let env = NodeJs.Process.process.env
  let saved = names->Array.map(name => (name, env->Utils.Dict.dangerouslyGetNonOption(name)))
  names->Array.forEach(name => env->Dict.delete(name))
  let result = try Ok(fn()) catch {
  | exn => Error(exn)
  }
  saved->Array.forEach(((name, value)) =>
    switch value {
    | Some(value) => env->Dict.set(name, value)
    | None => ()
    }
  )
  switch result {
  | Ok(value) => value
  | Error(exn) => throw(exn)
  }
}

describe("PgStorage.makeStorageFromEnv ClickHouse env var validation", () => {
  Async.it(
    "Throws listing all missing ENVIO_CLICKHOUSE_* env vars when storage.clickhouse=true",
    async t => {
      let config = {
        ...config,
        storage: (
          {
            postgres: true,
            clickhouse: true,
            postgresColumnNameFormat: Original,
            clickhouseColumnNameFormat: Original,
          }: Config.storage
        ),
      }
      let message = withoutClickHouseEnv(
        () =>
          switch try {
            let _ = PgStorage.makeStorageFromEnv(~config)
            None
          } catch {
          | JsExn(e) => Some(e->JsExn.message->Option.getOr(""))
          | _ => None
          } {
          | Some(m) => m
          | None => ""
          },
      )
      t.expect(
        message,
        ~message="Should throw a helpful error naming every missing env var at once",
      ).toBe(
        "ClickHouse storage is enabled but required env vars are not set: ENVIO_CLICKHOUSE_HOST, ENVIO_CLICKHOUSE_USERNAME, ENVIO_CLICKHOUSE_PASSWORD, ENVIO_CLICKHOUSE_DATABASE. Please set them, disable clickhouse in the `storage` config, or run `envio dev` for a pre-configured local ClickHouse.",
      )
    },
  )

  Async.it("Does not throw when storage.clickhouse=false (default)", async t => {
    let config = {
      ...config,
      storage: (
        {
          postgres: true,
          clickhouse: false,
          postgresColumnNameFormat: Original,
          clickhouseColumnNameFormat: Original,
        }: Config.storage
      ),
    }
    // Just ensure construction succeeds without touching ClickHouse env vars.
    let _ = PgStorage.makeStorageFromEnv(~config)
    t.expect(true, ~message="Expected no throw when clickhouse is disabled").toBe(true)
  })

  // `envio dev` applies ENVIO_CLICKHOUSE_* vars via Bin.applyEnv, which runs
  // AFTER Env.res has been imported. If Env.ClickHouse cached reads at module
  // load, those late writes would be invisible and validation would still
  // throw. This test simulates that timing by writing the vars to process.env
  // right before calling makeStorageFromEnv.
  Async.it("Picks up ENVIO_CLICKHOUSE_* vars set after Env.res has been loaded", async t => {
    let getEnvVar: string => option<string> = %raw(`(k) => process.env[k]`)
    let setEnvVar: (string, string) => unit = %raw(`(k, v) => { process.env[k] = v; }`)
    let unsetEnvVar: string => unit = %raw(`(k) => { delete process.env[k]; }`)
    // The ClickHouse leg points the process at its own database through these
    // same vars, so deleting them unconditionally would strip the run's wiring
    // from every test after this one in the file.
    let restored = [
      ("ENVIO_CLICKHOUSE_HOST", "http://localhost:8123"),
      ("ENVIO_CLICKHOUSE_USERNAME", "default"),
      ("ENVIO_CLICKHOUSE_PASSWORD", "testing"),
      ("ENVIO_CLICKHOUSE_DATABASE", "envio_indexer"),
    ]->Array.map(
      ((key, value)) => {
        let before = getEnvVar(key)
        setEnvVar(key, value)
        (key, before)
      },
    )
    let config = {
      ...config,
      storage: (
        {
          postgres: true,
          clickhouse: true,
          postgresColumnNameFormat: Original,
          clickhouseColumnNameFormat: Original,
        }: Config.storage
      ),
    }
    let result = try {
      let _ = PgStorage.makeStorageFromEnv(~config)
      Ok()
    } catch {
    | JsExn(e) => Error(e->JsExn.message->Option.getOr(""))
    | _ => Error("non-JsExn")
    }
    restored->Array.forEach(
      ((key, before)) =>
        switch before {
        | Some(value) => setEnvVar(key, value)
        | None => unsetEnvVar(key)
        },
    )
    t.expect(
      result,
      ~message="Should read ClickHouse env vars lazily so envio dev's late injection works",
    ).toEqual(Ok())
  })
})

describe("ecosystem.toRawEvent", () => {
  Async.it(
    "Derives a raw event row from a batch item, taking block hash and timestamp from the payload block and stringifying bigint block fields",
    async t => {
      let srcAddress =
        "0x00000000000000000000000000000000000000ab"->(Utils.magic: string => Address.t)
      let blockNumber = 5
      let logIndex = 3

      let event = {
        "block": %raw(`{"number": 5, "timestamp": 9999, "hash": "0xblockhash", "gasUsed": 99n, "miner": "0xminer"}`),
        "transaction": %raw(`{"hash": "0xtxhash", "transactionIndex": 2}`),
        "params": (),
        "logIndex": logIndex,
        "srcAddress": srcAddress,
        "chainId": 137,
        "contractName": "ERC20",
        "eventName": "EventWithoutFields",
      }->(
        Utils.magic: {
          "block": JSON.t,
          "transaction": JSON.t,
          "params": unit,
          "logIndex": int,
          "srcAddress": Address.t,
          "chainId": int,
          "contractName": string,
          "eventName": string,
        } => Internal.eventPayload
      )

      let eventItem = Internal.Event({
        onEventRegistration: (EventRegistration.evmOnEventRegistration(
          ~contractName="ERC20",
        ) :> Internal.onEventRegistration),
        chainId: 137->ChainId.fromInt,
        blockNumber,
        logIndex,
        transactionIndex: 0,
        payload: event,
      })->Internal.castUnsafeEventItem

      t.expect(ecosystem.toRawEvent(eventItem)).toEqual({
        chain_id: 137->ChainId.fromInt,
        event_id: EventUtils.packEventIndex(~logIndex, ~blockNumber),
        event_name: "EventWithoutFields",
        contract_name: "ERC20",
        block_number: blockNumber,
        log_index: logIndex,
        src_address: srcAddress,
        block_hash: "0xblockhash",
        block_timestamp: 9999,
        block_fields: %raw(`{"gasUsed": "99", "miner": "0xminer"}`),
        transaction_fields: %raw(`{"hash": "0xtxhash", "transactionIndex": 2}`),
        params: %raw(`"null"`),
      })
    },
  )
})
