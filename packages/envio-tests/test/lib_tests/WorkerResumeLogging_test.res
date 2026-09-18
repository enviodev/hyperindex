open Vitest

let sql = PgStorage.makeClient()
let pgSchema = TestPgSchema.make()
let config = TestConfig.make()

Async.afterAll(async () => {
  await sql->TestPgSchema.drop(~pgSchema)
  await sql->Postgres.endSql
})

let makePersistence = () =>
  Persistence.make(
    ~userEntities=config.userEntities,
    ~allEnums=config.allEnums,
    ~storage=PgStorage.make(
      ~sql,
      ~pgHost=Env.Db.host,
      ~pgSchema,
      ~pgPort=Env.Db.port,
      ~pgUser=Env.Db.user,
      ~pgDatabase=Env.Db.database,
      ~pgPassword=Env.Db.password,
      ~isHasuraEnabled=false,
      ~ecosystem=Evm,
    ),
  )

let initRun = (~requireInitialized) =>
  makePersistence()->Persistence.init(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping=config.contractMapping,
    ~envioInfo=JSON.Encode.object(Dict.make()),
    ~resetCommand="envio dev -r",
    ~runCommand=Some("envio dev"),
    ~lowercaseAddresses=config.lowercaseAddresses,
    ~requireInitialized,
  )

let logLines = async path =>
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

describe("Resuming an isolated worker", () => {
  // The supervisor announces the run's storage once, for every chain. A worker
  // resuming the state it was handed has nothing to add to that.
  Async.it("Stays quiet about storage the supervisor already announced", async t => {
    await initRun(~requireInitialized=false)

    let path = `${NodeJs.Process.cwd()}/lib/envio-worker-resume-${Date.now()->Float.toString}.log`
    Logging.setLogger(
      Logging.makeLogger(
        ~logStrategy=FileOnly,
        ~logFilePath=path,
        ~defaultFileLogLevel=#info,
        ~userLogLevel=#info,
      ),
    )

    await initRun(~requireInitialized=true)
    Logging.info("done")

    let rec until = async deadline =>
      switch await logLines(path) {
      | lines if lines->Array.includes("done") || Date.now() > deadline => lines
      | _ =>
        await Utils.delay(50)
        await until(deadline)
      }

    t.expect(await until(Date.now() +. 3000.)).toStrictEqual(["done"])
  })
})
