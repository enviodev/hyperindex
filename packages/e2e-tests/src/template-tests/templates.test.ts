/**
 * Template Tests
 *
 * Verifies that scenario templates can build and pass tests.
 * These tests use existing scenarios in the repository.
 * No database access required, can run in parallel.
 */

import { describe, it, expect } from "vitest";
import { runCommand } from "../utils/process.js";
import { config } from "../config.js";
import path from "path";

interface ScenarioConfig {
  name: string;
  path: string;
  hasTests: boolean;
}

// Get envio binary path
const ENVIO_BIN = path.join(
  config.rootDir,
  "codegenerator/target/release/envio"
);

const SCENARIOS: ScenarioConfig[] = [
  {
    name: "test_codegen",
    path: path.join(config.scenariosDir, "test_codegen"),
    hasTests: true,
  },
  {
    name: "erc20_multichain_factory",
    path: path.join(config.scenariosDir, "erc20_multichain_factory"),
    hasTests: true,
  },
  // Note: fuel_test excluded due to tsx/yoga-layout top-level await compatibility issue
];

describe.each(SCENARIOS)("Scenario: $name", ({ name, path: scenarioPath, hasTests }) => {
  it("runs codegen successfully", async () => {
    const result = await runCommand(ENVIO_BIN, ["codegen"], {
      cwd: scenarioPath,
      timeout: config.timeouts.codegen,
      env: {
        ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
      },
    });

    if (result.exitCode !== 0) {
      console.error(`[${name}] codegen failed:`, result.stderr);
    }
    expect(result.exitCode).toBe(0);
  });

  it("builds successfully", async () => {
    const result = await runCommand("pnpm", ["build"], {
      cwd: scenarioPath,
      timeout: config.timeouts.test,
    });

    if (result.exitCode !== 0) {
      console.error(`[${name}] build failed:`, result.stderr);
    }
    expect(result.exitCode).toBe(0);
  });

  if (hasTests) {
    it("passes unit tests", async () => {
      const result = await runCommand("pnpm", ["test"], {
        cwd: scenarioPath,
        timeout: config.timeouts.test,
      });

      if (result.exitCode !== 0) {
        console.error(`[${name}] test failed:`, result.stderr);
      }
      expect(result.exitCode).toBe(0);
    });
  }
});
