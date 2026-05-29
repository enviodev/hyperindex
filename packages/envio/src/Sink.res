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
  let client = ClickHouse.createClient({
    url: host,
    username,
    password,
  })

  // Don't pass database to the client; it would fail if the database doesn't
  // exist yet. Each query qualifies the name explicitly or runs USE first.

  let cache = Utils.WeakMap.make()

  {
    name: "clickhouse",
    initialize: (~chainConfigs as _=[], ~entities=[], ~enums=[]) => {
      ClickHouse.initialize(client, ~database, ~entities, ~enums)
    },
    resume: (~checkpointId) => {
      ClickHouse.resume(client, ~database, ~checkpointId)
    },
    writeBatch: async (~batch, ~updatedEntities) => {
      await Promise.all(
        updatedEntities->Belt.Array.map(({entityConfig, changes}) => {
          ClickHouse.setUpdatesOrThrow(client, ~cache, ~changes, ~entityConfig, ~database)
        }),
      )->Utils.Promise.ignoreValue
      await ClickHouse.setCheckpointsOrThrow(client, ~batch, ~database)
    },
  }
}
