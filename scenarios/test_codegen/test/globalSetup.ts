import * as PgStorage from "envio/src/PgStorage.res.mjs";
import * as TestPgSchema from "envio-tests/test/helpers/TestPgSchema.res.mjs";

// A worker killed mid-test leaves its schema behind. Collect the old ones once,
// before any worker starts, so they can't pile up in a developer's database.
export default async function setup(): Promise<void> {
  const sql = PgStorage.makeClient();
  try {
    await TestPgSchema.sweep(sql);
  } finally {
    await sql.end();
  }
}
