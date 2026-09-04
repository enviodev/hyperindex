/**
 * Direct Postgres access, for tests that run without Hasura.
 *
 * `runPgSql` goes through Hasura's `run_sql`, which needs the Hasura container.
 * The ClickHouse parity test only needs Postgres and ClickHouse, so it talks to
 * Postgres itself and stays runnable on a machine with no Docker.
 */

import postgres from "postgres";

import { config } from "../config.js";

let sql: ReturnType<typeof postgres> | null = null;

export function pg() {
  if (!sql) {
    sql = postgres({
      host: config.pgHost,
      port: config.pgPort,
      username: config.pgUser,
      password: config.pgPassword,
      database: config.pgDatabase,
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

export async function isPgReachable(): Promise<boolean> {
  try {
    await pg().unsafe("SELECT 1");
    return true;
  } catch {
    return false;
  }
}
