let pool = DrizzleOrm.Pool.make(~config=Config.db)

%%private(let db = DrizzleOrm.Drizzle.make(~pool))

let migrateDb = () =>
  DrizzleOrm.Drizzle.migrate(db, {migrationsFolder: "./generated/migrations-folder"})

let getDb = async () => {
  // TODO: make this only migrate once, rather than every time.
  await migrateDb()
  db
}
