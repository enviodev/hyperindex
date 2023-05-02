// TODO - put common bindings into bindings folder:
module Postgres = {
  type sql

  type poolConfig = {
    host: string,
    port: int,
    user: string,
    password: string,
    database: string,
  }

  @module
  external makeSql: (~config: poolConfig) => sql= "postgres"

  // TODO: can explore this approach (https://forum.rescript-lang.org/t/rfc-support-for-tagged-template-literals/3744)
  // @send @variadic
  // external sql:  array<string>  => (sql, array<string>) => int = "sql"
}

let sql = Postgres.makeSql(~config=Config.db->Obj.magic /* TODO: make this have the correct type */)

{{#each entities as |entity|}}
module {{entity.name.capitalized}} = {
  let create{{entity.name.capitalized}}Table:unit => promise<unit> = async () => {
    await %raw("sql`CREATE TABLE public.{{entity.name.uncapitalized}}test ({{#each entity.params as |param|}}{{param.key}} {{param.type_pg}},{{/each}}UNIQUE (id));`")
  }
}

// TODO: catch and handle query errors
{{entity.name.capitalized}}.create{{entity.name.capitalized}}Table()->ignore

{{/each}}

// TODO: all the migration steps should run as a single transaction
// TODO: we should make a hash of the schema file and either drop the tables and create new ones or keep this migration.
