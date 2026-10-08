open Vitest

// Two indexers driving different chains of one schema, as `envio start --chain`
// runs them: a process each, and so a connection pool each, contending on the
// same tables at the same time.
//
// One process does the migration; the two that follow only resume. What they
// then do concurrently is everything a started indexer does to the database
// before it has read a block — resume, write, stamp their chain's metadata, and
// build the indexes the schema promises.

let config = TestConfig.fromUserApi(
  ~schema=`
type Item {
  id: ID!
  owner: String! @index
}
`,
  `
name: sibling-processes
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
  - id: 137
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
)
let entityConfig = config->IndexerRunner.entityConfigByName("Item")
let entities = [entityConfig]
let enums = config.allEnums
let pgSchema = TestPgSchema.make()

let migrateClient = PgStorage.makeClient(~pgSchema)
let firstClient = PgStorage.makeClient(~pgSchema)
let secondClient = PgStorage.makeClient(~pgSchema)

let storageOn = sql => PgStorage.make(~pgSchema, ~sql, ~ecosystem=Evm)

let rowsPerSibling = 200

// What one of the two processes does on the way up.
let sibling = async (~sql, ~chainId) => {
  let storage = storageOn(sql)
  let resumed = await storage.resumeInitialState(
    ~entities,
    ~chainIds=[chainId],
    ~contractMapping=config.contractMapping,
  )

  let _ = await TestPgSchema.write(
    ~pgSchema,
    ~items=Array.fromInitializer(~length=rowsPerSibling, index =>
      {
        "id": `${chainId->ChainId.toString}-${index->Int.toString}`,
        "owner": `owner-${mod(index, 5)->Int.toString}`,
      }
    )->(Utils.magic: array<'a> => array<unknown>),
    ~table=entityConfig.table,
    ~itemSchema=entityConfig->PgStorage.getRowSchema->S.toUnknown,
  )

  let _ = await storage.setChainMeta(
    Dict.fromArray([
      (
        chainId->ChainId.toString,
        (
          {
            firstEventBlockNumber: Null.make(chainId->ChainId.toInt),
            latestFetchedBlockNumber: chainId->ChainId.toInt,
            timestampCaughtUpToHeadOrEndblock: Null.null,
            isHyperSync: false,
          }: InternalTable.Chains.metaFields
        ),
      ),
    ]),
  )

  // Both siblings promise the same indexes and neither knows the other is
  // building them, so one of the two loses every create. Finishing a backfill
  // is where that matters: the process stamps its chains ready only once every
  // index verifies, and being beaten to one is not a reason to stop.
  await storage.finalizeBackfill(~entities, ~chainIds=[chainId], ~readyAt=Date.make())
  // What a resumed process runs instead, which by now has nothing left to do.
  await storage.ensureSchemaIndexes(~entities, ~chainIds=[chainId])

  resumed.chains->Array.map(chain => chain.id)
}

Async.afterAll(async () => {
  await TestPgSchema.drop(migrateClient, ~pgSchema)
  let _ = await [migrateClient, firstClient, secondClient]
  ->Array.map(sql => sql->Sql.close)
  ->Promise.all
})

describe("Two processes indexing one schema", () => {
  Async.it("each resume, write and build indexes without standing on the other", async t => {
    let _ = await storageOn(migrateClient).initialize(
      ~chainConfigs=config.chainMap->ChainMap.values,
      ~contractMapping=config.contractMapping,
      ~entities,
      ~enums,
      ~envioInfo=JSON.parseOrThrow(`{"name": "sibling-processes"}`),
    )

    let (firstResumed, secondResumed) = await Promise.all2((
      sibling(~sql=firstClient, ~chainId=1->ChainId.fromInt),
      sibling(~sql=secondClient, ~chainId=137->ChainId.fromInt),
    ))

    let written =
      (
        await migrateClient->Sql.query(
          PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=entityConfig.table.tableName),
        )
      )->Array.length
    let meta: array<{
      "id": int,
      "first_event_block": Null.t<int>,
    }> = await migrateClient->Sql.query(
      `SELECT "id", "first_event_block" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
    )
    let meta =
      meta->Array.map(
        chain => (chain["id"]->Int.toString, chain["first_event_block"]->Null.toOption),
      )
    let readyChains: array<{
      "count": string,
    }> = await migrateClient->Sql.query(
      `SELECT count(*)::text AS "count" FROM "${pgSchema}"."envio_chains" WHERE "ready_at" IS NOT NULL;`,
    )
    let indexes: array<{
      "indexname": string,
    }> = await migrateClient->Sql.query(
      `SELECT indexname FROM pg_indexes WHERE schemaname = '${pgSchema}' AND tablename = '${entityConfig.table.tableName}' ORDER BY indexname;`,
    )

    t.expect((
      firstResumed->Array.map(ChainId.toString),
      secondResumed->Array.map(ChainId.toString),
      written,
      meta,
      indexes->Array.map(row => row["indexname"]),
      readyChains->Array.map(row => row["count"]),
    )).toEqual((
      ["1"],
      ["137"],
      rowsPerSibling * 2,
      // Each sibling stamped its own chain and left the other's alone.
      [("1", Some(1)), ("137", Some(137))],
      ["Item_owner_g537j79h9n", "Item_pkey"],
      // Both processes finished their own backfill.
      ["2"],
    ))
  })
})
