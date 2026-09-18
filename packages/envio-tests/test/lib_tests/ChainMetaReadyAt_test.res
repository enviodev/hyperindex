open Vitest

// `ready_at` is committed by the finalization and carried by every chain
// metadata write after it. The two race: metadata is written on a throttle of
// its own, outside the batch the finalization flushes, so a snapshot taken
// before the stamp can reach the database after it.
let sql = PgStorage.makeClient()
let pgSchema = TestPgSchema.make()
let config = TestConfig.make()

Async.afterAll(async () => {
  await sql->TestPgSchema.drop(~pgSchema)
  await sql->Postgres.endSql
})

let storage = PgStorage.make(
  ~sql,
  ~pgHost=Env.Db.host,
  ~pgSchema,
  ~pgPort=Env.Db.port,
  ~pgUser=Env.Db.user,
  ~pgDatabase=Env.Db.database,
  ~pgPassword=Env.Db.password,
  ~isHasuraEnabled=false,
  ~ecosystem=Evm,
)

let readyAt = async () => {
  let rows: array<{"ready_at": Null.t<Date.t>}> = await sql->Postgres.unsafe(
    `SELECT "ready_at" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
  )
  rows->Array.map(row => row["ready_at"]->Null.toOption->Option.isSome)
}

describe("A chain metadata write", () => {
  Async.it("Can't clear the ready timestamp the finalization committed", async t => {
    let _ = await storage.initialize(
      ~chainConfigs=config.chainMap->ChainMap.values,
      ~contractMapping=config.contractMapping,
      ~entities=config.userEntities,
      ~enums=config.allEnums->Array.concat([
        EntityHistory.RowAction.config->Table.fromGenericEnumConfig,
      ]),
      ~envioInfo=JSON.Encode.object(Dict.make()),
    )
    await storage.finalizeBackfill(
      ~entities=config.userEntities,
      ~chainIds=config.chainMap->ChainMap.keys,
      ~readyAt=Date.make(),
    )
    let stamped = await readyAt()

    // What a process staged before it was ready, landing after the stamp.
    let stale = Dict.make()
    config.chainMap
    ->ChainMap.keys
    ->Array.forEach(chainId =>
      stale->Dict.set(
        chainId->ChainId.toString,
        {
          InternalTable.Chains.firstEventBlockNumber: Null.null,
          latestFetchedBlockNumber: 10,
          timestampCaughtUpToHeadOrEndblock: Null.null,
          isHyperSync: false,
        },
      )
    )
    let _ = await storage.setChainMeta(stale)

    t.expect((stamped, await readyAt())).toStrictEqual(([true], [true]))
  })
})
