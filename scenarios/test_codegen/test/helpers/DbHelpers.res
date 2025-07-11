let _sqlConfig = Db.config

@@warning("-21")
let resetPostgresClient: unit => unit = () => {
  // This is a hack to reset the postgres client between tests. postgres.js seems to cache some types, and if tests clear the DB you need to also reset sql.
  %raw("require('../../generated/src/db/Db.res.js').sql = require('postgres')(_sqlConfig)")
}

let runUpDownMigration = async () => {
  resetPostgresClient()
  (await Migrations.runUpMigrations(~shouldExit=false, ~reset=true))->ignore
}
