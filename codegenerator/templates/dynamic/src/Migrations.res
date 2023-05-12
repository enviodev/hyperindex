let sql = Postgres.makeSql(~config=Config.db->Obj.magic /* TODO: make this have the correct type */)

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

@@warning("-21")
let deleteAllTables:unit => promise<unit> = async () => {
  // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
  await %raw("sql`DROP SCHEMA public CASCADE;`")
  await %raw("sql`CREATE SCHEMA public;`")
  await %raw("sql`GRANT ALL ON SCHEMA public TO postgres;`")
  await %raw("sql`GRANT ALL ON SCHEMA public TO public;`")
}
@@warning("+21")

type t
@module external process: t = "process"

@send external exit: (t, unit) => unit = "exit"

// TODO: all the migration steps should run as a single transaction
let runUpMigrations = async () => {
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
