let pool = DrizzleOrm.Pool.make(~config=Config.db)

%%private(let db = DrizzleOrm.Drizzle.make(~pool))

let migrateDb = () => DrizzleOrm.Drizzle.migrate(db, {migrationsFolder: "./generated/migrations-folder"})

let getDb = async () => {
  db
}
