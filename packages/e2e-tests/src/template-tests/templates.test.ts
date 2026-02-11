/**
 * Template Tests
 *
 * Verifies that all project templates can be initialized, built and pass codegen.
 * Uses `envio init` with CLI arguments to generate projects non-interactively.
 * No database access required, can run in parallel.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { runCommand } from "../utils/process.js";
import { config } from "../config.js";
import path from "path";
import fs from "fs";
import os from "os";

interface TemplateConfig {
  name: string;
  initArgs: string[];
}

// Get envio binary path
const ENVIO_BIN = path.join(
  config.rootDir,
  "codegenerator/target/release/envio"
);

// All available templates to test (TypeScript only)
const TEMPLATES: TemplateConfig[] = [
  // EVM Templates
  {
    name: "evm-greeter",
    initArgs: ["template", "-t", "greeter", "-l", "typescript"],
  },
  {
    name: "evm-erc20",
    initArgs: ["template", "-t", "erc20", "-l", "typescript"],
  },
  {
    name: "evm-factory",
    initArgs: ["template", "-t", "feature-factory", "-l", "typescript"],
  },
  // Fuel Templates
  {
    name: "fuel-greeter",
    initArgs: ["fuel", "template", "-t", "greeter", "-l", "typescript"],
  },
  // SVM Templates
  {
    name: "svm-block-handler",
    initArgs: ["svm", "template", "-t", "feature-block-handler", "-l", "typescript"],
  },
];

describe.each(TEMPLATES)("Template: $name", ({ name, initArgs }) => {
  let projectDir: string;

  beforeAll(async () => {
    // Create a unique temp directory for this test
    const tempBase = path.join(os.tmpdir(), "envio-template-tests");
    fs.mkdirSync(tempBase, { recursive: true });
    projectDir = path.join(tempBase, `${name}-${Date.now()}`);
    fs.mkdirSync(projectDir, { recursive: true });
  });

  afterAll(async () => {
    // Clean up the temp directory
    if (projectDir && fs.existsSync(projectDir)) {
      fs.rmSync(projectDir, { recursive: true, force: true });
    }
  });

  it("initializes successfully", async () => {
    const apiToken = process.env.ENVIO_API_TOKEN ?? "";
    const result = await runCommand(
      ENVIO_BIN,
      ["init", "-n", name, "-d", projectDir, "--api-token", apiToken, ...initArgs],
      {
        cwd: projectDir,
        timeout: config.timeouts.codegen,
      }
    );

    if (result.exitCode !== 0) {
      console.error(`[${name}] init failed:`, result.stderr);
      console.error(`[${name}] stdout:`, result.stdout);
    }
    expect(result.exitCode).toBe(0);
  });

  it("installs dependencies", async () => {
    const result = await runCommand("pnpm", ["install"], {
      cwd: projectDir,
      timeout: config.timeouts.test,
    });

    if (result.exitCode !== 0) {
      console.error(`[${name}] pnpm install failed:`, result.stderr);
    }
    expect(result.exitCode).toBe(0);
  });

  it("runs codegen successfully", async () => {
    const result = await runCommand(ENVIO_BIN, ["codegen"], {
      cwd: projectDir,
      timeout: config.timeouts.codegen,
    });

    if (result.exitCode !== 0) {
      console.error(`[${name}] codegen failed:`, result.stderr);
    }
    expect(result.exitCode).toBe(0);
  });

  it("type-checks successfully", async () => {
    // TypeScript templates don't have a build script, use tsc --noEmit to verify compilation
    const result = await runCommand("pnpm", ["exec", "tsc", "--noEmit"], {
      cwd: projectDir,
      timeout: config.timeouts.test,
    });

    if (result.exitCode !== 0) {
      console.error(`[${name}] type-check failed (exit code ${result.exitCode}):`);
      console.error(`[${name}] stdout:`, result.stdout);
      console.error(`[${name}] stderr:`, result.stderr);
    }
    expect(result.exitCode).toBe(0);
  });
});
