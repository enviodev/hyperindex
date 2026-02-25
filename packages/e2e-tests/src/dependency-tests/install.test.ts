/**
 * Isolated Dependency E2E Test
 *
 * Runs codegen in an isolated directory outside the pnpm workspace,
 * then re-installs with both pnpm and npm using a direct file: reference
 * to packages/envio. Starts `envio dev` to verify the indexer runs and
 * produces data, proving all runtime dependencies are correctly declared.
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

/** Replace the envio dependency version in a package.json file */
function patchEnvioDep(pkgJsonPath: string, version: string) {
  const pkg = JSON.parse(fs.readFileSync(pkgJsonPath, "utf-8"));
  if (pkg.dependencies?.envio) {
    pkg.dependencies.envio = version;
  }
  fs.writeFileSync(pkgJsonPath, JSON.stringify(pkg, null, 2));
}

interface PmConfig {
  pm: string;
  installArgs: string[];
}

const PACKAGE_MANAGERS: PmConfig[] = [
  { pm: "pnpm", installArgs: ["install"] },
  { pm: "npm", installArgs: ["install"] },
];

describe("Isolated dependency e2e", () => {
  let baseProjectDir: string;
  const tempDirs: string[] = [];
  const envioPackagePath = path.join(config.rootDir, "packages/envio");

  // Run codegen once; each PM test copies from here.
  beforeAll(async () => {
    // 1. Copy e2e_test scenario into an isolated temp directory
    baseProjectDir = fs.mkdtempSync(path.join(os.tmpdir(), "envio-base-"));
    tempDirs.push(baseProjectDir);

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

    // 2. Patch root package.json to absolute file: path so codegen's
    //    pnpm install resolves correctly outside the workspace
    patchEnvioDep(
      path.join(baseProjectDir, "package.json"),
      `file:${envioPackagePath}`
    );

    // 3. Run envio codegen — generates code, pnpm-installs, builds rescript
    const codegenResult = await runCommand(config.envioBin, ["codegen"], {
      cwd: baseProjectDir,
      timeout: 120_000,
      env: { ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "" },
    });
    expect(
      codegenResult.exitCode,
      `codegen failed: ${codegenResult.stderr}`
    ).toBe(0);

    // 4. Ensure both package.json files use the absolute file: path
    patchEnvioDep(
      path.join(baseProjectDir, "package.json"),
      `file:${envioPackagePath}`
    );
    patchEnvioDep(
      path.join(baseProjectDir, "generated", "package.json"),
      `file:${envioPackagePath}`
    );

    // 5. Remove node_modules and lockfiles so each PM test starts clean
    for (const dir of [baseProjectDir, path.join(baseProjectDir, "generated")]) {
      const nm = path.join(dir, "node_modules");
      if (fs.existsSync(nm)) fs.rmSync(nm, { recursive: true, force: true });
      for (const name of ["pnpm-lock.yaml", "package-lock.json"]) {
        const p = path.join(dir, name);
        if (fs.existsSync(p)) fs.unlinkSync(p);
      }
    }
  }, 180_000);

  afterAll(() => {
    for (const dir of tempDirs) {
      if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true });
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

      // Copy the base project (skip node_modules dirs)
      projectDir = fs.mkdtempSync(path.join(os.tmpdir(), `envio-${pm}-`));
      tempDirs.push(projectDir);
      fs.cpSync(baseProjectDir, projectDir, {
        recursive: true,
        filter: (source: string) => path.basename(source) !== "node_modules",
      });

      // Install in generated/ first, then project root (same order as codegen)
      const genInstall = await runCommand(pm, installArgs, {
        cwd: path.join(projectDir, "generated"),
        timeout: config.timeouts.install,
      });
      if (genInstall.exitCode !== 0) {
        console.error(`[${pm}] generated/ install failed:`, genInstall.stderr);
      }
      expect(genInstall.exitCode).toBe(0);

      const rootInstall = await runCommand(pm, installArgs, {
        cwd: projectDir,
        timeout: config.timeouts.install,
      });
      if (rootInstall.exitCode !== 0) {
        console.error(`[${pm}] install failed:`, rootInstall.stderr);
      }
      expect(rootInstall.exitCode).toBe(0);

      // envio dev: persisted state matches → skips codegen (and its pnpm install) →
      // starts docker → runs migrations → starts indexer.
      // Our isolated node_modules are preserved.
      indexerProcess = startBackground(config.envioBin, ["dev"], {
        cwd: projectDir,
        env: {
          TUI_OFF: "true",
          ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
        },
      });

      await waitForOutput(
        indexerProcess,
        "All chains are caught up to end blocks",
        60_000
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
      await runCommand(config.envioBin, ["stop"], {
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
