module General = {
  type existsRes = {exists: bool}

  let hasRows = async (sql, ~table: Table.table) => {
    let query = `SELECT EXISTS(SELECT 1 FROM "${Env.Db.publicSchema}"."${table.tableName}");`
    switch await sql->Postgres.unsafe(query) {
    | [{exists}] => exists
    | _ => Js.Exn.raiseError("Unexpected result from hasRows query: " ++ query)
    }
  }
}

module EntityHistory = {
  let hasRows = async sql => {
    let all =
      await Entities.allEntities
      ->Belt.Array.map(async entityConfig => {
        try await General.hasRows(sql, ~table=entityConfig.entityHistory.table) catch {
        | exn =>
          exn->ErrorHandling.mkLogAndRaise(
            ~msg=`Failed to check if entity history table has rows`,
            ~logger=Logging.createChild(
              ~params={
                "entityName": entityConfig.name,
              },
            ),
          )
        }
      })
      ->Promise.all
    all->Belt.Array.some(v => v)
  }
}
