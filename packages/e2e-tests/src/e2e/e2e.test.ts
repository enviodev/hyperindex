/**
 * E2E Indexer Test
 *
 * Tests the full indexer flow with database:
 * 1. Start `envio dev` in background
 * 2. Wait for "All chains are caught up to end blocks" in stdout
 * 3. Verify GraphQL queries return expected data
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
import path from "path";

const PROJECT_DIR = path.join(config.scenariosDir, "e2e_test");

describe("E2E: Indexer with GraphQL", () => {
  let indexerProcess: ChildProcess | null = null;
  let graphql: GraphQLClient;

  beforeAll(async () => {
    graphql = new GraphQLClient({
      endpoint: config.graphqlEndpoint,
      adminSecret: config.hasuraAdminSecret,
    });

    await killProcessOnPort(config.indexerPort);

    indexerProcess = startBackground(config.envioBin, ["dev"], {
      cwd: PROJECT_DIR,
      env: {
        TUI_OFF: "true",
        ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
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
  }, 120_000);

  afterAll(async () => {
    if (indexerProcess) {
      indexerProcess.kill("SIGTERM");
      indexerProcess = null;
    }
    await killProcessOnPort(config.indexerPort);
    await runCommand(config.envioBin, ["stop"], {
      cwd: PROJECT_DIR,
      timeout: 30000,
    }).catch(() => {});
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
});
