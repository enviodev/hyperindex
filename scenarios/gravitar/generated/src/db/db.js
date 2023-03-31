const { pgTable, serial, text, varchar } = require("drizzle-orm/pg-core");
const { drizzle } = require("drizzle-orm/node-postgres");
const { migrate } = require("drizzle-orm/node-postgres/migrator");
const { Pool } = require("pg");
const { gravatar } = require("./schema");

// const pool = new Pool({
//   connectionString: 'postgres://user:password@host:port/db',
// });
// // or
const pool = new Pool({
  host: "127.0.0.1",
  port: 5433,
  user: "postgres",
  password: "testing",
  database: "indexly-dev",
});

async function main() {
  const db = drizzle(pool);
  await migrate(db, { migrationsFolder: "./migrations-folder" });
  // await db.insert(users).values({
  //   id: 123,
  //   fullName: "Jason Smythe",
  //   phone: "555-555-5555",
  // });
  // await db.insert(users).values({
  //   id: 124,
  //   fullName: "Jono Prest",
  //   phone: "555-555-5555",
  // });
  console.log("inserted user")
  const allUsers = await db.select().from(gravatar);

  console.log("all users", allUsers);
}

main();
