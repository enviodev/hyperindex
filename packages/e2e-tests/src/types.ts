/**
 * E2E test type definitions
 */

export type Ecosystem = "evm" | "fuel";
export type Template = "Erc20" | "Greeter";

export interface TestConfig {
  /** Unique test identifier */
  id: string;
  /** Display name for the test */
  name: string;
  /** Ecosystem (evm, fuel) */
  ecosystem: Ecosystem;
  /** Template name */
  template: Template;
  /** Config file to use (default: config.yaml) */
  configFile?: string;
  /** Whether the test should fail */
  shouldFail?: boolean;
  /** Whether to test restart behavior */
  testRestart?: boolean;
  /** Custom environment variables */
  env?: Record<string, string>;
  /** Timeout in ms (default: 120000) */
  timeout?: number;
}

export interface TestResult {
  /** Test configuration */
  config: TestConfig;
  /** Whether the test passed */
  passed: boolean;
  /** Duration in ms */
  durationMs: number;
  /** Error message if failed */
  error?: string;
  /** Detailed error stack */
  stack?: string;
  /** Number of GraphQL poll attempts */
  pollAttempts?: number;
}

export interface TestSuiteResult {
  /** Total tests run */
  total: number;
  /** Tests passed */
  passed: number;
  /** Tests failed */
  failed: number;
  /** Total duration in ms */
  durationMs: number;
  /** Individual test results */
  results: TestResult[];
}

export interface IndexerContext {
  /** Working directory for the test */
  workDir: string;
  /** Port the indexer is running on */
  port: number;
  /** Cleanup function */
  cleanup: () => Promise<void>;
}

export type TestValidation<T = unknown> = (data: T) => boolean;

export interface GraphQLTestCase<T = unknown> {
  /** GraphQL query */
  query: string;
  /** Validation function */
  validate: TestValidation<T>;
  /** Description of what's being tested */
  description?: string;
}
