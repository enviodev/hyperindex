/**
 * E2E Test Configuration
 */

import path from "path";
import fs from "fs";
import { execSync } from "child_process";
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
 * Resolve the envio binary path.
 * Priority: ENVIO_BIN env var → local debug binary → `envio` on PATH (CI).
 */
function resolveEnvioBin(): string {
  if (process.env.ENVIO_BIN) {
    return process.env.ENVIO_BIN;
  }

  // Check release first (CI builds --release), then debug (local dev)
  for (const profile of ["release", "debug"]) {
    const bin = path.join(rootDir, `codegenerator/target/${profile}/envio`);
    if (fs.existsSync(bin)) {
      return bin;
    }
  }

  try {
    const whichResult = execSync("which envio", { encoding: "utf-8" }).trim();
    if (whichResult) return whichResult;
  } catch {
    // not on PATH
  }

  throw new Error(
    "envio binary not found. Either:\n" +
      "  - Set ENVIO_BIN env var\n" +
      "  - Run `cargo build` in codegenerator/cli first\n" +
      "  - Add envio to PATH"
  );
}

const envioBin = resolveEnvioBin();

export const config = {
  /** Root directory of the hyperindex project */
  rootDir,

  /** Resolved path to the envio binary */
  envioBin,

  /** Scenarios directory */
  get scenariosDir() {
    return path.join(this.rootDir, "scenarios");
  },

  /** CLI templates directory */
  get templatesDir() {
    return path.join(this.rootDir, "codegenerator/cli/templates");
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
