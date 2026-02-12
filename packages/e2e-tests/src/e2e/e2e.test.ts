/**
 * E2E Indexer Test
 *
 * Tests the full indexer flow with database:
 * 1. Use erc20_multichain_factory scenario
 * 2. Start indexer with pnpm dev
 * 3. Verify GraphQL queries return expected data
 *
 * Requires Postgres and Hasura to be running (via docker-compose or CI services)
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { ChildProcess } from "child_process";
import { config } from "../config.js";
import {
  startBackground,
  killProcessOnPort,
  runCommand,
} from "../utils/process.js";
import { waitForIndexer, waitForHasura } from "../utils/health.js";
import { GraphQLClient } from "../utils/graphql.js";
import path from "path";

// Use dedicated e2e_test scenario
const PROJECT_DIR = path.join(config.scenariosDir, "e2e_test");

// Get envio binary path
const ENVIO_BIN = path.join(
  config.rootDir,
  "codegenerator/target/release/envio"
);

describe("E2E: Indexer with GraphQL", () => {
  let indexerProcess: ChildProcess | null = null;
  let graphql: GraphQLClient;

  beforeAll(async () => {
    graphql = new GraphQLClient({
      endpoint: config.graphqlEndpoint,
      adminSecret: config.hasuraAdminSecret,
    });

    // Ensure Hasura is ready (should be started by CI or docker-compose)
    const hasuraHealth = await waitForHasura(config.hasuraPort, 60);
    if (!hasuraHealth.success) {
      throw new Error(
        `Hasura not available at port ${config.hasuraPort}. ` +
          "Make sure docker-compose is running or CI services are configured."
      );
    }

    // Kill any existing indexer on the port
    await killProcessOnPort(config.indexerPort);

    // Start the indexer
    indexerProcess = startBackground("pnpm", ["dev"], {
      cwd: PROJECT_DIR,
      env: {
        TUI_OFF: "true",
        ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
      },
    });

    // Wait for indexer to be healthy
    const indexerHealth = await waitForIndexer(
      config.indexerPort,
      config.timeouts.indexerStartup / 1000
    );

    if (!indexerHealth.success) {
      throw new Error(
        `Indexer health check failed after ${indexerHealth.attempts} attempts`
      );
    }
  }, config.timeouts.indexerStartup + 30000);

  afterAll(async () => {
    // Stop the indexer
    if (indexerProcess) {
      indexerProcess.kill("SIGTERM");
      indexerProcess = null;
    }

    await killProcessOnPort(config.indexerPort);

    // Clean up docker
    await runCommand(ENVIO_BIN, ["stop"], {
      cwd: PROJECT_DIR,
      timeout: 30000,
    }).catch(() => {});
  });

  it("should have _meta populated", async () => {
    interface MetaResponse {
      _meta: Array<{
        chainId: number;
        progressBlock: number;
        eventsProcessed: number;
        isReady: boolean;
        startBlock: number;
      }>;
    }

    const result = await graphql.poll<MetaResponse>({
      query: `
        {
          _meta {
            chainId
            progressBlock
            eventsProcessed
            bufferBlock
            firstEventBlock
            sourceBlock
            readyAt
            isReady
            startBlock
            endBlock
          }
        }
      `,
      validate: (data) => {
        return data._meta && data._meta.length > 0;
      },
      maxAttempts: config.retry.maxPollAttempts,
      timeoutMs: config.timeouts.test,
    });

    expect(result.success).toBe(true);
    expect(result.data?._meta).toBeDefined();
    expect(result.data?._meta.length).toBeGreaterThan(0);
    expect(result.data?._meta[0].chainId).toBe(1);
  });

  it("should have Transfer entities indexed", async () => {
    interface TransferResponse {
      Transfer: Array<{
        id: string;
        from: string;
        to: string;
        value: string;
        blockNumber: number;
        transactionHash: string;
      }>;
    }

    const result = await graphql.poll<TransferResponse>({
      query: `
        {
          Transfer(limit: 10) {
            id
            from
            to
            value
            blockNumber
            transactionHash
          }
        }
      `,
      validate: (data) => {
        return data.Transfer && data.Transfer.length > 0;
      },
      maxAttempts: config.retry.maxPollAttempts,
      timeoutMs: config.timeouts.test,
    });

    expect(result.success).toBe(true);
    expect(result.data?.Transfer).toBeDefined();
    expect(result.data?.Transfer.length).toBeGreaterThan(0);
    // Verify Transfer entity structure
    const transfer = result.data?.Transfer[0];
    expect(transfer?.id).toBeDefined();
    expect(transfer?.from).toBeDefined();
    expect(transfer?.to).toBeDefined();
    expect(transfer?.blockNumber).toBeGreaterThanOrEqual(0);
  });

  it("should be able to query GraphQL schema", async () => {
    const result = await graphql.poll({
      query: `
        {
          __schema {
            queryType {
              name
            }
          }
        }
      `,
      validate: (data: { __schema: { queryType: { name: string } } }) => {
        return data.__schema?.queryType?.name === "query_root";
      },
      maxAttempts: 10,
      timeoutMs: 30000,
    });

    expect(result.success).toBe(true);
  });
});
