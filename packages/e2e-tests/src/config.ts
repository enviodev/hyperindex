/**
 * E2E Test Configuration
 */

import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const config = {
  /** Root directory of the hyperindex project */
  rootDir: path.resolve(__dirname, "../../../.."),

  /** Output directory for generated templates */
  get outputDir() {
    return path.join(
      this.rootDir,
      "codegenerator/integration_tests/integration_test_output"
    );
  },

  /** Fixtures directory */
  get fixturesDir() {
    return path.join(__dirname, "../fixtures");
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

  /** Timeouts */
  timeouts: {
    /** Health check timeout per attempt */
    healthCheck: 5000,
    /** Max time to wait for indexer health */
    indexerStartup: 60000,
    /** Max time to wait for Hasura health */
    hasuraStartup: 60000,
    /** Default test timeout */
    test: 120000,
    /** pnpm install timeout */
    install: 120000,
    /** codegen timeout */
    codegen: 60000,
  },

  /** Retry settings */
  retry: {
    /** Max GraphQL poll attempts */
    maxPollAttempts: 100,
    /** Initial delay between polls */
    initialDelayMs: 500,
    /** Max delay between polls */
    maxDelayMs: 3000,
  },
} as const;
