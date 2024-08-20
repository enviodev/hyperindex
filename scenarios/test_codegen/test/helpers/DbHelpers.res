let _sqlConfig = DbFunctions.config

@@warning("-21")
let resetPostgresClient: unit => unit = () => {
  // This is a hack to reset the postgres client between tests. postgres.js seems to cache some types, and if tests clear the DB you need to also reset sql.
  %raw(
    "require('../../generated/src/db/DbFunctions.bs.js').sql = require('postgres')(_sqlConfig)"
  )
}

let runUpDownMigration = async () => {
  resetPostgresClient()
  (await Migrations.runDownMigrations(~shouldExit=false, ~shouldDropRawEvents=true))->ignore
  (await Migrations.runUpMigrations(~shouldExit=false))->ignore
}
