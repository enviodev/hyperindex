// This is a module with all the global configuration of the DB
// Ideally it should be moved to the config and passed with it

let makeClient = () => {
  Postgres.makeSql(
    ~config={
      host: Env.Db.host,
      port: Env.Db.port,
      username: Env.Db.user,
      password: Env.Db.password,
      database: Env.Db.database,
      ssl: Env.Db.ssl,
      // TODO: think how we want to pipe these logs to pino.
      onnotice: ?(
        Env.userLogLevel == #warn || Env.userLogLevel == #error ? None : Some(_str => ())
      ),
      transform: {undefined: Null},
      max: 2,
      // debug: (~connection, ~query, ~params as _, ~types as _) => Js.log2(connection, query),
    },
  )
}

let publicSchema = Env.Db.publicSchema

let allEntityTables: array<Table.table> = Entities.allEntities->Belt.Array.map(entityConfig => {
  entityConfig.table
})

let schema = Schema.make(allEntityTables)
