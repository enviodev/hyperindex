type t = {
  name: string,
  // Which entities this sink mirrors. PgStorage filters entities/updates
  // through this before calling initialize/writeBatch.
  shouldStoreEntity: Internal.entityConfig => bool,
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
    shouldStoreEntity: entityConfig => entityConfig.storage.clickhouse,
    initialize: (~chainConfigs as _=[], ~entities=[], ~enums=[]) => {
      ClickHouse.initialize(client, ~database, ~entities, ~enums)
    },
    resume: (~checkpointId) => {
      ClickHouse.resume(client, ~database, ~checkpointId)
    },
    writeBatch: async (~batch, ~updatedEntities) => {
      await Promise.all(
        updatedEntities->Belt.Array.map(({entityConfig, updates}) => {
          ClickHouse.setUpdatesOrThrow(client, ~cache, ~updates, ~entityConfig, ~database)
        }),
      )->Utils.Promise.ignoreValue
      await ClickHouse.setCheckpointsOrThrow(client, ~batch, ~database)
    },
  }
}

// DuckDB is a full mirror of every persisted entity, backed by a local file.
// The connection is opened lazily because instance/connect are async and the
// file path's parent directory must exist first.
let makeDuckDb = (~path): t => {
  let connRef = ref(None)
  let getConn = async () =>
    switch connRef.contents {
    | Some(p) => await p
    | None =>
      let p =
        NodeJs.Fs.Promises.mkdir(~path=NodeJs.Path.dirname(path), ~options={recursive: true})
        ->Promise.then(() => DuckDb.createInstance(path))
        ->Promise.then(instance => instance->DuckDb.connect)
      connRef := Some(p)
      await p
    }

  {
    name: "duckdb",
    shouldStoreEntity: _ => true,
    initialize: async (~chainConfigs as _=[], ~entities=[], ~enums as _=[]) => {
      let conn = await getConn()
      await DuckDb.initialize(conn, ~entities)
    },
    resume: async (~checkpointId) => {
      let conn = await getConn()
      await DuckDb.resume(conn, ~checkpointId)
    },
    writeBatch: async (~batch, ~updatedEntities) => {
      let conn = await getConn()
      await DuckDb.writeBatch(conn, ~batch, ~updatedEntities)
    },
  }
}
