/**
 * What an operator sees when config.yaml changes under an indexer that has
 * already written data: a chain added to it joins on `envio start --chain`,
 * and any other change is refused with what to do about it.
 *
 * Needs Postgres but no Docker: it drives `envio start` with Hasura disabled.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { ChildProcess } from "child_process";
import path from "path";
import { config } from "../config.js";
import { runCommand, startBackground } from "../utils/process.js";
import { pgRows, closePg, isPgReachable } from "../utils/pg-direct.js";

const PROJECT_DIR = path.join(config.scenariosDir, "split_test");
const PG_SCHEMA = "e2e_migration";
const PORT = 9896;

const indexerEnv = {
  ENVIO_PG_SCHEMA: PG_SCHEMA,
  ENVIO_HASURA: "false",
  ENVIO_TUI: "false",
  ENVIO_INDEXER_PORT: String(PORT),
  ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
};

const reachable = await isPgReachable();

if (!reachable && process.env.CI) {
  throw new Error(
    "Postgres is unreachable, so the migration suite cannot run. Refusing to skip it in CI.",
  );
}

const ansi = /\x1b\[[0-9;]*m/g;
const timestamp = /^\[\d{2}:\d{2}:\d{2}\.\d{3}\] /gm;

/** Runs `envio start` to its exit, with what it printed stripped of colour and time. */
const start = async (args: string[], env: Record<string, string> = {}) => {
  const indexer: ChildProcess = startBackground(
    config.envioCommand,
    [...config.envioArgs, "start", ...args],
    { cwd: PROJECT_DIR, env: { ...indexerEnv, ...env } },
  );
  let output = "";
  indexer.stdout?.on("data", (data: Buffer) => (output += data.toString()));
  indexer.stderr?.on("data", (data: Buffer) => (output += data.toString()));
  const abandon = setTimeout(
    () => indexer.kill("SIGKILL"),
    config.timeouts.indexerStartup,
  );
  const exitCode = await new Promise<number | null>((resolve) =>
    indexer.on("close", resolve),
  );
  clearTimeout(abandon);
  return { exitCode, output: output.replace(ansi, "").replace(timestamp, "") };
};

describe.skipIf(!reachable)(
  "E2E: changing config.yaml under an existing indexer",
  () => {
    beforeAll(async () => {
      const codegen = await runCommand(
        config.envioCommand,
        [...config.envioArgs, "codegen"],
        { cwd: PROJECT_DIR, env: indexerEnv, timeout: config.timeouts.codegen },
      );
      expect(codegen.exitCode, `codegen failed: ${codegen.stderr}`).toBe(0);
    }, config.timeouts.codegen);

    afterAll(async () => {
      await closePg();
    });

    it("Adds a chain named by --chain, then refuses a run whose end blocks changed", async () => {
      const deployed = await start([
        "-r",
        "--config",
        "config.first-chain.yaml",
      ]);
      const added = await start(["--chain", "8453"]);
      const edited = await start(["--config", "config.head.yaml"]);

      expect({
        deployed: deployed.exitCode,
        added: {
          exitCode: added.exitCode,
          announced: added.output.includes(
            "Adding the chain to the existing indexer storage...",
          ),
        },
        rowsPerChain: await pgRows(
          `SELECT "chain_id", COUNT(*) > 0 FROM "${PG_SCHEMA}"."Transfer" GROUP BY "chain_id" ORDER BY "chain_id"`,
        ),
        edited: {
          exitCode: edited.exitCode,
          output: edited.output,
        },
      }).toEqual({
        deployed: 0,
        added: { exitCode: 0, announced: true },
        rowsPerChain: [
          [1, true],
          [8453, true],
        ],
        edited: {
          exitCode: 1,
          output: `INFO: Found existing indexer storage. Resuming indexing state...

ERROR: The following config changes are incompatible with the existing indexer data:

    - chains.1.endBlock
    - chains.8453.endBlock

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio start -r            # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio start

`,
        },
      });
    });

    it("Asks for a set-up database before a --chain process starts", async () => {
      await pgRows(`DROP SCHEMA IF EXISTS "e2e_migration_unset" CASCADE`);
      const chainOnly = await start(["--chain", "1"], {
        ENVIO_PG_SCHEMA: "e2e_migration_unset",
      });

      expect(chainOnly).toEqual({
        exitCode: 1,
        output: `ERROR: \`envio start --chain\` needs a database that is already set up. Run \`envio local db-migrate up\` once with the full config, then start a process per chain.

`,
      });
    });
  },
);
