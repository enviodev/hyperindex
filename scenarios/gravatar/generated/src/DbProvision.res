let pool = DrizzleOrm.Pool.make(
  ~config={
    host: "127.0.0.1",
    port: 5433,
    user: "postgres",
    password: "testing",
    database: "indexly-dev",
  },
)

%%private(let db = DrizzleOrm.Drizzle.make(~pool))

let migrateDb = () =>
  DrizzleOrm.Drizzle.migrate(db, {migrationsFolder: "generated/migrations-folder"})

let getDb = async () => {
  // TODO: make this only migrate once, rather than every time.
  await migrateDb()
  db
}
