open Vitest

// Finalizing a schema that declares no indexes has nothing to say about them.
// The indexer reporting itself ready is `FinalizeBackfill`'s line, not this
// one's, so a schema with no indexes should leave no trace here.
let sql = PgStorage.makeClient()
let pgSchema = TestPgSchema.make()
let config = TestConfig.make()

Async.afterAll(async () => {
  await sql->TestPgSchema.drop(~pgSchema)
  await sql->Sql.close
})

let loggedLines = async path =>
  switch await NodeJs.Fs.Promises.readFile(~filepath=NodeJs.Path.resolve([path]), ~encoding=Utf8) {
  | contents =>
    contents
    ->String.trim
    ->String.split("\n")
    ->Array.filterMap(line => line->JSON.parseOrThrow->JSON.Decode.object)
  | exception _ => []
  }

let message = fields => fields->Dict.get("msg")->Option.flatMap(JSON.Decode.string)

// Logs to a file of its own, runs `act`, then logs a marker and reads back
// everything up to it. The storage reports index events from another thread,
// so one more turn of the event loop lets any it queued land first.
let logsOf = async act => {
  let path = `${NodeJs.Process.cwd()}/lib/envio-index-logs-${Date.now()->Float.toString}.log`
  Logging.setLogger(
    Logging.makeLogger(
      ~logStrategy=FileOnly,
      ~logFilePath=path,
      ~defaultFileLogLevel=#info,
      ~userLogLevel=#info,
    ),
  )
  await act()
  await Utils.delay(0)
  Logging.info("done")
  let rec until = async deadline =>
    switch await loggedLines(path) {
    | lines
      if lines->Array.some(line => line->message === Some("done")) || Date.now() > deadline => lines
    | _ =>
      await Utils.delay(50)
      await until(deadline)
    }
  await until(Date.now() +. 3000.)
}

describe("Finalizing a schema with no indexes", () => {
  Async.it("Says nothing about the indexes it didn't have to build", async t => {
    let storage = PgStorage.make(~pgSchema, ~ecosystem=Evm)
    let _ = await storage.initialize(
      ~chainConfigs=config.chainMap->ChainMap.values,
      ~contractMapping=config.contractMapping,
      ~entities=config.userEntities,
      ~enums=config.allEnums,
      ~envioInfo=JSON.Encode.object(Dict.make()),
    )

    let lines = await logsOf(
      () =>
        storage.finalizeBackfill(
          ~entities=config.userEntities,
          ~chainIds=config.chainMap->ChainMap.keys,
          ~readyAt=Date.make(),
        ),
    )

    t.expect(lines->Array.filterMap(message)).toStrictEqual(["done"])
  })
})

describe("A schema index the database can't build", () => {
  Async.it("Is logged with the server's error code", async t => {
    let pgSchema = `${pgSchema}_failed`
    let config = TestConfig.make(
      ~schema=`
type Token {
  id: ID!
  owner: String! @index
}
`,
    )
    let storage = PgStorage.make(~pgSchema, ~ecosystem=Evm)
    let _ = await storage.initialize(
      ~chainConfigs=config.chainMap->ChainMap.values,
      ~contractMapping=config.contractMapping,
      ~entities=config.userEntities,
      ~enums=config.allEnums,
      ~envioInfo=JSON.Encode.object(Dict.make()),
    )
    let _ = await sql->Sql.query(`ALTER TABLE "${pgSchema}"."Token" DROP COLUMN "owner";`)

    let lines = await logsOf(
      () =>
        storage.ensureSchemaIndexes(
          ~entities=config.userEntities,
          ~chainIds=config.chainMap->ChainMap.keys,
        ),
    )
    await sql->TestPgSchema.drop(~pgSchema)

    t.expect(
      lines->Array.filterMap(
        line =>
          line
          ->Dict.get("code")
          ->Option.flatMap(JSON.Decode.string)
          ->Option.map(code => (line->message, code)),
      ),
    ).toEqual([
      (
        Some(`Failed to restore the schema index "Token_owner_9t23tg2g16". Queries relying on it run unindexed until the next restart.`),
        "42703",
      ),
    ])
  })
})
