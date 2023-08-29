type sql

type undefinedOpaque
type transformConfig = {undefined: Js.Null.t<undefinedOpaque>}
type poolConfig = {
  host: string,
  port: int,
  user: string,
  password: string,
  database: string,
  ssl: string,
  onnotice: option<unit => unit>,
  transform?: transformConfig,
}

@module
external makeSql: (~config: poolConfig) => sql = "postgres"

@send external beginSql: (sql, sql => array<promise<unit>>) => promise<unit> = "begin"

// TODO: can explore this approach (https://forum.rescript-lang.org/t/rfc-support-for-tagged-template-literals/3744)
// @send @variadic
// external sql:  array<string>  => (sql, array<string>) => int = "sql"
