let sql = Postgres.makeSql(~config=Config.db->Obj.magic /* TODO: make this have the correct type */)

module RawEventsTable = {
  let createRawEventsTable: unit => promise<unit> = async () => {
    @warning("-21")
    let _ = await %raw("sql`
      CREATE TYPE EVENT_TYPE AS ENUM (
      'GravatarContract_TestEventEvent',
      'GravatarContract_NewGravatarEvent',
      'GravatarContract_UpdatedGravatarEvent'
      
      );
      `")

    @warning("-21")
    let _ = await %raw("sql`
      CREATE TABLE public.raw_events (
        chain_id INTEGER NOT NULL,
        event_id NUMERIC NOT NULL,
        block_number INTEGER NOT NULL,
        log_index INTEGER NOT NULL,
        transaction_index INTEGER NOT NULL,
        transaction_hash TEXT NOT NULL,
        src_address TEXT NOT NULL,
        block_hash TEXT NOT NULL,
        block_timestamp INTEGER NOT NULL,
        event_type EVENT_TYPE NOT NULL,
        params JSON NOT NULL,
        PRIMARY KEY (chain_id, event_id)
      );
      `")
  }

  let dropRawEventsTable = async () => {
    await %raw("sql`
    DROP TABLE public.raw_events;
  `")
  }
}

module User = {
  let createUserTable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE \"public\".\"user\" (\"id\" text  NOT NULL,\"address\" text  NOT NULL,\"gravatar\" text,UNIQUE (\"id\"));`"
    )
  }

  let deleteUserTable: unit => promise<unit> = async () => {
    // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
    await %raw("sql`DROP TABLE IF EXISTS \"public\".\"user\";`")
  }
}

module Gravatar = {
  let createGravatarTable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE \"public\".\"gravatar\" (\"id\" text  NOT NULL,\"owner\" text  NOT NULL,\"displayName\" text  NOT NULL,\"imageUrl\" text  NOT NULL,\"updatesCount\" integer  NOT NULL,UNIQUE (\"id\"));`"
    )
  }

  let deleteGravatarTable: unit => promise<unit> = async () => {
    // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
    await %raw("sql`DROP TABLE IF EXISTS \"public\".\"gravatar\";`")
  }
}

let deleteAllTables: unit => promise<unit> = async () => {
  // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).

  @warning("-21")
  await (
    %raw(
      "sql.unsafe`DROP SCHEMA public CASCADE;CREATE SCHEMA public;GRANT ALL ON SCHEMA public TO postgres;GRANT ALL ON SCHEMA public TO public;`"
    )
  )
}

type t
@module external process: t = "process"

@send external exit: (t, unit) => unit = "exit"

// TODO: all the migration steps should run as a single transaction
let runUpMigrations = async () => {
  await RawEventsTable.createRawEventsTable()
  // TODO: catch and handle query errors
  await User.createUserTable()
  await Gravatar.createGravatarTable()
}

let runDownMigrations = async () => {
  //
  // await User.deleteUserTable()
  //
  // await Gravatar.deleteGravatarTable()
  //

  // NOTE: For now delete any remaining tables.
  await deleteAllTables()
}

let setupDb = async () => {
  // TODO: we should make a hash of the schema file (that gets stored in the DB) and either drop the tables and create new ones or keep this migration.
  //       for now we always run the down migration.
  // if (process.env.MIGRATE === "force" || hash_of_schema_file !== hash_of_current_schema)
  await runDownMigrations()
  // else
  //   await clearDb()

  await runUpMigrations()

  process->exit()
}
