open Vitest

// Finalizing a schema that declares no indexes has nothing to say about them.
// The indexer reporting itself ready is `FinalizeBackfill`'s line, not this
// one's, so a schema with no indexes should leave no trace here.
let sql = PgStorage.makeClient()
let pgSchema = TestPgSchema.make()
let config = TestConfig.make()

Async.afterAll(async () => {
  await sql->TestPgSchema.drop(~pgSchema)
  await sql->Postgres.endSql
})

let loggedMessages = async path =>
  switch await NodeJs.Fs.Promises.readFile(~filepath=NodeJs.Path.resolve([path]), ~encoding=Utf8) {
  | contents =>
    contents
    ->String.trim
    ->String.split("\n")
    ->Array.filterMap(line =>
      switch line->JSON.parseOrThrow->JSON.Decode.object {
      | Some(fields) => fields->Dict.get("msg")->Option.flatMap(JSON.Decode.string)
      | None => None
      }
    )
  | exception _ => []
  }

describe("Finalizing a schema with no indexes", () => {
  Async.it("Says nothing about the indexes it didn't have to build", async t => {
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
    let _ = await storage.initialize(
      ~chainConfigs=config.chainMap->ChainMap.values,
      ~contractMapping=config.contractMapping,
      ~entities=config.userEntities,
      ~enums=config.allEnums->Array.concat([
        EntityHistory.RowAction.config->Table.fromGenericEnumConfig,
      ]),
      ~envioInfo=JSON.Encode.object(Dict.make()),
    )

    let path = `${NodeJs.Process.cwd()}/lib/envio-finalize-indexes-${Date.now()->Float.toString}.log`
    Logging.setLogger(
      Logging.makeLogger(
        ~logStrategy=FileOnly,
        ~logFilePath=path,
        ~defaultFileLogLevel=#info,
        ~userLogLevel=#info,
      ),
    )

    await storage.finalizeBackfill(
      ~entities=config.userEntities,
      ~chainIds=config.chainMap->ChainMap.keys,
      ~readyAt=Date.make(),
    )
    Logging.info("done")

    let rec until = async deadline =>
      switch await loggedMessages(path) {
      | messages if messages->Array.includes("done") || Date.now() > deadline => messages
      | _ =>
        await Utils.delay(50)
        await until(deadline)
      }

    t.expect(await until(Date.now() +. 3000.)).toStrictEqual(["done"])
  })
})
