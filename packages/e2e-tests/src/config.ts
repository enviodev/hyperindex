/**
 * E2E Test Configuration
 */

import path from "path";
import fs from "fs";
import { createRequire } from "node:module";

import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Load key=value pairs from a .env file into process.env (no overwrite) */
function loadEnvFile(filePath: string) {
  try {
    const content = fs.readFileSync(filePath, "utf-8");
    for (const line of content.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eqIdx = trimmed.indexOf("=");
      if (eqIdx === -1) continue;
      const key = trimmed.slice(0, eqIdx).trim();
      const value = trimmed.slice(eqIdx + 1).trim();
      if (!process.env[key]) {
        process.env[key] = value;
      }
    }
  } catch {
    // .env file is optional
  }
}

const rootDir = path.resolve(__dirname, "../../..");
loadEnvFile(path.join(rootDir, ".env"));

/**
 * Resolve the envio command and base args.
 * Priority: ENVIO_BIN → installed bin.mjs via require.resolve.
 *
 * We resolve the *installed* envio's bin.mjs (via createRequire) rather
 * than the source checkout's, because in CI the source checkout has
 * uncompiled .res files — only the artifact installed into node_modules
 * has the compiled .res.mjs output that Core.res.mjs imports.
 *
 * We use `node <absolute-path>` instead of `pnpm exec envio` because
 * template tests run from temp directories with no node_modules.
 *
 * e2e-tests declares envio as a devDependency so createRequire resolves
 * to the installed package (CI artifact or workspace link).
 */
function resolveEnvio(): { command: string; args: string[] } {
  if (process.env.ENVIO_BIN) {
    return { command: process.env.ENVIO_BIN, args: [] };
  }

  const req = createRequire(import.meta.url);
  try {
    const pkgJsonPath = req.resolve("envio/package.json");
    const pkg = JSON.parse(fs.readFileSync(pkgJsonPath, "utf-8"));
    const binRel = typeof pkg.bin === "string" ? pkg.bin : pkg.bin?.envio;
    if (binRel) {
      const binAbs = path.resolve(path.dirname(pkgJsonPath), binRel);
      if (fs.existsSync(binAbs)) {
        return { command: "node", args: [binAbs] };
      }
    }
  } catch {}

  throw new Error(
    "envio not found. Either:\n" +
      "  - Set ENVIO_BIN env var\n" +
      "  - Run `pnpm install` to install the envio package"
  );
}

const envio = resolveEnvio();

export const config = {
  /** Root directory of the hyperindex project */
  rootDir,

  /** Command to invoke envio (e.g. path to binary, or "pnpm") */
  envioCommand: envio.command,

  /** Base args prepended to every envio invocation (e.g. ["exec", "envio"]) */
  envioArgs: envio.args,

  /** Scenarios directory */
  get scenariosDir() {
    return path.join(this.rootDir, "scenarios");
  },

  /** CLI templates directory */
  get templatesDir() {
    return path.join(this.rootDir, "packages/cli/templates");
  },

  /** Default indexer port */
  indexerPort: 9898,

  /** Default Hasura port */
  hasuraPort: 8080,

  /** Default GraphQL endpoint */
  get graphqlEndpoint() {
    return `http://localhost:${this.hasuraPort}/v1/graphql`;
  },

  /** Default Hasura admin secret */
  hasuraAdminSecret: "testing",

  /** ClickHouse settings */
  clickhousePort: 8123,
  clickhouseContainer: "envio-clickhouse-test",
  clickhouseUsername: "default",
  clickhousePassword: "testing",

  get clickhouseUrl() {
    return `http://localhost:${this.clickhousePort}`;
  },

  /** Timeouts (ms) */
  timeouts: {
    healthCheck: 5000,
    indexerStartup: 60000,
    hasuraStartup: 60000,
    test: 120000,
    install: 120000,
    codegen: 60000,
  },

  /** Retry settings */
  retry: {
    maxPollAttempts: 100,
    initialDelayMs: 500,
    maxDelayMs: 3000,
  },
} as const;
