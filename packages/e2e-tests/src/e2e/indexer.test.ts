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

// Use existing scenario
const PROJECT_DIR = path.join(config.scenariosDir, "erc20_multichain_factory");

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

  it("should have chain_metadata populated", async () => {
    const result = await graphql.poll({
      query: `
        {
          chain_metadata {
            chain_id
            start_block
            block_height
            is_hyper_sync
            num_batches_fetched
          }
        }
      `,
      validate: (data: { chain_metadata: Array<{ chain_id: number }> }) => {
        return data.chain_metadata && data.chain_metadata.length > 0;
      },
      maxAttempts: config.retry.maxPollAttempts,
      timeoutMs: config.timeouts.test,
    });

    expect(result.success).toBe(true);
    expect(result.data?.chain_metadata).toBeDefined();
    expect(result.data?.chain_metadata.length).toBeGreaterThan(0);
  });

  it("should have _meta with indexed block info", async () => {
    interface MetaResponse {
      _meta: {
        block: {
          number: number;
          timestamp: number;
        };
      };
    }

    const result = await graphql.poll<MetaResponse>({
      query: `
        {
          _meta {
            block {
              number
              timestamp
            }
          }
        }
      `,
      validate: (data) => {
        return (
          data._meta?.block?.number !== undefined &&
          data._meta?.block?.number >= 0
        );
      },
      maxAttempts: config.retry.maxPollAttempts,
      timeoutMs: config.timeouts.test,
    });

    expect(result.success).toBe(true);
    expect(result.data?._meta?.block?.number).toBeGreaterThanOrEqual(0);
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
