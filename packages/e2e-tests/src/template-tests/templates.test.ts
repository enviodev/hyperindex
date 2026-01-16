/**
 * Template Tests
 *
 * Verifies that templates can be generated, build, and pass tests.
 * These tests don't require database access and can run in parallel.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { runCommand } from "../utils/process.js";
import { config } from "../config.js";
import path from "path";
import fs from "fs/promises";
import os from "os";

interface TemplateTestConfig {
  name: string;
  ecosystem: "evm" | "fuel";
  template: string;
}

const TEMPLATES: TemplateTestConfig[] = [
  { name: "EVM Greeter", ecosystem: "evm", template: "greeter" },
  { name: "EVM ERC20", ecosystem: "evm", template: "erc20" },
  { name: "EVM Factory", ecosystem: "evm", template: "feature-factory" },
  { name: "Fuel Greeter", ecosystem: "fuel", template: "greeter" },
];

// Get envio binary path - use built binary or fall back to cargo run
const ENVIO_BIN = path.join(
  config.rootDir,
  "codegenerator/target/release/envio"
);

describe.each(TEMPLATES)("Template: $name", ({ ecosystem, template }) => {
  let testDir: string;
  let projectDir: string;
  const projectName = `test-${ecosystem}-${template.replace("-", "")}`;

  beforeAll(async () => {
    // Create a temporary directory for this test
    testDir = await fs.mkdtemp(
      path.join(os.tmpdir(), `envio-template-test-`)
    );
    projectDir = path.join(testDir, projectName);
  });

  afterAll(async () => {
    // Clean up the temporary directory
    if (testDir) {
      await fs.rm(testDir, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("generates template with envio init", async () => {
    // Build the init command based on ecosystem
    const args =
      ecosystem === "fuel"
        ? [
            "init",
            "fuel",
            "template",
            "--name",
            projectName,
            "--template",
            template,
            "--language",
            "typescript",
          ]
        : [
            "init",
            "template",
            "--name",
            projectName,
            "--template",
            template,
            "--language",
            "typescript",
          ];

    const result = await runCommand(ENVIO_BIN, args, {
      cwd: testDir,
      timeout: config.timeouts.codegen,
      env: {
        ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
      },
    });

    if (result.exitCode !== 0) {
      console.error("envio init failed:", result.stderr);
    }
    expect(result.exitCode).toBe(0);

    // Verify project was created
    const exists = await fs
      .access(projectDir)
      .then(() => true)
      .catch(() => false);
    expect(exists).toBe(true);
  });

  it("installs dependencies", async () => {
    const result = await runCommand("pnpm", ["install"], {
      cwd: projectDir,
      timeout: config.timeouts.install,
    });

    if (result.exitCode !== 0) {
      console.error("pnpm install failed:", result.stderr);
    }
    expect(result.exitCode).toBe(0);
  });

  it("runs codegen successfully", async () => {
    const result = await runCommand(ENVIO_BIN, ["codegen"], {
      cwd: projectDir,
      timeout: config.timeouts.codegen,
      env: {
        ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
      },
    });

    if (result.exitCode !== 0) {
      console.error("envio codegen failed:", result.stderr);
    }
    expect(result.exitCode).toBe(0);
  });

  it("passes TypeScript type check", async () => {
    const result = await runCommand("pnpm", ["tsc", "--noEmit"], {
      cwd: projectDir,
      timeout: config.timeouts.test,
    });

    if (result.exitCode !== 0) {
      console.error("tsc failed:", result.stderr);
    }
    expect(result.exitCode).toBe(0);
  });

  it("passes unit tests", async () => {
    const result = await runCommand("pnpm", ["test"], {
      cwd: projectDir,
      timeout: config.timeouts.test,
    });

    if (result.exitCode !== 0) {
      console.error("pnpm test failed:", result.stderr);
    }
    expect(result.exitCode).toBe(0);
  });
});
