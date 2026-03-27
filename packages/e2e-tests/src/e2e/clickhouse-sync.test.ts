/**
 * E2E ClickHouse Sink Test
 *
 * Verifies that the ClickHouse secondary sink receives data when enabled:
 * 1. Start ClickHouse container (or reuse CI service)
 * 2. Start `envio dev` with ClickHouse sink env vars
 * 3. Wait for indexing to complete
 * 4. Query ClickHouse directly to verify synced data
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

describe("E2E: ClickHouse Sink", () => {
  let indexerProcess: ChildProcess | null = null;

  beforeAll(async () => {
    await ensureClickHouse();
    await killProcessOnPort(config.indexerPort);

    indexerProcess = startBackground(
      config.envioCommand,
      [...config.envioArgs, "dev"],
      {
        cwd: PROJECT_DIR,
        env: {
          TUI_OFF: "true",
          ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
          ENVIO_CLICKHOUSE_SINK_HOST: config.clickhouseUrl,
          ENVIO_CLICKHOUSE_SINK_USERNAME: "default",
          ENVIO_CLICKHOUSE_SINK_PASSWORD: "",
        },
      }
    );

    await waitForOutput(
      indexerProcess,
      "All chains are caught up to end blocks",
      120_000
    );

    // Kill immediately so envio dev doesn't tear down docker before tests query it.
    indexerProcess.kill("SIGKILL");
    indexerProcess = null;
  }, 300_000);

  afterAll(async () => {
    if (indexerProcess) {
      indexerProcess.kill("SIGTERM");
      indexerProcess = null;
    }
    await killProcessOnPort(config.indexerPort);
    await runCommand(config.envioCommand, [...config.envioArgs, "stop"], {
      cwd: PROJECT_DIR,
      timeout: 30_000,
    }).catch(() => {});
    await stopClickHouse();
  }, 30_000);

  it("should have Transfer data in ClickHouse view", async () => {
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

  it("should have checkpoints in ClickHouse", async () => {
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

  it("should have entity history in ClickHouse", async () => {
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
});
