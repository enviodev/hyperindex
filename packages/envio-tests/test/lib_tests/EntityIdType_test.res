open Vitest

// A numeric-id entity referenced by a foreign key. The referenced entity's id
// type (BigInt here) must flow to the foreign key column, and every id-typed
// SQL statement must cast to the id column's Postgres type rather than text.
let bigParentTable = Table.mkTable(
  "BigParent",
  ~fields=[Table.mkField("id", BigInt({}), ~isPrimaryKey=true, ~fieldSchema=Utils.BigInt.schema)],
)

let numericIdTable = Table.mkTable(
  "NumericId",
  ~fields=[
    Table.mkField("id", Int32, ~isPrimaryKey=true, ~fieldSchema=S.int),
    Table.mkField("value", String, ~fieldSchema=S.string),
    // Foreign key to BigParent: adopts BigParent's BigInt id type, stored as
    // the `parent_id` column.
    Table.mkField(
      "parent",
      BigInt({}),
      ~linkedEntity="BigParent",
      ~fieldSchema=Utils.BigInt.schema,
    ),
  ],
)

describe("Non-string entity id support", () => {
  it("resolves the id column Postgres type per entity", t => {
    t.expect((
      numericIdTable->Table.getIdPgFieldType(~pgSchema="public"),
      bigParentTable->Table.getIdPgFieldType(~pgSchema="public"),
    )).toEqual(("INTEGER", "NUMERIC"))
  })

  it("creates id and foreign-key columns with matching numeric types", t => {
    t.expect(
      PgStorage.makeCreateTableQuery(
        numericIdTable,
        ~pgSchema="public",
        ~isNumericArrayAsText=false,
      ),
    ).toBe(`CREATE TABLE IF NOT EXISTS "public"."NumericId"("id" INTEGER NOT NULL, "value" TEXT NOT NULL, "parent_id" NUMERIC NOT NULL, PRIMARY KEY("id"));`)
  })

  it("casts delete-by-ids to the id column type instead of text", t => {
    t.expect(
      PgStorage.makeDeleteByIdsQuery(
        ~pgSchema="public",
        ~tableName="NumericId",
        ~idPgType=numericIdTable->Table.getIdPgFieldType(~pgSchema="public"),
        ~chainIdCondition="",
      ),
    ).toBe(`DELETE FROM "public"."NumericId" WHERE id = ANY($1::INTEGER[]);`)
  })

  it("casts history backfill unnest to the id column type", t => {
    t.expect(
      EntityHistory.makeBackfillHistoryQuery(
        ~pgSchema="public",
        ~entityName="BigParent",
        ~entityIndex=0,
        ~idPgType=bigParentTable->Table.getIdPgFieldType(~pgSchema="public"),
        ~chainIdColumn=None,
        ~chainId=None,
      )->String.includes("UNNEST($1::NUMERIC[])"),
    ).toBe(true)
  })

  it("maps numeric ids to ClickHouse column types", t => {
    t.expect((
      ClickHouse.getClickHouseFieldType(~fieldType=Int32, ~isNullable=false, ~isArray=false),
      ClickHouse.getClickHouseFieldType(
        ~fieldType=BigInt({precision: 20}),
        ~isNullable=false,
        ~isArray=false,
      ),
    )).toEqual(("Int32", "Decimal(20,0)"))
  })

  it("degrades an unbounded BigInt id to a ClickHouse String column", t => {
    // A BigInt without precision has no Decimal width, so ClickHouse falls back
    // to String. This is expected (lexicographic ORDER BY) — pin it so the
    // fallback isn't silently changed.
    t.expect(
      ClickHouse.getClickHouseFieldType(~fieldType=BigInt({}), ~isNullable=false, ~isArray=false),
    ).toBe("String")
  })

  it("serializes a history set update keeping the numeric id value", t => {
    let entitySchema = S.object(
      s =>
        {
          "id": s.field("id", S.int),
          "value": s.field("value", S.string),
        },
    )->(Utils.magic: S.t<{"id": int, "value": string}> => S.t<Internal.entity>)

    let setUpdateSchema = EntityHistory.makeSetUpdateSchema(
      ~idSchema=numericIdTable->Table.getIdSchema,
      entitySchema,
    )

    let json = Change.Set({
      entityId: 123->EntityId.unsafeOfAny,
      entity: {"id": 123, "value": "x"}->(
        Utils.magic: {"id": int, "value": string} => Internal.entity
      ),
      checkpointId: 5n,
    })->S.reverseConvertToJsonOrThrow(setUpdateSchema)

    t.expect(json).toEqual(
      %raw(`{"id": 123, "value": "x", "envio_checkpoint_id": "5", "envio_change": "SET"}`),
    )
  })
})

// End-to-end coverage through the in-process test indexer + Postgres: a schema
// with Int!/BigInt! ids and foreign keys referencing them, driven by a real
// handler, must round-trip the numeric values and delete by numeric id.
type chainEntity = {id: int}
type vaultEntity = {id: string, @as("chain_id") chainId: int, @as("big_id") bigId: bigint}

type chainOps = {set: chainEntity => unit, deleteUnsafe: int => unit}
type bigThingOps = {set: {"id": bigint} => unit}
type vaultOps = {set: vaultEntity => unit}
type handlerContext = {
  @as("Chain") chain: chainOps,
  @as("BigThing") bigThing: bigThingOps,
  @as("Vault") vault: vaultOps,
}

let scenario = Scenario.make(
  ~schema=`
type Chain {
  id: Int!
  vaults: [Vault!]! @derivedFrom(field: "chain")
}
type BigThing {
  id: BigInt!
}
type Vault {
  id: ID!
  chain: Chain!
  big: BigThing!
}
`,
  ~configYaml=`
name: numeric-ids
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer()
`,
  ~unsupported=[
    {
      backend: #clickhouse,
      reason: "BigThing's unbounded BigInt id has no ClickHouse precision",
    },
  ],
)

describe("Non-string entity id — end-to-end via the in-process indexer", () => {
  scenario->Scenario.it(
    "round-trips Int/BigInt ids and foreign keys and deletes by numeric id",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)

      source.resolveGetHeightOrThrow(300)

      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 5,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
              context.chain.set({id: 137})
              // Deleted below by its numeric id, exercising delete-by-id with an
              // integer column instead of text.
              context.chain.set({id: 10})
              context.bigThing.set({"id": 999n})
              context.vault.set({id: "v1", chainId: 137, bigId: 999n})
              context.chain.deleteUnsafe(10)
            },
          },
        ],
        ~latestFetchedBlockNumber=300,
      )
      await indexer.getBatchWritePromise()

      let chains: array<chainEntity> = await indexer.query("Chain")
      let vaults: array<vaultEntity> = await indexer.query("Vault")

      t.expect((chains, vaults)).toEqual(([{id: 137}], [{id: "v1", chainId: 137, bigId: 999n}]))
    },
  )
})

// A ClickHouse entity keyed by a BigInt id must set a numeric precision:
// ClickHouse stores an unbounded (or over-precision) BigInt as a String, and an
// id is the mandatory sort key, so it would order lexicographically.
describe("ClickHouse BigInt id precision validation", () => {
  let parseWithStorage = (~schema, ~storage) =>
    InternalTestIndexer.fromUserApi(
      ~schema,
      ~configYaml=`
name: ch-bigint-id
storage:
${storage}
chains:
  - id: 1
    rpc:
      url: https://eth.com
      for: sync
    start_block: 0
`,
    )

  let bothBackends = "  postgres:\n    default: true\n  clickhouse: true"

  // The full error a rejected parse throws. `toThrowErrorEqual` asserts the
  // whole message (not a substring). The entity is named "Thing" in every case.
  let expectedError = "Invalid storage for `Thing`. Its `id` is a BigInt, which ClickHouse stores as a String (sorted lexicographically, not numerically) unless a precision is set. Since `id` is ClickHouse's sorting key, add `@config(precision: N)` with N <= 38 so the id stores as a numeric Decimal, or set `@storage(clickhouse: {orderBy: [...]})` to sort by other fields."

  it("rejects an unbounded BigInt id on a clickhouse entity", t => {
    t->toThrowErrorEqual(
      () =>
        parseWithStorage(
          ~schema=`type Thing @storage(clickhouse: true) { id: BigInt! }`,
          ~storage=bothBackends,
        )->ignore,
      expectedError,
    )
  })

  it("rejects a BigInt id whose precision exceeds the ClickHouse Decimal ceiling", t => {
    t->toThrowErrorEqual(
      () =>
        parseWithStorage(
          ~schema=`type Thing @storage(clickhouse: true) { id: BigInt! @config(precision: 100) }`,
          ~storage=bothBackends,
        )->ignore,
      expectedError,
    )
  })

  it("rejects an unbounded BigInt id when clickhouse is the default backend", t => {
    t->toThrowErrorEqual(
      () =>
        parseWithStorage(
          ~schema=`type Thing { id: BigInt! }`,
          ~storage="  postgres:\n    default: true\n  clickhouse:\n    default: true",
        )->ignore,
      expectedError,
    )
  })

  it("accepts a BigInt id with a numeric precision on a clickhouse entity", t => {
    let {config} = parseWithStorage(
      ~schema=`type Thing @storage(clickhouse: true) { id: BigInt! @config(precision: 20) }`,
      ~storage=bothBackends,
    )
    t.expect(config.userEntitiesByName->Dict.get("Thing")->Option.isSome).toBe(true)
  })

  it("accepts an Int id on a clickhouse entity", t => {
    let {config} = parseWithStorage(
      ~schema=`type Thing @storage(clickhouse: true) { id: Int! }`,
      ~storage=bothBackends,
    )
    t.expect(config.userEntitiesByName->Dict.get("Thing")->Option.isSome).toBe(true)
  })

  it("accepts an unbounded BigInt id on a postgres-only entity", t => {
    let {config} = parseWithStorage(
      ~schema=`type Thing { id: BigInt! }`,
      ~storage="  postgres:\n    default: true",
    )
    t.expect(config.userEntitiesByName->Dict.get("Thing")->Option.isSome).toBe(true)
  })
})

// The public `EntityChangeValue.deleted` type in index.d.ts is derived from the
// entity id (`EntityId<Entity>`), so the ids the test indexer actually reports
// must be the raw scalars rather than stringified ones.
// Parsed, never run — these cases only need the entity configs. Parsed through
// `fromUserApi` rather than `Scenario.make` so the ClickHouse leg doesn't shape
// the config for a schema whose BigInt id has no precision.
let idTypesConfig = {
  let {config} = InternalTestIndexer.fromUserApi(
    ~schema=`
type IntIdEntity {
  id: Int!
  value: String!
}
type BigIntIdEntity {
  id: BigInt!
}
type User {
  id: ID!
}
`,
    ~configYaml=`
name: id-types
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer()
`,
  )
  config
}

let idTypesEntityConfig = name => idTypesConfig->IndexerRunner.entityConfigByName(name)

describe("Test indexer reports deleted ids with the entity's id type", () => {
  let makeState = (~entityConfig: Internal.entityConfig): TestIndexer.testIndexerState => {
    let entityConfigs = Dict.make()
    entityConfigs->Dict.set(entityConfig.name, entityConfig)
    {
      processInProgress: false,
      progressBlockByChain: Dict.make(),
      entities: Dict.make(),
      entityConfigs,
      addresses: AddressRows.Table.make(),
      contractMapping: ContractMapping.empty,
      processChanges: [],
    }
  }

  let deletedIdsOf = (~entityConfig: Internal.entityConfig, ~entityId: EntityId.t) => {
    let state = makeState(~entityConfig)
    state->TestIndexer.handleWriteBatch(
      ~config=idTypesConfig,
      ~registeredAddresses=[],
      ~updatedEntities=[
        {
          entityConfig,
          scope: Internal.CrossChain,
          changes: [Change.Delete({entityId, checkpointId: 1n})],
        },
      ],
      ~checkpointIds=[1n],
      ~checkpointChainIds=[1337->ChainId.fromInt],
      ~checkpointBlockNumbers=[5],
      ~checkpointEventsProcessed=[1],
    )
    state.processChanges
    ->Array.getUnsafe(0)
    ->(Utils.magic: unknown => dict<dict<array<EntityId.t>>>)
    ->Dict.getUnsafe(entityConfig.name)
    ->Dict.getUnsafe("deleted")
  }

  it("keeps an Int id a number", t => {
    let deleted = deletedIdsOf(
      ~entityConfig=idTypesEntityConfig("IntIdEntity"),
      ~entityId=137->EntityId.unsafeOfAny,
    )
    // Compared against the raw number, so a stringified "137" fails here.
    t.expect(deleted).toEqual([137->EntityId.unsafeOfAny])
  })

  it("keeps a BigInt id a bigint", t => {
    let deleted = deletedIdsOf(
      ~entityConfig=idTypesEntityConfig("BigIntIdEntity"),
      ~entityId=999n->EntityId.unsafeOfAny,
    )
    t.expect(deleted).toEqual([999n->EntityId.unsafeOfAny])
  })

  it("keeps a string id a string", t => {
    let deleted = deletedIdsOf(
      ~entityConfig=idTypesEntityConfig("User"),
      ~entityId="u1"->EntityId.unsafeOfString,
    )
    t.expect(deleted).toEqual(["u1"->EntityId.unsafeOfString])
  })
})

// A custom `orderBy` replaces `id` in the ClickHouse sorting key, so the fields
// it lists are what must sort numerically — and a relation sorts by the id it
// stores, not by the entity it points at.
describe("ClickHouse orderBy sort-key validation", () => {
  let parseWithClickHouse = schema =>
    InternalTestIndexer.fromUserApi(
      ~schema,
      ~configYaml=`
name: clickhouse-order-by
storage:
  postgres:
    default: true
  clickhouse: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
`,
    )

  it("accepts an unbounded BigInt id when orderBy replaces id in the sort key", t => {
    let {config} = parseWithClickHouse(`
type Thing @storage(clickhouse: {orderBy: ["timestamp"]}) {
  id: BigInt!
  timestamp: Int!
}
`)
    t.expect(config.userEntitiesByName->Dict.get("Thing")->Option.isSome).toBe(true)
  })

  it("rejects sorting by a relation whose target id is an unbounded BigInt", t => {
    t->toThrowErrorEqual(
      () =>
        parseWithClickHouse(`
type Parent {
  id: BigInt!
}
type Thing @storage(clickhouse: {orderBy: ["parent"]}) {
  id: ID!
  parent: Parent!
}
`)->ignore,
      "Invalid storage for `Thing`. `clickhouse.orderBy` sorts by `parent`, which stores a BigInt that ClickHouse keeps as a String (sorted lexicographically, not numerically) unless a precision is set. Add `@config(precision: N)` with N <= 38 to the BigInt it stores so it sorts as a numeric Decimal.",
    )
  })

  it("accepts sorting by a relation whose target id is a bounded BigInt", t => {
    let {config} = parseWithClickHouse(`
type Parent {
  id: BigInt! @config(precision: 20)
}
type Thing @storage(clickhouse: {orderBy: ["parent"]}) {
  id: ID!
  parent: Parent!
}
`)
    t.expect(config.userEntitiesByName->Dict.get("Thing")->Option.isSome).toBe(true)
  })

  it("accepts sorting by a relation whose target id is an Int", t => {
    let {config} = parseWithClickHouse(`
type Parent {
  id: Int!
}
type Thing @storage(clickhouse: {orderBy: ["parent"]}) {
  id: ID!
  parent: Parent!
}
`)
    t.expect(config.userEntitiesByName->Dict.get("Thing")->Option.isSome).toBe(true)
  })
})
