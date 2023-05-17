let sql = Postgres.makeSql(~config=Config.db->Obj.magic /* TODO: make this have the correct type */)

module RawEventsTable = {
  let createRawEventsTable: unit => promise<unit> = async () => {
    @warning("-21")
    let _ = await (
      %raw("sql`
      CREATE TYPE EVENT_TYPE AS ENUM (
      {{#each contracts as | contract |}}
      {{#each contract.events as | event |}}
      '{{contract.name.capitalized}}Contract_{{event.name.capitalized}}Event'
      {{/each}}
      {{#unless @last}},{{/unless}}
      {{/each}}
      );
      `")
    )
    @warning("-21")
    let _ = await (
      %raw("sql`
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
    )
  }

  let dropRawEventsTable = async () => {
    await %raw("sql`
    DROP TABLE public.raw_events;
  `")
  }
}

{{#each entities as |entity|}}
module {{entity.name.capitalized}} = {
  let create{{entity.name.capitalized}}Table:unit => promise<unit> = async () => {
    await %raw("sql`CREATE TABLE \"public\".\"{{entity.name.uncapitalized}}\" ({{#each entity.params as |param|}}\"{{param.key}}\" {{param.type_pg}},{{/each}}UNIQUE (\"id\"));`")
  }

  let delete{{entity.name.capitalized}}Table:unit => promise<unit> = async () => {
    // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
    await %raw("sql`DROP TABLE IF EXISTS \"public\".\"{{entity.name.uncapitalized}}\";`")
  }
}

{{/each}}

let deleteAllTables:unit => promise<unit> = async () => {
  // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
  @warning("-21")
  await %raw("sql.unsafe`DROP SCHEMA public CASCADE;CREATE SCHEMA public;GRANT ALL ON SCHEMA public TO postgres;GRANT ALL ON SCHEMA public TO public;`")
}

type t
@module external process: t = "process"

@send external exit: (t, unit) => unit = "exit"

// TODO: all the migration steps should run as a single transaction
let runUpMigrations = async () => {
  await RawEventsTable.createRawEventsTable()
// TODO: catch and handle query errors
{{#each entities as |entity|}}
  await {{entity.name.capitalized}}.create{{entity.name.capitalized}}Table()
{{/each}}

}

let runDownMigrations = async () => {
  // {{#each entities as |entity|}}
  // await {{entity.name.capitalized}}.delete{{entity.name.capitalized}}Table()
  // {{/each}}

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
