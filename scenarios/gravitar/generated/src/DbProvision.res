let pool = DrizzleOrm.Pool.make(
  ~config={
    host: "127.0.0.1",
    port: 5433,
    user: "postgres",
    password: "testing",
    database: "indexly-dev",
  },
)

let db = DrizzleOrm.Drizzle.make(~pool)

DrizzleOrm.Drizzle.migrate(db, {migrationsFolder: "./migrations-folder"})->ignore
