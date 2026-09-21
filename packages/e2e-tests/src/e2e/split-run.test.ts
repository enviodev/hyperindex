/**
 * A plain `envio start` over a per-chain schema, with a connection budget that
 * affords two processes, splits the chains across forked workers and stays
 * one indexer to the operator: one metrics endpoint over every process, one
 * exit once every chain reaches its end block, one signal to stop it all.
 *
 * Needs Postgres but no Docker: it drives `envio start` with Hasura disabled.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { ChildProcess } from "child_process";
import path from "path";
import { config } from "../config.js";
import { runCommand, startBackground, waitForOutput } from "../utils/process.js";
import { pgRows, closePg, isPgReachable } from "../utils/pg-direct.js";

const PROJECT_DIR = path.join(config.scenariosDir, "split_test");
const PG_SCHEMA = "e2e_split_run";
const PORT = 9897;

const indexerEnv = {
  ENVIO_PG_SCHEMA: PG_SCHEMA,
  // Two processes' worth: the split's own condition.
  ENVIO_PG_MAX_CONNECTIONS: "4",
  ENVIO_HASURA: "false",
  ENVIO_TUI: "false",
  ENVIO_INDEXER_PORT: String(PORT),
  ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
};

const reachable = await isPgReachable();

if (!reachable && process.env.CI) {
  throw new Error(
    "Postgres is unreachable, so the split-run suite cannot run. Refusing to skip it in CI."
  );
}

const exitCode = (child: ChildProcess) =>
  new Promise<number | null>((resolve) => child.on("close", resolve));

/**
 * Leaves no indexer behind when a test fails before its own shutdown: one that
 * survived would hold the port and the schema against everything after it.
 */
const stopIfRunning = async (indexer: ChildProcess) => {
  if (indexer.exitCode !== null || indexer.signalCode !== null) return;
  const exited = exitCode(indexer);
  indexer.kill("SIGINT");
  const abandon = setTimeout(() => indexer.kill("SIGKILL"), 10_000);
  await exited;
  clearTimeout(abandon);
};

/** Polls an endpoint of the supervisor until its body satisfies `ready`. */
const scrapeUntil = async (route: string, ready: (body: string) => boolean) => {
  const deadline = Date.now() + config.timeouts.indexerStartup;
  let body = "";
  while (Date.now() < deadline) {
    try {
      body = await (await fetch(`http://localhost:${PORT}${route}`)).text();
      if (ready(body)) return body;
    } catch {}
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`Timed out scraping ${route}\n--- last body ---\n${body}`);
};

const start = (args: string[]) =>
  startBackground(config.envioCommand, [...config.envioArgs, "start", ...args], {
    cwd: PROJECT_DIR,
    env: indexerEnv,
  });

describe.skipIf(!reachable)("E2E: a split run is one indexer", () => {
  beforeAll(async () => {
    const codegen = await runCommand(
      config.envioCommand,
      [...config.envioArgs, "codegen"],
      { cwd: PROJECT_DIR, env: indexerEnv, timeout: config.timeouts.codegen }
    );
    expect(codegen.exitCode, `codegen failed: ${codegen.stderr}`).toBe(0);
  }, config.timeouts.codegen);

  afterAll(async () => {
    await closePg();
  });

  it("Exits once every chain is done, with both chains' rows written", async () => {
    const indexer = start(["-r"]);
    try {
      const exit = exitCode(indexer);
      await waitForOutput(indexer, "Indexing will be split across multiple processes", config.timeouts.indexerStartup);

      expect({
        exitCode: await exit,
        rowsPerChain: await pgRows(
          `SELECT "chain_id", COUNT(*) > 0 FROM "${PG_SCHEMA}"."Transfer" GROUP BY "chain_id" ORDER BY "chain_id"`
        ),
        // Reaching an end block doesn't make a worker done: it owes the schema
        // the indexes its chains deferred, and until the run goes realtime it
        // has no leave to commit them.
        readyPerChain: await pgRows(
          `SELECT "id"::text, "ready_at" IS NOT NULL FROM "${PG_SCHEMA}"."envio_chains" ORDER BY "id"`
        ),
      }).toEqual({
        exitCode: 0,
        rowsPerChain: [
          [1, true],
          [8453, true],
        ],
        readyPerChain: [
          ["1", true],
          ["8453", true],
        ],
      });
    } finally {
      await stopIfRunning(indexer);
    }
  });

  // The same chains with no end block: a run that nothing but a stop ends, so
  // there is time to read what it serves.
  it("Serves every process's metrics, and stops them all on one interrupt", async () => {
    const indexer = start(["-r", "--config", "config.head.yaml"]);
    try {
      const exit = exitCode(indexer);
      await waitForOutput(indexer, "Indexing will be split across multiple processes", config.timeouts.indexerStartup);

      const [runtime, metrics] = await Promise.all([
        // Each worker's readings, told apart by label.
        scrapeUntil("/metrics/runtime", (body) => body.includes('worker="8453"')),
        // Both chains on one endpoint, whichever process drives each.
        scrapeUntil(
          "/metrics",
          (body) => body.includes('chainId="1"') && body.includes('chainId="8453"')
        ),
      ]);

      // Only the supervisor is signalled, the way a process manager would.
      indexer.kill("SIGINT");

      expect({
        exitCode: await exit,
        // Workers are named by the chains they drive.
        runtimeWorkers: ["1", "8453"].map((worker) =>
          runtime.includes(`nodejs_heap_size_used_bytes{worker="${worker}"}`)
        ),
        metricsChains: [1, 8453].map((chainId) =>
          metrics.includes(`envio_progress_block{chainId="${chainId}"}`)
        ),
      }).toEqual({
        exitCode: 0,
        runtimeWorkers: [true, true],
        metricsChains: [true, true],
      });
    } finally {
      await stopIfRunning(indexer);
    }
  });
});
