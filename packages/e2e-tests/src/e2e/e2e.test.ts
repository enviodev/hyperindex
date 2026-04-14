/**
 * E2E Indexer Test
 *
 * Tests the full indexer flow with database and ClickHouse sink:
 * 1. Ensure ClickHouse is running (CI service or local container)
 * 2. Start `envio dev` in background with ClickHouse sink enabled
 * 3. Wait for "All chains are caught up to end blocks" in stdout
 * 4. Verify GraphQL queries return expected data
 * 5. Verify ClickHouse sink received the indexed data
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { ChildProcess } from "child_process";
import { config } from "../config.js";
import {
  startBackground,
  waitForOutput,
  killProcessOnPort,
  runCommand,
} from "../utils/process.js";
import { GraphQLClient } from "../utils/graphql.js";
import {
  ensureClickHouse,
  stopClickHouse,
  queryClickHouse,
} from "../utils/clickhouse.js";
import path from "path";

const PROJECT_DIR = path.join(config.scenariosDir, "e2e_test");
const CH_DATABASE = "envio_sink";

interface ClickHouseResult<T> {
  data: T[];
  rows: number;
}

describe("E2E: Indexer with GraphQL and ClickHouse sink", () => {
  let indexerProcess: ChildProcess | null = null;
  let graphql: GraphQLClient;

  beforeAll(async () => {
    graphql = new GraphQLClient({
      endpoint: config.graphqlEndpoint,
      adminSecret: config.hasuraAdminSecret,
    });

    await ensureClickHouse();
    await killProcessOnPort(config.indexerPort);

    // envio dev handles codegen, pnpm install, rescript build, migrations, and indexer start
    indexerProcess = startBackground(config.envioCommand, [...config.envioArgs, "dev"], {
      cwd: PROJECT_DIR,
      env: {
        TUI_OFF: "true",
        ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
        ENVIO_CLICKHOUSE_HOST: config.clickhouseUrl,
        ENVIO_CLICKHOUSE_USERNAME: config.clickhouseUsername,
        ENVIO_CLICKHOUSE_PASSWORD: config.clickhousePassword,
        // First run: no DB state yet, fallback returns the config endBlock
        E2E_EXPECTED_END_BLOCK: "10861774",
      },
    });

    await waitForOutput(
      indexerProcess,
      "All chains are caught up to end blocks",
      120_000
    );

    // Kill immediately so envio dev doesn't tear down docker before tests query it.
    // The "Exiting with success" → process.exit(0) path runs docker compose down.
    indexerProcess.kill("SIGKILL");
    indexerProcess = null;
  }, 300_000); // 5 min for codegen + install + build + indexer startup

  afterAll(async () => {
    if (indexerProcess) {
      indexerProcess.kill("SIGTERM");
      indexerProcess = null;
    }
    await killProcessOnPort(config.indexerPort);
    await runCommand(config.envioCommand, [...config.envioArgs, "stop"], {
      cwd: PROJECT_DIR,
      timeout: 30000,
    }).catch(() => {});
    await stopClickHouse();
  }, 30_000);

  it("should have _meta with isReady true", async () => {
    // Chain metadata uses a throttled DB write, so poll briefly
    const result = await graphql.poll<{
      _meta: Array<{ chainId: number; isReady: boolean }>;
    }>({
      query: `{ _meta { chainId isReady } }`,
      validate: (data) =>
        data._meta?.length > 0 && data._meta.every((m) => m.isReady),
      maxAttempts: 10,
      timeoutMs: 5_000,
    });

    expect(result.success).toBe(true);
    expect(result.data?._meta).toEqual([{ chainId: 1, isReady: true }]);
  });

  it("should have Transfer entities indexed", async () => {
    const result = await graphql.poll<{
      Transfer: Array<{
        id: string;
        from: string;
        to: string;
        value: string;
        blockNumber: number;
        transactionHash: string;
      }>;
    }>({
      query: `{
        Transfer(limit: 10) {
          id from to value blockNumber transactionHash
        }
      }`,
      validate: (data) => data.Transfer?.length > 0,
      maxAttempts: 10,
      timeoutMs: 5_000,
    });

    expect(result.success).toBe(true);
    const transfer = result.data?.Transfer[0];
    expect(transfer).toMatchObject({
      id: expect.any(String),
      from: expect.any(String),
      to: expect.any(String),
      blockNumber: expect.any(Number),
      transactionHash: expect.any(String),
    });
  });

  it("should be able to query GraphQL schema", async () => {
    const result = await graphql.query<{
      __schema: { queryType: { name: string } };
    }>(`{ __schema { queryType { name } } }`);

    expect(result.data?.__schema.queryType.name).toBe("query_root");
  });

  it("should have Transfer data in ClickHouse sink view", async () => {
    const result = await queryClickHouse<
      ClickHouseResult<{
        id: string;
        from: string;
        to: string;
        value: string;
        blockNumber: number;
        transactionHash: string;
      }>
    >(`SELECT * FROM ${CH_DATABASE}.Transfer LIMIT 10`);

    expect(result.rows).toBeGreaterThan(0);
    expect(result.data[0]).toMatchObject({
      id: expect.any(String),
      from: expect.any(String),
      to: expect.any(String),
      blockNumber: expect.any(Number),
      transactionHash: expect.any(String),
    });
  });

  it("should have checkpoints in ClickHouse sink", async () => {
    const result = await queryClickHouse<
      ClickHouseResult<{
        id: string;
        chain_id: number;
        block_number: number;
      }>
    >(`SELECT * FROM ${CH_DATABASE}.envio_checkpoints`);

    expect(result.rows).toBeGreaterThan(0);
    expect(result.data[0]).toMatchObject({
      chain_id: 1,
      block_number: expect.any(Number),
    });

    const maxBlock = Math.max(...result.data.map((r) => r.block_number));
    expect(maxBlock).toBeGreaterThan(0);
  });

  it("should have entity history in ClickHouse sink", async () => {
    const result = await queryClickHouse<
      ClickHouseResult<{
        id: string;
        envio_change: string;
        envio_checkpoint_id: string;
      }>
    >(
      `SELECT * FROM ${CH_DATABASE}.\`envio_history_Transfer\` LIMIT 10`
    );

    expect(result.rows).toBeGreaterThan(0);
    expect(result.data[0]).toMatchObject({
      id: expect.any(String),
      envio_change: "SET",
    });
  });

  it("should resume with DB state on second start", async () => {
    const patchedEndBlock = 10861775; // original 10861774 + 1

    // Patch envio_chains.end_block via Hasura run_sql
    const sqlRes = await fetch(`http://localhost:${config.hasuraPort}/v2/query`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-hasura-admin-secret": config.hasuraAdminSecret,
      },
      body: JSON.stringify({
        type: "run_sql",
        args: {
          sql: `UPDATE public.envio_chains SET end_block = ${patchedEndBlock} WHERE id = 1`,
        },
      }),
    });
    expect(sqlRes.ok).toBe(true);

    await killProcessOnPort(config.indexerPort);

    let secondProcess: ChildProcess | null = null;
    try {
      secondProcess = startBackground(config.envioCommand, [...config.envioArgs, "dev"], {
        cwd: PROJECT_DIR,
        env: {
          TUI_OFF: "true",
          ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
          ENVIO_CLICKHOUSE_SINK_HOST: config.clickhouseUrl,
          ENVIO_CLICKHOUSE_SINK_USERNAME: config.clickhouseUsername,
          ENVIO_CLICKHOUSE_SINK_PASSWORD: config.clickhousePassword,
          E2E_EXPECTED_END_BLOCK: String(patchedEndBlock),
        },
      });

      // If the handler's endBlock check fails, the indexer crashes and
      // waitForOutput rejects. Success means DB state was used.
      await waitForOutput(
        secondProcess,
        "All chains are caught up to end blocks",
        120_000
      );
    } finally {
      if (secondProcess) {
        secondProcess.kill("SIGKILL");
      }
    }
  }, 180_000);
});
