// The two calls whose shape differs between this branch and the commit the
// benchmark compares against. Everything else in the benchmark is the same
// source on both sides.

let close = sql => sql->Sql.close

let query = (sql, statement): promise<array<unknown>> => sql->Sql.query(statement)
