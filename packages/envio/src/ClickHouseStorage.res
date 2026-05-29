// ClickHouse-backed Persistence.storage. Replaces the prior `Sink` module —
// ClickHouse now plugs into Persistence as a peer of Postgres, so the same
// init/validate/reset flow runs over it.
//
// Many methods on Persistence.storage are PG-only today (loaders, effect
// cache, chain meta, rollback queries). They throw a friendly "not supported
// yet" error if invoked against ClickHouse; in practice they only fire for
// entities whose primary storage resolves to ClickHouse, which today is
// nobody since every entity opting into ClickHouse also opts into Postgres.

let unsupported = (method: string) =>
  JsError.throwWithMessage(
    `${method} is not supported on ClickHouse storage yet. Enable \`storage.postgres\` on this entity to use this operation.`,
  )

let make = (~host, ~database, ~username, ~password): Persistence.storage => {
  let client = ClickHouse.createClient({
    url: host,
    username,
    password,
  })

  // Don't pass `database` to createClient — it fails if the database doesn't
  // exist yet. Queries explicitly qualify table names with the database.
  let database = switch database {
  | Some(database) => database
  | None => "envio_indexer"
  }

  let cache = Utils.WeakMap.make()

  let isInitialized = () => ClickHouse.isInitialized(client, ~database)

  let reset = () => ClickHouse.dropDatabase(client, ~database)

  let initialize = async (~chainConfigs as _=[], ~entities=[], ~enums=[], ~envioInfo) => {
    let chEntities = entities->Array.filter((e: Internal.entityConfig) => e.storage.clickhouse)
    await ClickHouse.initialize(client, ~database, ~entities=chEntities, ~enums, ~envioInfo)

    (
      {
        cleanRun: true,
        cache: Dict.make(),
        chains: [],
        reorgCheckpoints: [],
        checkpointId: InternalTable.Checkpoints.initialCheckpointId,
        envioInfo: Some(envioInfo),
      }: Persistence.initialState
    )
  }

  let resumeInitialState = async (): Persistence.initialState => {
    let envioInfo = await ClickHouse.readEnvioInfo(client, ~database)
    {
      cleanRun: false,
      cache: Dict.make(),
      chains: [],
      reorgCheckpoints: [],
      checkpointId: InternalTable.Checkpoints.initialCheckpointId,
      envioInfo,
    }
  }

  let writeBatch = async (
    ~batch: Batch.t,
    ~rawEvents as _,
    ~rollbackTargetCheckpointId,
    ~isInReorgThreshold as _,
    ~config as _,
    ~allEntities as _,
    ~updatedEffectsCache as _,
    ~updatedEntities: array<Persistence.updatedEntity>,
    ~siblingTxHooks as _=[],
  ) => {
    // Rollback handling — must run before writes for this batch so we don't
    // leave history rows newer than the rollback target.
    switch rollbackTargetCheckpointId {
    | Some(checkpointId) => await ClickHouse.rollback(client, ~database, ~checkpointId)
    | None => ()
    }

    let chUpdates =
      updatedEntities->Array.filter(({entityConfig}: Persistence.updatedEntity) =>
        entityConfig.storage.clickhouse
      )

    await Promise.all(
      chUpdates->Belt.Array.map(({entityConfig, updates}) => {
        ClickHouse.setUpdatesOrThrow(client, ~cache, ~updates, ~entityConfig, ~database)
      }),
    )->Utils.Promise.ignoreValue
    await ClickHouse.setCheckpointsOrThrow(client, ~batch, ~database)
  }

  {
    name: "clickhouse",
    isInitialized,
    initialize,
    resumeInitialState,
    loadByIdsOrThrow: (~ids as _, ~table as _, ~rowsSchema as _) => unsupported("loadByIdsOrThrow"),
    loadByFieldOrThrow: (
      ~fieldName as _,
      ~fieldSchema as _,
      ~fieldValue as _,
      ~operator as _,
      ~table as _,
      ~rowsSchema as _,
    ) => unsupported("loadByFieldOrThrow"),
    dumpEffectCache: () => Promise.resolve(),
    reset,
    setChainMeta: _ => unsupported("setChainMeta"),
    pruneStaleCheckpoints: (~safeCheckpointId as _) => unsupported("pruneStaleCheckpoints"),
    pruneStaleEntityHistory: (~entityName as _, ~entityIndex as _, ~safeCheckpointId as _) =>
      unsupported("pruneStaleEntityHistory"),
    getRollbackTargetCheckpoint: (~reorgChainId as _, ~lastKnownValidBlockNumber as _) =>
      unsupported("getRollbackTargetCheckpoint"),
    getRollbackProgressDiff: (~rollbackTargetCheckpointId as _) =>
      unsupported("getRollbackProgressDiff"),
    getRollbackData: (~entityConfig as _, ~rollbackTargetCheckpointId as _) =>
      unsupported("getRollbackData"),
    writeBatch,
    alignToCheckpoint: (~checkpointId) => ClickHouse.rollback(client, ~database, ~checkpointId),
    close: () => ClickHouse.close(client),
  }
}

// Validates required env vars only when ClickHouse storage is enabled.
let makeFromEnv = (): option<Persistence.storage> => {
  let host = Env.ClickHouse.host()
  let username = Env.ClickHouse.username()
  let password = Env.ClickHouse.password()
  let missing = []
  let checkEnv = (opt, name) =>
    switch opt {
    | Some(_) => ()
    | None => missing->Array.push(name)->ignore
    }
  host->checkEnv("ENVIO_CLICKHOUSE_HOST")
  username->checkEnv("ENVIO_CLICKHOUSE_USERNAME")
  password->checkEnv("ENVIO_CLICKHOUSE_PASSWORD")
  if missing->Array.length > 0 {
    JsError.throwWithMessage(
      `ClickHouse storage is enabled but required env vars are not set: ${missing->Array.joinUnsafe(
          ", ",
        )}. Please set them, disable clickhouse in the \`storage\` config, or run \`envio dev\` for a pre-configured local ClickHouse.`,
    )
  }
  Some(
    make(
      ~host=host->Option.getUnsafe,
      ~database=Env.ClickHouse.database(),
      ~username=username->Option.getUnsafe,
      ~password=password->Option.getUnsafe,
    ),
  )
}
