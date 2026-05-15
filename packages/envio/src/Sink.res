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

let makeClickHouse = (~host, ~database, ~username, ~password): t => {
  // The JS @clickhouse/client client is still used for DDL (initialize/resume).
  // Write paths (entity history + checkpoints) go through the Rust addon over
  // RowBinary; see ClickHouseStorage.res and packages/cli/src/clickhouse_storage.rs.
  let client = ClickHouse.createClient({
    url: host,
    username,
    password,
  })

  let endpoint: ClickHouseStorage.endpoint = {
    url: host,
    username,
    password,
    database,
  }

  {
    name: "clickhouse",
    initialize: (~chainConfigs as _=[], ~entities=[], ~enums=[]) => {
      ClickHouse.initialize(client, ~database, ~entities, ~enums)
    },
    resume: (~checkpointId) => {
      ClickHouse.resume(client, ~database, ~checkpointId)
    },
    writeBatch: async (~batch, ~updatedEntities) => {
      let entityPromises = updatedEntities->Belt.Array.map(({entityConfig, updates}) => {
        ClickHouseStorage.setUpdatesOrThrow(~endpoint, ~updates, ~entityConfig)
      })
      let checkpointPromise = ClickHouseStorage.setCheckpointsOrThrow(~endpoint, ~batch)
      let _ = await Promise.all(entityPromises->Array.concat([checkpointPromise]))
    },
  }
}
