type t = {
  name: string,
  initialize: (
    ~chainConfigs: array<Config.chain>=?,
    ~entities: array<Internal.entityConfig>=?,
    ~enums: array<Table.enumConfig<Table.enum>>=?,
  ) => promise<unit>,
  resume: (~checkpointId: int) => promise<unit>,
  writeBatch: (~updatedEntities: array<Persistence.updatedEntity>) => promise<unit>,
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
  | None => "envio_mirror"
  }

  {
    name: "ClickHouse",
    initialize: (~chainConfigs as _=[], ~entities=[], ~enums=[]) => {
      ClickHouse.initialize(client, ~database, ~entities, ~enums)
    },
    resume: (~checkpointId) => {
      ClickHouse.resume(client, ~database, ~checkpointId)
    },
    writeBatch: (~updatedEntities) => {
      Promise.all(
        updatedEntities->Belt.Array.map(({entityConfig, updates}) => {
          ClickHouse.setUpdatesOrThrow(client, ~updates, ~entityConfig, ~database)
        }),
      )->Promise.ignoreValue
    },
  }
}
