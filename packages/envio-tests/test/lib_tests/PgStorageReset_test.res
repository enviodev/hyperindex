open Vitest

// A reset drops the schema and builds it again, and the connections that served
// the process before it are the ones that serve it after.

let sql = PgStorage.makeClient()

let config = TestConfig.make(
  ~schema=`
enum Status {
  PENDING
  ACTIVE
}

type Counter {
  id: ID!
  status: Status!
}
`,
)
let entities = [config->IndexerRunner.entityConfigByName("Counter")]
let enums =
  config.allEnums->Array.concat([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])
let pgSchema = TestPgSchema.make()

Async.afterAll(async () => {
  let _ = await sql->Sql.query(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`)
  await sql->Sql.close
})

describe("Resetting Postgres storage", () => {
  Async.it("serves the same query against the schema it built again", async t => {
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
    let table = (entities->Array.getUnsafe(0)).table
    let filter = EntityFilter.Eq({
      fieldName: "id",
      fieldValue: "1"->(Utils.magic: string => unknown),
    })
    let initialize = () =>
      storage.initialize(
        ~chainConfigs=config.chainMap->ChainMap.values,
        ~contractMapping=config.contractMapping,
        ~entities,
        ~enums,
        ~envioInfo=JSON.parseOrThrow(`{"name": "reset"}`),
      )

    let _ = await initialize()
    let before = await storage.loadOrThrow(~filter, ~table)

    await storage.reset()
    let _ = await initialize()

    // The same text as the load above, so a connection that kept the statement
    // it prepared then would answer this one with a plan describing an enum
    // type the reset has dropped.
    let after = await storage.loadOrThrow(~filter, ~table)

    t.expect((before, after)).toEqual(([], []))
  })
})
