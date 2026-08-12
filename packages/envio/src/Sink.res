type t = {
  name: string,
  initialize: (
    ~chainConfigs: array<Config.chain>=?,
    ~entities: array<Internal.entityConfig>=?,
    ~enums: array<Table.enumConfig<Table.enum>>=?,
  ) => promise<unit>,
  resume: (~checkpointId: Internal.checkpointId) => promise<unit>,
  writeBatch: (
    ~batch: Batch.t,
    ~updatedEntities: array<Persistence.updatedEntity>,
  ) => promise<unit>,
}

let makeClickHouse = (~host, ~database, ~username, ~password, ~chainIdMode: ChainId.mode=Int32): t => {
  let client = ClickHouse.createClient({
    url: host,
    username,
    password,
  })

  // Don't pass database to the client; it would fail if the database doesn't
  // exist yet. Each query qualifies the name explicitly or runs USE first.

  // Inserts go through the Rust sink: values cross the napi boundary columnar,
  // get encoded as RowBinary and are sent off the Node main thread. DDL, the
  // current-state views and the reorg cleanup stay on the JS client.
  let sink = ClickHouseSink.make(~url=host, ~username, ~password, ~database)

  let cache = Dict.make()

  {
    name: "clickhouse",
    initialize: (~chainConfigs as _=[], ~entities=[], ~enums=[]) => {
      ClickHouse.initialize(client, ~sink, ~database, ~entities, ~enums, ~chainIdMode)
    },
    resume: (~checkpointId) => {
      ClickHouse.resume(client, ~database, ~checkpointId)
    },
    writeBatch: async (~batch, ~updatedEntities) => {
      await Promise.all(
        updatedEntities->Array.map(({entityConfig, scope, changes}) => {
          ClickHouse.setUpdatesOrThrow(
            sink,
            ~cache,
            ~changes,
            ~entityConfig,
            ~scope,
            ~chainIdMode,
          )
        }),
      )->Utils.Promise.ignoreValue
      // Checkpoints land after the rows they cover: the current-state view reads
      // up to `max(id)`, so a checkpoint visible before its rows would expose a
      // partial batch.
      await ClickHouse.setCheckpointsOrThrow(sink, ~batch, ~chainIdMode)
    },
  }
}
