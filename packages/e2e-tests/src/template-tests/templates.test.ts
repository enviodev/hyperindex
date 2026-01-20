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
  language: "typescript" | "rescript";
}

// Get envio binary path
const ENVIO_BIN = path.join(
  config.rootDir,
  "codegenerator/target/release/envio"
);

// All available templates to test
const TEMPLATES: TemplateConfig[] = [
  // EVM Templates - TypeScript
  {
    name: "evm-greeter-ts",
    initArgs: ["template", "-t", "greeter", "-l", "typescript"],
    language: "typescript",
  },
  {
    name: "evm-erc20-ts",
    initArgs: ["template", "-t", "erc20", "-l", "typescript"],
    language: "typescript",
  },
  {
    name: "evm-factory-ts",
    initArgs: ["template", "-t", "feature-factory", "-l", "typescript"],
    language: "typescript",
  },
  // EVM Templates - ReScript
  {
    name: "evm-greeter-res",
    initArgs: ["template", "-t", "greeter", "-l", "rescript"],
    language: "rescript",
  },
  {
    name: "evm-erc20-res",
    initArgs: ["template", "-t", "erc20", "-l", "rescript"],
    language: "rescript",
  },
  {
    name: "evm-factory-res",
    initArgs: ["template", "-t", "feature-factory", "-l", "rescript"],
    language: "rescript",
  },
  // Fuel Templates
  {
    name: "fuel-greeter-ts",
    initArgs: ["fuel", "template", "-t", "greeter", "-l", "typescript"],
    language: "typescript",
  },
  {
    name: "fuel-greeter-res",
    initArgs: ["fuel", "template", "-t", "greeter", "-l", "rescript"],
    language: "rescript",
  },
  // SVM Templates
  {
    name: "svm-block-handler-ts",
    initArgs: ["svm", "template", "-t", "feature-block-handler", "-l", "typescript"],
    language: "typescript",
  },
  {
    name: "svm-block-handler-res",
    initArgs: ["svm", "template", "-t", "feature-block-handler", "-l", "rescript"],
    language: "rescript",
  },
];

describe.each(TEMPLATES)("Template: $name", ({ name, initArgs, language }) => {
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
    const result = await runCommand(
      ENVIO_BIN,
      ["init", "-n", name, "-d", projectDir, ...initArgs],
      {
        cwd: projectDir,
        timeout: config.timeouts.codegen,
        env: {
          ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
        },
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
    // For ReScript projects, run rescript build first
    if (language === "rescript") {
      const resResult = await runCommand("pnpm", ["res:build"], {
        cwd: projectDir,
        timeout: config.timeouts.test,
      });

      if (resResult.exitCode !== 0) {
        console.error(`[${name}] rescript build failed:`, resResult.stderr);
      }
      expect(resResult.exitCode).toBe(0);
    }

    const result = await runCommand("pnpm", ["build"], {
      cwd: projectDir,
      timeout: config.timeouts.test,
    });

    if (result.exitCode !== 0) {
      console.error(`[${name}] build failed:`, result.stderr);
    }
    expect(result.exitCode).toBe(0);
  });
});
