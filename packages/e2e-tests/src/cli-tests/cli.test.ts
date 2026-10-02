/**
 * CLI Subprocess Tests
 *
 * Drives the real envio binary against fixture projects that have no codegen
 * output — every command here parses the project files directly.
 */

import { describe, it, expect } from "vitest";
import path from "path";
import { runCommand } from "../utils/process.js";
import { config } from "../config.js";

const PROJECT_DIR = path.join(config.rootDir, "packages/e2e-tests/fixtures/cli-project");

// Its own schema, so setup/down can't wipe a schema another test file is
// indexing into while the suite runs in parallel.
const PG_SCHEMA = `envio_test_${Date.now()}_${process.pid}_dbmigrate`;

const runEnvio = (args: string[], env?: Record<string, string>, cwd = PROJECT_DIR) =>
  runCommand(config.envioCommand, [...config.envioArgs, ...args], {
    cwd,
    timeout: 30_000,
    env,
  });

describe("envio config view", () => {
  it("prints the resolved config as JSON", async () => {
    const result = await runEnvio(["config", "view"]);

    expect({ exitCode: result.exitCode, parsed: JSON.parse(result.stdout) }).toEqual({
      exitCode: 0,
      parsed: { version: "0.0.1-dev", storage: { postgres: true } },
    });
  });
});

// Regression test for db-migrate setup/down hanging after the postgres pool's
// idle TCP sockets kept Node's event loop alive. The commands must exit on
// their own, well within the timeout.
describe("envio local db-migrate", () => {
  const dbEnv = {
    ENVIO_PG_PORT: String(config.pgPort),
    ENVIO_PG_SCHEMA: PG_SCHEMA,
    // Hasura isn't reachable in the test environment; without this, retries
    // dominate runtime and obscure whether the process actually exited.
    ENVIO_HASURA: "false",
  };

  it("setup exits cleanly without hanging", async () => {
    const result = await runEnvio(["local", "db-migrate", "setup"], dbEnv);

    expect(result.exitCode, result.stderr).toBe(0);
  });

  it("down exits cleanly without hanging", async () => {
    const result = await runEnvio(["local", "db-migrate", "down"], dbEnv);

    expect(result.exitCode, result.stderr).toBe(0);
  });
});

describe("TypeScript handler errors", () => {
  it("name the handler's TypeScript source line", async () => {
    const result = await runEnvio(
      ["start"],
      {
        ENVIO_PG_PORT: String(config.pgPort),
        ENVIO_PG_SCHEMA: `envio_test_${Date.now()}_${process.pid}_tshandler`,
        ENVIO_HASURA: "false",
      },
      path.join(config.rootDir, "packages/e2e-tests/fixtures/ts-handler-project")
    );

    expect(`${result.stdout}${result.stderr}`).toMatch(/Throwing\.ts:9:/);
  });
});

// The tsconfig is the one found from the working directory, as tsx does, so
// this runs the CLI rather than an in-process indexer.
describe("TypeScript handler imports", () => {
  it("resolve tsconfig paths and baseUrl before packages, and dependencies as Node does", async () => {
    const result = await runEnvio(
      ["start"],
      {
        ENVIO_PG_PORT: String(config.pgPort),
        ENVIO_PG_SCHEMA: `envio_test_${Date.now()}_${process.pid}_tspaths`,
        ENVIO_HASURA: "false",
      },
      path.join(config.rootDir, "packages/e2e-tests/fixtures/ts-paths-project")
    );

    expect(`${result.stdout}${result.stderr}`).toContain("loaded Gravatar NewGravatar shadowed cjs js");
  });
});
