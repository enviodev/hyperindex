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
  { name: "EVM Greeter", ecosystem: "evm", template: "Greeter" },
  { name: "EVM ERC20", ecosystem: "evm", template: "Erc20" },
  { name: "EVM Factory", ecosystem: "evm", template: "Factory" },
  { name: "Fuel Greeter", ecosystem: "fuel", template: "Greeter" },
];

describe.each(TEMPLATES)("Template: $name", ({ name, ecosystem, template }) => {
  let testDir: string;
  const projectName = `test-${ecosystem}-${template.toLowerCase()}`;

  beforeAll(async () => {
    // Create a temporary directory for this test
    testDir = await fs.mkdtemp(path.join(os.tmpdir(), `envio-template-test-`));
  });

  afterAll(async () => {
    // Clean up the temporary directory
    if (testDir) {
      await fs.rm(testDir, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("generates template with envio init", async () => {
    const result = await runCommand(
      "pnpm",
      [
        "envio",
        "init",
        projectName,
        "--template",
        template,
        "--language",
        "typescript",
        "--ecosystem",
        ecosystem,
      ],
      {
        cwd: testDir,
        timeout: config.timeouts.codegen,
        env: {
          ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
        },
      }
    );

    expect(result.exitCode).toBe(0);

    // Verify project was created
    const projectPath = path.join(testDir, projectName);
    const exists = await fs
      .access(projectPath)
      .then(() => true)
      .catch(() => false);
    expect(exists).toBe(true);
  });

  it("installs dependencies", async () => {
    const projectPath = path.join(testDir, projectName);

    const result = await runCommand("pnpm", ["install"], {
      cwd: projectPath,
      timeout: config.timeouts.install,
    });

    expect(result.exitCode).toBe(0);
  });

  it("runs codegen successfully", async () => {
    const projectPath = path.join(testDir, projectName);

    const result = await runCommand("pnpm", ["codegen"], {
      cwd: projectPath,
      timeout: config.timeouts.codegen,
      env: {
        ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
      },
    });

    expect(result.exitCode).toBe(0);
  });

  it("passes TypeScript type check", async () => {
    const projectPath = path.join(testDir, projectName);

    const result = await runCommand("pnpm", ["tsc", "--noEmit"], {
      cwd: projectPath,
      timeout: config.timeouts.test,
    });

    expect(result.exitCode).toBe(0);
  });

  it("passes unit tests", async () => {
    const projectPath = path.join(testDir, projectName);

    const result = await runCommand("pnpm", ["test"], {
      cwd: projectPath,
      timeout: config.timeouts.test,
    });

    expect(result.exitCode).toBe(0);
  });
});
