@@warning("-21")
let resetPostgresClient: unit => unit = () => {
  // This is a hack to reset the postgres client between tests. postgres.js seems to cache some types, and if tests clear the DB you need to also reset the storage.
  let sql = Db.makeClient()
  Generated.codegenPersistence.storage = Generated.makeStorage(~sql)
}

let runUpDownMigration = async () => {
  resetPostgresClient()
  (await Migrations.runUpMigrations(~shouldExit=false, ~reset=true))->ignore
}
