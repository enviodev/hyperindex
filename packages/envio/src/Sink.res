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

// DuckDB / DuckLake are full mirrors of every persisted entity. Both run the
// same DDL/DML; they differ only in how the connection is opened, so the sink
// body is shared and each variant supplies its own lazy connection factory.
let makeDuckSink = (~name, ~getConn): t => {
  name,
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

// Single local file. Single-writer: external readers are locked out while the
// indexer runs.
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
  makeDuckSink(~name="duckdb", ~getConn)
}

// DuckLake: Parquet data files + a SQLite catalog under `dir`. The DuckDB
// engine is in-memory (just the attach point); persistence lives in the
// catalog + Parquet files, which lets other processes read concurrently while
// the indexer writes. The ducklake/sqlite extensions are installed on first
// run (needs network).
let makeDuckLake = (~dir): t => {
  let connRef = ref(None)
  let getConn = async () =>
    switch connRef.contents {
    | Some(p) => await p
    | None =>
      let dirPath = NodeJs.Path.resolve([dir])
      let filesPath = dirPath->NodeJs.Path.join("files")
      let catalogStr = dirPath->NodeJs.Path.join("catalog.sqlite")->NodeJs.Path.toString
      let filesStr = filesPath->NodeJs.Path.toString
      let p =
        NodeJs.Fs.Promises.mkdir(~path=filesPath, ~options={recursive: true})
        ->Promise.then(() => DuckDb.createInstance(":memory:"))
        ->Promise.then(instance => instance->DuckDb.connect)
        ->Promise.then(async conn => {
          await conn->DuckDb.run("INSTALL ducklake")
          await conn->DuckDb.run("INSTALL sqlite")
          await conn->DuckDb.run("LOAD ducklake")
          await conn->DuckDb.run("LOAD sqlite")
          await conn->DuckDb.run(
            `ATTACH 'ducklake:sqlite:${catalogStr}' AS envio_lake (DATA_PATH '${filesStr}/')`,
          )
          await conn->DuckDb.run("USE envio_lake")
          conn
        })
      connRef := Some(p)
      await p
    }
  makeDuckSink(~name="ducklake", ~getConn)
}
