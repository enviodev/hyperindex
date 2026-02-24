type t = {
  name: string,
  initialize: (
    ~chainConfigs: array<Config.chain>=?,
    ~entities: array<Internal.entityConfig>=?,
    ~enums: array<Table.enumConfig<Table.enum>>=?,
  ) => promise<unit>,
  resume: (~checkpointId: float) => promise<unit>,
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

  // Don't assign it to client immediately,
  // since it will fail if the database doesn't exist
  // Call USE database instead
  let database = switch database {
  | Some(database) => database
  | None => "envio_sink"
  }

  {
    name: "ClickHouse",
    initialize: (~chainConfigs as _=[], ~entities=[], ~enums=[]) => {
      ClickHouse.initialize(client, ~database, ~entities, ~enums)
    },
    resume: (~checkpointId) => {
      ClickHouse.resume(client, ~database, ~checkpointId)
    },
    writeBatch: async (~batch, ~updatedEntities) => {
      await Promise.all(
        updatedEntities->Belt.Array.map(({entityConfig, updates}) => {
          ClickHouse.setUpdatesOrThrow(client, ~updates, ~entityConfig, ~database)
        }),
      )->Utils.Promise.ignoreValue
      await ClickHouse.setCheckpointsOrThrow(client, ~batch, ~database)
    },
  }
}
