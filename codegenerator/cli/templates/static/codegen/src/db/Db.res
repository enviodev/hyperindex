// This is a module with all the global configuration of the DB
// Ideally it should be moved to the config and passed with it

let config: Postgres.poolConfig = {
  host: Env.Db.host,
  port: Env.Db.port,
  username: Env.Db.user,
  password: Env.Db.password,
  database: Env.Db.database,
  ssl: Env.Db.ssl,
  // TODO: think how we want to pipe these logs to pino.
  onnotice: ?(Env.userLogLevel == #warn || Env.userLogLevel == #error ? None : Some(_str => ())),
  transform: {undefined: Null},
  max: 2,
}
let sql = Postgres.makeSql(~config)
let publicSchema = Env.Db.publicSchema

let allEntityTables: array<Table.table> = Entities.allEntities->Belt.Array.map(entityConfig => {
  entityConfig.table
})

let allStaticTables: array<Table.table> = [
  InternalTable.EventSyncState.table,
  InternalTable.ChainMetadata.table,
  InternalTable.PersistedState.table,
  InternalTable.EndOfBlockRangeScannedData.table,
  InternalTable.RawEvents.table,
]

let schema = Schema.make(allEntityTables)
