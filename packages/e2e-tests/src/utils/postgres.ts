/**
 * Run a SQL statement against the Postgres backing the indexer.
 *
 * Uses the Hasura admin `/v2/query` `run_sql` endpoint so no `pg` client
 * dependency is needed and the auth path matches the existing e2e helpers.
 */

import { config } from "../config.js";

interface RunSqlResponse {
  result_type: "TuplesOk" | "CommandOk" | string;
  result?: string[][];
}

/**
 * Execute a SELECT statement and return rows as `string[][]`. The first
 * element of `result` from Hasura is the column-name header row; this
 * helper strips it so callers get just the data rows.
 *
 * For non-SELECT statements (DDL, UPDATE, etc.) Hasura returns
 * `result_type: "CommandOk"` with no `result` — callers get `[]`.
 */
export async function runPgSql(sql: string): Promise<string[][]> {
  const res = await fetch(
    `http://localhost:${config.hasuraPort}/v2/query`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-hasura-admin-secret": config.hasuraAdminSecret,
      },
      body: JSON.stringify({ type: "run_sql", args: { sql } }),
    }
  );

  if (!res.ok) {
    throw new Error(`run_sql failed (${res.status}): ${await res.text()}`);
  }

  const body = (await res.json()) as RunSqlResponse;
  if (!body.result || body.result.length < 1) return [];
  // Skip the column-name header row.
  return body.result.slice(1);
}
