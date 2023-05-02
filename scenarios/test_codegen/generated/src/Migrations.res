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
  external makeSql: (~config: poolConfig) => sql = "postgres"

  // TODO: can explore this approach (https://forum.rescript-lang.org/t/rfc-support-for-tagged-template-literals/3744)
  // @send @variadic
  // external sql:  array<string>  => (sql, array<string>) => int = "sql"
}

let sql = Postgres.makeSql(~config=Config.db->Obj.magic /* TODO: make this have the correct type */)

module User = {
  let createUserTable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE public.usertest (id text  NOT NULL,address text  NOT NULL,gravatar text,UNIQUE (id));`"
    )
  }
}

// TODO: catch and handle query errors
User.createUserTable()->ignore

module Gravatar = {
  let createGravatarTable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE public.gravatartest (id text  NOT NULL,owner text  NOT NULL,displayName text  NOT NULL,imageUrl text  NOT NULL,updatesCount integer  NOT NULL,UNIQUE (id));`"
    )
  }
}

// TODO: catch and handle query errors
Gravatar.createGravatarTable()->ignore

// TODO: all the migration steps should run as a single transaction
// TODO: we should make a hash of the schema file and either drop the tables and create new ones or keep this migration.
