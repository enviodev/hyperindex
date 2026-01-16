#!/usr/bin/env tsx
/**
 * E2E Test Runner
 *
 * Usage:
 *   pnpm test                    # Run all tests sequentially
 *   pnpm test --parallel         # Run tests in parallel
 *   pnpm test --template evm_Greeter  # Run single template
 *   pnpm test --generate-only    # Only generate templates
 */

import path from "path";
import { fileURLToPath } from "url";
import {
  TestConfig,
  TestResult,
  TestSuiteResult,
  GraphQLTestCase,
} from "./types.js";
import { IndexerManager } from "./indexer.js";
import { GraphQLClient } from "./utils/graphql.js";
import { generateAllTemplates, copyTestIndexers } from "./templates.js";
import { greeterTests } from "./tests/evm-greeter.js";
import { erc20Tests } from "./tests/evm-erc20.js";
import { fuelGreeterTests } from "./tests/fuel-greeter.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(__dirname, "../../../..");
const OUTPUT_DIR = path.join(ROOT_DIR, "codegenerator/integration_tests/integration_test_output");
const FIXTURES_DIR = path.join(__dirname, "../fixtures");

/**
 * Test configurations
 */
const TEST_CONFIGS: TestConfig[] = [
  {
    id: "evm_Erc20",
    name: "EVM ERC20 Template",
    ecosystem: "evm",
    template: "Erc20",
  },
  {
    id: "evm_Greeter",
    name: "EVM Greeter Template",
    ecosystem: "evm",
    template: "Greeter",
  },
  {
    id: "fuel_Greeter",
    name: "Fuel Greeter Template",
    ecosystem: "fuel",
    template: "Greeter",
  },
];

/**
 * Map test IDs to their GraphQL test cases
 */
function getTestCases(id: string): GraphQLTestCase<unknown>[] {
  switch (id) {
    case "evm_Greeter":
      return greeterTests as GraphQLTestCase<unknown>[];
    case "evm_Erc20":
      return erc20Tests as GraphQLTestCase<unknown>[];
    case "fuel_Greeter":
      return fuelGreeterTests as GraphQLTestCase<unknown>[];
    default:
      return [];
  }
}

/**
 * Run a single test
 */
async function runTest(
  config: TestConfig,
  manager: IndexerManager,
  graphql: GraphQLClient
): Promise<TestResult> {
  const startTime = Date.now();

  try {
    // Setup
    await manager.install(config);
    await manager.codegen(config);
    await manager.stop(config);

    // Start indexer
    const context = await manager.startDev(config);

    try {
      // Run GraphQL tests
      const testCases = getTestCases(config.id);
      let totalAttempts = 0;

      for (const testCase of testCases) {
        console.log(
          `[${config.id}] Testing: ${testCase.description ?? "GraphQL validation"}`
        );

        const result = await graphql.poll({
          query: testCase.query,
          validate: testCase.validate,
          maxAttempts: 100,
          timeoutMs: config.timeout ?? 120000,
        });

        totalAttempts += result.attempts;

        if (!result.success) {
          throw new Error(
            `GraphQL test failed: ${result.error}\nLast response: ${JSON.stringify(result.lastResponse, null, 2)}`
          );
        }

        console.log(
          `[${config.id}] Test passed after ${result.attempts} attempts`
        );
      }

      return {
        config,
        passed: true,
        durationMs: Date.now() - startTime,
        pollAttempts: totalAttempts,
      };
    } finally {
      await context.cleanup();
    }
  } catch (err) {
    const error = err instanceof Error ? err : new Error(String(err));
    return {
      config,
      passed: false,
      durationMs: Date.now() - startTime,
      error: error.message,
      stack: error.stack,
    };
  }
}

/**
 * Run tests sequentially
 */
async function runSequential(
  configs: TestConfig[],
  manager: IndexerManager,
  graphql: GraphQLClient
): Promise<TestSuiteResult> {
  const results: TestResult[] = [];
  const startTime = Date.now();

  for (const config of configs) {
    console.log(`\n${"=".repeat(60)}`);
    console.log(`Running: ${config.name}`);
    console.log(`${"=".repeat(60)}\n`);

    const result = await runTest(config, manager, graphql);
    results.push(result);

    if (result.passed) {
      console.log(`\n[PASS] ${config.name} (${result.durationMs}ms)`);
    } else {
      console.log(`\n[FAIL] ${config.name}: ${result.error}`);
    }
  }

  return {
    total: results.length,
    passed: results.filter((r) => r.passed).length,
    failed: results.filter((r) => !r.passed).length,
    durationMs: Date.now() - startTime,
    results,
  };
}

/**
 * Run tests in parallel (limited concurrency)
 */
async function runParallel(
  configs: TestConfig[],
  manager: IndexerManager,
  graphql: GraphQLClient,
  concurrency: number = 2
): Promise<TestSuiteResult> {
  const results: TestResult[] = [];
  const startTime = Date.now();
  const queue = [...configs];

  const workers = Array.from({ length: concurrency }, async (_, workerIdx) => {
    while (queue.length > 0) {
      const config = queue.shift();
      if (!config) break;

      // Each worker uses its own port
      const workerPort = 9898 + workerIdx;
      const workerManager = new IndexerManager({
        outputDir: OUTPUT_DIR,
        port: workerPort,
      });

      console.log(`[Worker ${workerIdx}] Starting: ${config.name}`);
      const result = await runTest(config, workerManager, graphql);
      results.push(result);

      if (result.passed) {
        console.log(
          `[Worker ${workerIdx}] [PASS] ${config.name} (${result.durationMs}ms)`
        );
      } else {
        console.log(
          `[Worker ${workerIdx}] [FAIL] ${config.name}: ${result.error}`
        );
      }
    }
  });

  await Promise.all(workers);

  return {
    total: results.length,
    passed: results.filter((r) => r.passed).length,
    failed: results.filter((r) => !r.passed).length,
    durationMs: Date.now() - startTime,
    results,
  };
}

/**
 * Print test summary
 */
function printSummary(result: TestSuiteResult): void {
  console.log(`\n${"=".repeat(60)}`);
  console.log("TEST SUMMARY");
  console.log(`${"=".repeat(60)}`);
  console.log(`Total:    ${result.total}`);
  console.log(`Passed:   ${result.passed}`);
  console.log(`Failed:   ${result.failed}`);
  console.log(`Duration: ${(result.durationMs / 1000).toFixed(1)}s`);
  console.log(`${"=".repeat(60)}\n`);

  if (result.failed > 0) {
    console.log("FAILURES:");
    for (const r of result.results.filter((r) => !r.passed)) {
      console.log(`\n  ${r.config.name}:`);
      console.log(`    ${r.error}`);
    }
    console.log("");
  }
}

/**
 * Parse CLI arguments
 */
function parseArgs(): {
  parallel: boolean;
  template?: string;
  generateOnly: boolean;
  skipGenerate: boolean;
} {
  const args = process.argv.slice(2);
  return {
    parallel: args.includes("--parallel"),
    template: args.find((a) => a.startsWith("--template="))?.split("=")[1] ??
      (args.includes("--template") ? args[args.indexOf("--template") + 1] : undefined),
    generateOnly: args.includes("--generate-only"),
    skipGenerate: args.includes("--skip-generate"),
  };
}

/**
 * Main entry point
 */
async function main(): Promise<void> {
  const args = parseArgs();

  console.log("E2E Test Runner");
  console.log(`Mode: ${args.parallel ? "parallel" : "sequential"}`);

  // Generate templates unless skipped
  if (!args.skipGenerate) {
    console.log("\nGenerating templates...");
    await generateAllTemplates({
      outputDir: OUTPUT_DIR,
      apiToken: process.env.ENVIO_API_TOKEN,
    });

    // Copy custom test indexers
    await copyTestIndexers(
      path.join(ROOT_DIR, "codegenerator/integration_tests/tests"),
      OUTPUT_DIR
    );
  }

  if (args.generateOnly) {
    console.log("\nTemplates generated. Exiting (--generate-only).");
    return;
  }

  // Filter configs if specific template requested
  let configs = TEST_CONFIGS;
  if (args.template) {
    configs = configs.filter((c) => c.id === args.template);
    if (configs.length === 0) {
      console.error(`Unknown template: ${args.template}`);
      console.error(`Available: ${TEST_CONFIGS.map((c) => c.id).join(", ")}`);
      process.exit(1);
    }
  }

  // Initialize
  const manager = new IndexerManager({ outputDir: OUTPUT_DIR });
  const graphql = new GraphQLClient();

  // Run tests
  const result = args.parallel
    ? await runParallel(configs, manager, graphql)
    : await runSequential(configs, manager, graphql);

  // Print summary
  printSummary(result);

  // Exit with appropriate code
  process.exit(result.failed > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
