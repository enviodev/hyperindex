type sql

type poolConfig = {
  host: string,
  port: int,
  user: string,
  password: string,
  database: string,
  onnotice: option<unit => unit>,
}

@module
external makeSql: (~config: poolConfig) => sql = "postgres"

// TODO: can explore this approach (https://forum.rescript-lang.org/t/rfc-support-for-tagged-template-literals/3744)
// @send @variadic
// external sql:  array<string>  => (sql, array<string>) => int = "sql"
