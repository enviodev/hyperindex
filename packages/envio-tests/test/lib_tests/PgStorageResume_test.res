open Vitest

// What Postgres stored is what the compatibility check has to be handed: the
// only thing binding the check to the storage is this call.
let sql = PgStorage.makeClient()

let config = TestConfig.make(
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
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

describe("Resuming Postgres storage", () => {
  Async.it("hands the stored config to the compatibility check and stops on its throw", async t => {
    let storage = PgStorage.make(
      ~sql,
      ~pgSchema,
      ~pgUser=Env.Db.user,
      ~isHasuraEnabled=false,
      ~ecosystem=Evm,
    )
    let envioInfo = JSON.parseOrThrow(`{"name": "stored", "storage": {"clickhouse": false}}`)
    let _ = await storage.initialize(
      ~chainConfigs=config.chainMap->ChainMap.values,
      ~contractMapping=config.contractMapping,
      ~entities,
      ~enums,
      ~envioInfo,
    )

    let handed = []
    let outcome = try {
      let _ = await storage.resumeInitialState(
        ~entities,
        ~chainIds=config.chainMap->ChainMap.keys,
        ~throwIfIncompatible=(~storedEnvioInfo, ~storedContractMapping) => {
          handed
          ->Array.push((
            storedEnvioInfo,
            storedContractMapping->ContractMapping.isEqual(config.contractMapping),
          ))
          ->ignore
          JsError.throwWithMessage("refused")
        },
      )
      "resumed"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("")
    }

    t.expect((handed, outcome)).toEqual(([(Some(envioInfo), true)], "refused"))
  })
})
