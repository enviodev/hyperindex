/**
 * E2E Test Configuration
 */

import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const config = {
  /** Root directory of the hyperindex project */
  rootDir: path.resolve(__dirname, "../../.."),

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
