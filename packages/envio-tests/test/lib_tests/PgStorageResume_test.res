open Vitest

// What Postgres stored is what the compatibility check has to be handed: the
// only thing binding the check to the storage is this call.
let sql = PgStorage.makeClient()

// A per-chain entity, so the added chain has to grow a partition of its own.
let schema = `
type Counter {
  id: ID!
  count: BigInt! @index
}
`

let makeConfig = (~chains) =>
  TestConfig.multiChain(~chains, ~schema, ~extra="\ndisable_default_cross_chain: true")

let {TestConfig.config: config} = makeConfig(~chains=[(1, "Gravatar")])
let entities = [config->IndexerRunner.entityConfigByName("Counter")]
let enums =
  config.allEnums->Array.concat([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])
let pgSchema = TestPgSchema.make()
// The migration test needs a schema of its own: it initializes one config and
// then resumes against another, which the shared one above is already past.
let migrateSchema = TestPgSchema.make()

let makeStorage = (~pgSchema) =>
  PgStorage.make(
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

Async.afterAll(async () => {
  let _ = await sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`)
  let _ = await sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${migrateSchema}" CASCADE;`)
  await sql->Postgres.endSql
})

describe("Resuming Postgres storage", () => {
  Async.it("hands the stored config to the compatibility check and stops on its throw", async t => {
    let storage = makeStorage(~pgSchema)
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

  Async.it("adds a chain the schema was never initialized with", async t => {
    let storage = makeStorage(~pgSchema=migrateSchema)

    let before = makeConfig(~chains=[(1, "Gravatar")])
    let after = makeConfig(~chains=[(1, "Gravatar"), (137, "Poster")])
    let entitiesOf = (config: Config.t) => [config->IndexerRunner.entityConfigByName("Counter")]

    let _ = await storage.initialize(
      ~chainConfigs=before.config.chainMap->ChainMap.values,
      ~contractMapping=before.config.contractMapping,
      ~entities=entitiesOf(before.config),
      ~enums,
      ~envioInfo=before.envioInfo,
    )

    // What a synced indexer leaves behind: the deferred schema indexes built and
    // every chain stamped ready.
    await storage.finalizeBackfill(
      ~entities=entitiesOf(before.config),
      ~chainIds=before.config.chainMap->ChainMap.keys,
      ~readyAt=Date.make(),
    )

    let storedInfo = ref(None)
    let _ = await storage.resumeInitialState(
      ~entities=entitiesOf(after.config),
      ~throwIfIncompatible=(~storedEnvioInfo, ~storedContractMapping as _) =>
        storedInfo := storedEnvioInfo,
    )
    let detected = switch storedInfo.contents {
    | Some(stored) => Config.addedChains(~stored, ~current=after.envioInfo)
    | None => []
    }

    await storage.addChains(
      ~chainConfigs=after.config.chainMap
      ->ChainMap.values
      ->Config.selectChainsOrThrow(~added=detected),
      ~entities=entitiesOf(after.config),
      ~storedContractMapping=before.config.contractMapping,
      ~envioInfo=after.envioInfo,
    )

    // The resume that follows runs the real compatibility check: it passing is
    // what says the migration brought the schema up to the config.
    let resumed = await storage.resumeInitialState(
      ~entities=entitiesOf(after.config),
      ~throwIfIncompatible=(~storedEnvioInfo, ~storedContractMapping) =>
        Config.throwIfResumeIncompatible(
          ~storedEnvioInfo,
          ~storedContractMapping,
          ~envioInfo=after.envioInfo,
          ~contractMapping=after.config.contractMapping,
          ~resetCommand="envio start -r",
          ~runCommand=None,
        ),
    )

    let partitions: array<{
      "tablename": string,
    }> = await sql->Postgres.unsafe(
      `SELECT tablename FROM pg_tables WHERE schemaname = '${migrateSchema}' AND tablename LIKE 'Counter$%' ORDER BY tablename;`,
    )
    // The schema's indexes live on the partitioned parent, so Postgres builds
    // them on a partition as it is attached. That is why a migrated chain owes
    // no index work of its own.
    let indexedPartitions: array<{
      "tablename": string,
    }> = await sql->Postgres.unsafe(
      `SELECT tablename FROM pg_indexes WHERE schemaname = '${migrateSchema}' AND tablename LIKE 'Counter$%' AND indexdef LIKE '%count%' ORDER BY tablename;`,
    )

    t.expect({
      "detected": detected->Array.map(({path}: Config.addedChain) => path),
      // The added chain starts where a fresh one would: nothing processed and no
      // `ready_at`, while the chain that was already synced keeps its stamp.
      // That split is what makes the next run a backfill with the ready chain
      // frozen.
      "chains": resumed.chains
      ->Array.map(
        chain => (
          chain.id->ChainId.toString,
          chain.progressBlockNumber,
          chain.timestampCaughtUpToHeadOrEndblock->Option.isSome,
        ),
      )
      ->Array.toSorted(((a, _, _), (b, _, _)) => String.compare(a, b)),
      // Appended, so the id every already-stored address row references is
      // still the name it was written with.
      "contracts": resumed.contractMapping->ContractMapping.names,
      "partitions": partitions->Array.map(row => row["tablename"]),
      "indexedPartitions": indexedPartitions->Array.map(row => row["tablename"]),
    }).toEqual({
      "detected": ["evm.chains.polygon"],
      "chains": [("1", -1, true), ("137", -1, false)],
      "contracts": ["Gravatar", "Poster"],
      "partitions": ["Counter$1", "Counter$137"],
      "indexedPartitions": ["Counter$1", "Counter$137"],
    })
  })
})
