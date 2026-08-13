/**
 * Direct Postgres access, for tests that run without Hasura.
 *
 * `runPgSql` goes through Hasura's `run_sql`, which needs the Hasura container.
 * The ClickHouse parity test only needs Postgres and ClickHouse, so it talks to
 * Postgres itself and stays runnable on a machine with no Docker.
 */

import postgres from "postgres";

const env = (name: string, fallback: string) => process.env[name] ?? fallback;

let sql: ReturnType<typeof postgres> | null = null;

export function pg() {
  if (!sql) {
    sql = postgres({
      host: env("ENVIO_PG_HOST", "localhost"),
      port: Number(env("ENVIO_PG_PORT", "5433")),
      username: env("ENVIO_PG_USER", "postgres"),
      password: env("ENVIO_PG_PASSWORD", "testing"),
      database: env("ENVIO_PG_DATABASE", "envio-dev"),
      // Values are compared against ClickHouse's text output, so keep whatever
      // the driver gives and stringify at the comparison site.
      max: 2,
      onnotice: () => {},
    });
  }
  return sql;
}

/** Rows as arrays of column values, in the order the SELECT lists them. */
export async function pgRows(query: string): Promise<unknown[][]> {
  const result = await pg().unsafe(query);
  return result.map((row) => Object.values(row));
}

export async function closePg(): Promise<void> {
  if (sql) {
    await sql.end();
    sql = null;
  }
}

/** True when Postgres accepts a connection. */
export async function isPgReachable(): Promise<boolean> {
  try {
    await pg().unsafe("SELECT 1");
    return true;
  } catch {
    return false;
  }
}
