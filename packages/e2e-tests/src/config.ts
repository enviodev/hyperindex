/**
 * E2E Test Configuration
 */

import path from "path";
import fs from "fs";

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
 * Priority: ENVIO_BIN → cargo build → node bin.mjs (published artifact).
 */
function resolveEnvio(): { command: string; args: string[] } {
  if (process.env.ENVIO_BIN) {
    return { command: process.env.ENVIO_BIN, args: [] };
  }

  // Prefer bin.mjs which loads the NAPI addon in-process via Core.res.
  // In CI, the addon is installed via the envio-linux-x64 platform package;
  // in local dev, Core.res auto-builds via cargo if needed.
  const binMjs = path.join(rootDir, "packages/envio/bin.mjs");
  if (fs.existsSync(binMjs)) {
    return { command: "node", args: [binMjs] };
  }

  throw new Error(
    "envio binary not found. Either:\n" +
      "  - Set ENVIO_BIN env var\n" +
      "  - Run `cargo build` in packages/cli first"
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
