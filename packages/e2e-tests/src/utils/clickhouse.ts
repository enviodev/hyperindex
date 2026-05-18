/**
 * ClickHouse Docker container management and query utilities.
 *
 * Uses the ClickHouse HTTP interface (port 8123) with plain fetch(),
 * so no additional npm dependencies are needed.
 */

import { exec } from "child_process";
import { promisify } from "util";
import { config } from "../config.js";

const execAsync = promisify(exec);

const CLICKHOUSE_IMAGE = "clickhouse/clickhouse-server:latest";

/**
 * Query ClickHouse via its HTTP interface.
 * Returns parsed JSON for SELECT queries.
 */
export async function queryClickHouse<T = unknown>(sql: string): Promise<T> {
  const auth = Buffer.from(
    `${config.clickhouseUsername}:${config.clickhousePassword}`
  ).toString("base64");
  const url = `${config.clickhouseUrl}/?default_format=JSON`;
  const response = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Basic ${auth}` },
    body: sql,
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`ClickHouse query failed (${response.status}): ${text}`);
  }

  return response.json() as Promise<T>;
}

/**
 * Check if ClickHouse is reachable by hitting its ping endpoint.
 */
async function isClickHouseReachable(): Promise<boolean> {
  try {
    const response = await fetch(`${config.clickhouseUrl}/ping`, {
      signal: AbortSignal.timeout(2000),
    });
    return response.ok;
  } catch {
    return false;
  }
}

/**
 * Wait for ClickHouse to become ready, polling every 500ms.
 */
async function waitForReady(timeoutMs = 30_000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await isClickHouseReachable()) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`ClickHouse did not become ready within ${timeoutMs}ms`);
}

/**
 * Ensure a ClickHouse container is running.
 * If already reachable (e.g. CI service container), skips docker run.
 */
export async function ensureClickHouse(): Promise<void> {
  if (await isClickHouseReachable()) {
    console.log(
      `ClickHouse already reachable on port ${config.clickhousePort}, skipping container`
    );
    return;
  }

  console.log("Starting ClickHouse container...");

  // Remove any stale container with the same name
  await execAsync(`docker rm -f ${config.clickhouseContainer}`).catch(
    () => {}
  );

  await execAsync(
    `docker run -d --name ${config.clickhouseContainer} ` +
      `-p ${config.clickhousePort}:8123 ` +
      `-e CLICKHOUSE_PASSWORD=${config.clickhousePassword} ` +
      `${CLICKHOUSE_IMAGE}`
  );

  await waitForReady();
  console.log("ClickHouse is ready");
}

/**
 * Stop and remove the ClickHouse container.
 */
export async function stopClickHouse(): Promise<void> {
  await execAsync(`docker rm -f ${config.clickhouseContainer}`).catch(
    () => {}
  );
}
