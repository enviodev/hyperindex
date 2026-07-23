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
    Table.mkField("parent", BigInt({}), ~linkedEntity="BigParent", ~fieldSchema=Utils.BigInt.schema),
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
    ).toBe(
      `CREATE TABLE IF NOT EXISTS "public"."NumericId"("id" INTEGER NOT NULL, "value" TEXT NOT NULL, "parent_id" NUMERIC NOT NULL, PRIMARY KEY("id"));`,
    )
  })

  it("casts delete-by-ids to the id column type instead of text", t => {
    t.expect(
      PgStorage.makeDeleteByIdsQuery(
        ~pgSchema="public",
        ~tableName="NumericId",
        ~idPgType=numericIdTable->Table.getIdPgFieldType(~pgSchema="public"),
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

  it("serializes a history set update keeping the numeric id value", t => {
    let entitySchema =
      S.object(s =>
        {
          "id": s.field("id", S.int),
          "value": s.field("value", S.string),
        }
      )->(Utils.magic: S.t<{"id": int, "value": string}> => S.t<Internal.entity>)

    let setUpdateSchema = EntityHistory.makeSetUpdateSchema(
      ~idSchema=numericIdTable->Table.getIdSchema,
      entitySchema,
    )

    let json =
      Change.Set({
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

describe("Non-string entity id — end-to-end via the in-process indexer", () => {
  Async.it("round-trips Int/BigInt ids and foreign keys and deletes by numeric id", async t => {
    let {config} = InternalTestIndexer.fromUserApi(
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

    let source = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~chain=#1337)
    let indexerMock = await MockIndexer.Indexer.make(
      ~config,
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([source.source])}],
      ~shouldRollbackOnReorg=false,
    )
    await Utils.delay(0)

    source.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    source.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 5,
          logIndex: 0,
          handler: async args => {
            let context =
              args.context->(Utils.magic: MockIndexer.handlerContext => handlerContext)
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
    await indexerMock.getBatchWritePromise()

    let chains: array<chainEntity> = await indexerMock.queryRaw(
      config.userEntitiesByName->Dict.getUnsafe("Chain"),
    )
    let vaults: array<vaultEntity> = await indexerMock.queryRaw(
      config.userEntitiesByName->Dict.getUnsafe("Vault"),
    )

    t.expect((chains, vaults)).toEqual((
      [{id: 137}],
      [{id: "v1", chainId: 137, bigId: 999n}],
    ))
  })
})
