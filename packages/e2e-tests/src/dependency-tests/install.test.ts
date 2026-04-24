/**
 * Isolated Dependency E2E Test
 *
 * Copies the scenario and packages/envio into a temp directory outside
 * the pnpm workspace, runs codegen, then re-installs with each package
 * manager. Starts `envio dev` to verify the indexer runs and produces
 * data, proving all runtime dependencies are correctly declared on the
 * user's root package.json (generated/ no longer carries deps).
 *
 * This catches undeclared dependencies that work inside the pnpm workspace
 * (due to hoisting) but break for end users who `npm install envio`.
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
import fs from "fs";
import path from "path";
import os from "os";

const SCENARIO_DIR = path.join(config.scenariosDir, "e2e_test");

interface PmConfig {
  pm: string;
  installArgs: string[];
}

const PACKAGE_MANAGERS: PmConfig[] = [
  { pm: "pnpm", installArgs: ["install"] },
];

describe("Isolated dependency e2e", () => {
  let tmpRoot: string;
  let baseProjectDir: string;

  // Run codegen once; each PM test copies from here.
  beforeAll(async () => {
    // 1. Mirror repo layout in an isolated temp root so the scenario's
    //    "file:../../packages/envio" relative path resolves naturally.
    tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "envio-iso-"));

    // Copy envio package — prefer the pre-built artifact when available
    // (CI), fall back to the dev workspace member (local dev).
    const envioSource = fs.existsSync(path.join(config.rootDir, ".envio-artifacts/envio"))
      ? path.join(config.rootDir, ".envio-artifacts/envio")
      : path.join(config.rootDir, "packages/envio");
    fs.cpSync(
      envioSource,
      path.join(tmpRoot, "packages/envio"),
      {
        recursive: true,
        filter: (src: string) => path.basename(src) !== "node_modules",
      }
    );

    // Copy e2e_test scenario
    baseProjectDir = path.join(tmpRoot, "scenarios/e2e_test");
    fs.mkdirSync(baseProjectDir, { recursive: true });
    for (const name of ["config.yaml", "schema.graphql", "tsconfig.json"]) {
      fs.cpSync(
        path.join(SCENARIO_DIR, name),
        path.join(baseProjectDir, name)
      );
    }
    fs.cpSync(path.join(SCENARIO_DIR, "src"), path.join(baseProjectDir, "src"), {
      recursive: true,
    });
    fs.cpSync(
      path.join(SCENARIO_DIR, "package.json"),
      path.join(baseProjectDir, "package.json")
    );

    // 2. Run envio codegen — generates code into generated/. No deps or
     //    rescript config land in generated/, so nothing to install there.
    //    Root package.json's "file:../../packages/envio" resolves to tmpRoot/packages/envio.
    const codegenResult = await runCommand(config.envioCommand, [...config.envioArgs, "codegen"], {
      cwd: baseProjectDir,
      timeout: 120_000,
      env: { ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "" },
    });
    expect(
      codegenResult.exitCode,
      `codegen failed: ${codegenResult.stderr}`
    ).toBe(0);

    // 3. Remove root node_modules and lockfile so each PM test starts clean.
    const nm = path.join(baseProjectDir, "node_modules");
    if (fs.existsSync(nm)) fs.rmSync(nm, { recursive: true, force: true });
    for (const name of ["pnpm-lock.yaml", "package-lock.json"]) {
      const p = path.join(baseProjectDir, name);
      if (fs.existsSync(p)) fs.unlinkSync(p);
    }
  }, 180_000);

  afterAll(() => {
    if (tmpRoot && fs.existsSync(tmpRoot)) {
      fs.rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  describe.each(PACKAGE_MANAGERS)("$pm", ({ pm, installArgs }: PmConfig) => {
    let projectDir: string;
    let indexerProcess: ChildProcess | null = null;
    let graphql: GraphQLClient;

    beforeAll(async () => {
      graphql = new GraphQLClient({
        endpoint: config.graphqlEndpoint,
        adminSecret: config.hasuraAdminSecret,
      });

      await killProcessOnPort(config.indexerPort);

      // The e2e test (run earlier in the same CI job) patches
      // envio_chains.end_block to 10861775. The Postgres in CI is a GH
      // Actions service container, so `envio stop` can't reset it; and
      // this test reuses an existing persisted_state file so envio dev
      // skips migrations. Reset end_block via Hasura before starting so
      // the handler check sees the fresh config value.
      // (envio dev -r would do this via a clean migration, but the
      // isolated dependency install lacks envio's transitive rescript-envsafe
      // at the project root, which db_migrate needs.)
      await fetch(`http://localhost:${config.hasuraPort}/v2/query`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-hasura-admin-secret": config.hasuraAdminSecret,
        },
        body: JSON.stringify({
          type: "run_sql",
          args: {
            sql: `UPDATE public.envio_chains SET end_block = 10861774 WHERE id = 1`,
          },
        }),
      }).catch(() => {});

      // Copy the base project into <tmpRoot>/<pm>/e2e_test/ so the
      // relative path "../../packages/envio" still resolves to tmpRoot/packages/envio.
      projectDir = path.join(tmpRoot, pm, "e2e_test");
      fs.mkdirSync(path.join(tmpRoot, pm), { recursive: true });
      fs.cpSync(baseProjectDir, projectDir, {
        recursive: true,
        filter: (source: string) => path.basename(source) !== "node_modules",
      });

      const rootInstall = await runCommand(pm, installArgs, {
        cwd: projectDir,
        timeout: config.timeouts.install,
      });
      if (rootInstall.exitCode !== 0) {
        console.error(`[${pm}] install failed:`, rootInstall.stderr);
      }
      expect(rootInstall.exitCode).toBe(0);

      // envio dev: persisted state matches → skips codegen → starts docker →
      // runs migrations → starts indexer. Root node_modules are preserved.
      indexerProcess = startBackground(config.envioCommand, [...config.envioArgs, "dev"], {
        cwd: projectDir,
        env: {
          TUI_OFF: "true",
          ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
          // e2e_test config.yaml declares `storage.clickhouse: true`, so
          // PgStorage validates these env vars at indexer start.
          ENVIO_CLICKHOUSE_HOST: config.clickhouseUrl,
          ENVIO_CLICKHOUSE_USERNAME: config.clickhouseUsername,
          ENVIO_CLICKHOUSE_PASSWORD: config.clickhousePassword,
          // Fresh start (after the SQL reset above): handler check uses
          // the config endBlock as the source of truth.
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
    }, 300_000);

    afterAll(async () => {
      if (indexerProcess) {
        indexerProcess.kill("SIGTERM");
        indexerProcess = null;
      }
      await killProcessOnPort(config.indexerPort);
      // docker compose down -v (removes containers + volumes for clean next run)
      await runCommand(config.envioCommand, [...config.envioArgs, "stop"], {
        cwd: projectDir,
        timeout: 30_000,
      }).catch(() => {});
    }, 60_000);

    it("should have indexed Transfer entities", async () => {
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
      expect(result.data?.Transfer[0]).toMatchObject({
        id: expect.any(String),
        from: expect.any(String),
        to: expect.any(String),
        blockNumber: expect.any(Number),
        transactionHash: expect.any(String),
      });
    });
  });
});
