let pool = DrizzleOrm.Pool.make(
  ~config={
    // TODO: use proper environment variables with defaults.
    host: "postgres",
    port: 5432,
    user: "postgres",
    password: "testing",
    database: "indexly-dev",
  },
)

%%private(let db = DrizzleOrm.Drizzle.make(~pool))

let migrateDb = () => DrizzleOrm.Drizzle.migrate(db, {migrationsFolder: "./migrations-folder"})

let getDb = async () => {
  // TODO: make this only migrate once, rather than every time.
  await migrateDb()
  db
}
