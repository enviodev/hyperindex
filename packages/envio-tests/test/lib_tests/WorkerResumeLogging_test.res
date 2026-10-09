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

let initRun = (~isolated, ~announceResume=true) =>
  makePersistence()->Persistence.init(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping=config.contractMapping,
    ~envioInfo=JSON.Encode.object(Dict.make()),
    ~resetCommand="envio dev -r",
    ~runCommand=Some("envio dev"),
    ~lowercaseAddresses=config.lowercaseAddresses,
    ~isolated,
    ~announceResume,
  )

let resumeLines = async (~announceResume) => {
  let path = `${NodeJs.Process.cwd()}/lib/envio-worker-resume-${Date.now()->Float.toString}-${announceResume
      ? "announced"
      : "quiet"}.log`
  Logging.setLogger(
    Logging.makeLogger(
      ~logStrategy=FileOnly,
      ~logFilePath=path,
      ~defaultFileLogLevel=#info,
      ~userLogLevel=#info,
    ),
  )

  await initRun(~isolated=true, ~announceResume)
  Logging.info("done")

  let rec until = async deadline =>
    switch await LogFile.messages(path) {
    | lines if lines->Array.includes("done") || Date.now() > deadline => lines
    | _ =>
      await Utils.delay(50)
      await until(deadline)
    }
  await until(Date.now() +. 3000.)
}

describe("Announcing a resume", () => {
  // The supervisor says it once for the whole run, so a worker it forked has
  // nothing to add. Every other process resuming a subset of the chains is
  // somebody's only window onto it, `envio start --chain` included, and both
  // of them need the schema to exist already — so what a process requires of
  // the storage can't be what decides whether it speaks.
  Async.it("Quiet for a forked worker, and not for anyone else", async t => {
    await initRun(~isolated=false)

    let quiet = await resumeLines(~announceResume=false)
    let announced = await resumeLines(~announceResume=true)

    t.expect((quiet, announced)).toStrictEqual((
      ["done"],
      [
        "Found existing indexer storage. Resuming indexing state...",
        "Successfully resumed indexing state! Continuing from the last checkpoint.",
        "done",
      ],
    ))
  })
})
