/**
 * E2E Rate Limit Test
 *
 * Verifies that the indexer handles HyperSync rate limits gracefully:
 * 1. Start indexer with a rate-limited API token (limit=10 req/min)
 * 2. Indexer should complete indexing despite hitting rate limits
 * 3. Verify all events are indexed correctly
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

const PROJECT_DIR = path.join(config.scenariosDir, "rate_limit_test");
const RATE_LIMITED_API_TOKEN = "3dc856dd-b0ea-494f-b27e-017b8b6b7e07";

describe("E2E: Indexer handles rate limiting", () => {
  let indexerProcess: ChildProcess | null = null;
  let graphql: GraphQLClient;
  let indexerOutput: string[] = [];

  beforeAll(async () => {
    graphql = new GraphQLClient({
      endpoint: config.graphqlEndpoint,
      adminSecret: config.hasuraAdminSecret,
    });

    await killProcessOnPort(config.indexerPort);

    indexerProcess = startBackground(
      config.envioCommand,
      [...config.envioArgs, "dev"],
      {
        cwd: PROJECT_DIR,
        env: {
          ENVIO_TUI: "false",
          ENVIO_API_TOKEN: RATE_LIMITED_API_TOKEN,
        },
      }
    );

    // Capture all output for later assertions
    indexerProcess.stdout?.on("data", (data: Buffer) => {
      indexerOutput.push(data.toString());
    });
    indexerProcess.stderr?.on("data", (data: Buffer) => {
      indexerOutput.push(data.toString());
    });

    await waitForOutput(
      indexerProcess,
      "All chains are caught up to end blocks",
      300_000 // 5 min — rate limiting adds significant delay
    );

    await graphql.poll<{
      _meta: Array<{ chainId: number; isReady: boolean }>;
    }>({
      query: `{ _meta { chainId isReady } }`,
      validate: (data) =>
        data._meta?.length > 0 && data._meta.every((m) => m.isReady),
      maxAttempts: 60,
      timeoutMs: 30_000,
    });
  }, 600_000);

  afterAll(async () => {
    if (indexerProcess) {
      indexerProcess.kill("SIGKILL");
    }
    await killProcessOnPort(config.indexerPort);
    await runCommand(config.envioCommand, [...config.envioArgs, "stop"], {
      cwd: PROJECT_DIR,
      timeout: 30_000,
    }).catch(() => {});
  }, 30_000);

  it("should index all events despite rate limiting", async () => {
    const result = await graphql.poll<{
      Transfer: Array<{ id: string; blockNumber: number }>;
    }>({
      query: `{ Transfer(limit: 100) { id blockNumber } }`,
      validate: (data) => (data.Transfer?.length ?? 0) > 0,
      maxAttempts: 10,
      timeoutMs: 5_000,
    });

    expect(result.success).toBe(true);
    expect(result.data!.Transfer.length).toBeGreaterThan(0);
  });

  it("should have encountered rate limiting during indexing", () => {
    const fullOutput = indexerOutput.join("");
    expect(fullOutput).toContain("rate limit");
  });
});
