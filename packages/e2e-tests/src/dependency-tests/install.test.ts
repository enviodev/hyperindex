/**
 * Dependency Completeness E2E Test
 *
 * Packs the envio package, installs it in an isolated directory via npm,
 * and verifies that every external import in the compiled .res.mjs files
 * resolves against envio's declared dependencies.
 *
 * This catches undeclared dependencies that work inside the pnpm workspace
 * (due to hoisting) but break for end users who `npm install envio`.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { createRequire } from "module";
import fs from "fs";
import path from "path";
import os from "os";
import { config } from "../config.js";
import { runCommand } from "../utils/process.js";

/** Recursively collect files matching a suffix */
function collectFiles(dir: string, suffix: string): string[] {
  const results: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) results.push(...collectFiles(full, suffix));
    else if (entry.name.endsWith(suffix)) results.push(full);
  }
  return results;
}

/** Extract the npm package name from an ES import specifier */
function extractPackageName(specifier: string): string | null {
  // Skip relative, absolute, and node: builtins
  if (
    specifier.startsWith(".") ||
    specifier.startsWith("/") ||
    specifier.startsWith("node:")
  )
    return null;

  // Scoped: @scope/name/sub → @scope/name
  if (specifier.startsWith("@")) {
    const parts = specifier.split("/");
    return parts.length >= 2 ? `${parts[0]}/${parts[1]}` : null;
  }

  // Regular: name/sub → name
  return specifier.split("/")[0];
}

describe("envio dependency completeness", () => {
  let projectDir: string;

  beforeAll(async () => {
    projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "envio-dep-test-"));
    const envioDir = path.join(config.rootDir, "packages/envio");

    // Pack the envio package into a tarball
    const packResult = await runCommand(
      "npm",
      ["pack", "--pack-destination", projectDir],
      { cwd: envioDir, timeout: 30_000 }
    );
    if (packResult.exitCode !== 0) {
      console.error("npm pack failed:", packResult.stderr);
    }
    expect(packResult.exitCode).toBe(0);

    const tarball = fs
      .readdirSync(projectDir)
      .find((f) => f.endsWith(".tgz"));
    expect(tarball, "no .tgz tarball produced by npm pack").toBeDefined();

    // Create a minimal project that depends on the tarball
    fs.writeFileSync(
      path.join(projectDir, "package.json"),
      JSON.stringify({
        name: "dep-test",
        version: "0.0.0",
        private: true,
        dependencies: {
          envio: `./${tarball}`,
        },
      })
    );

    // Install with npm for true isolation (no pnpm workspace hoisting)
    const installResult = await runCommand("npm", ["install"], {
      cwd: projectDir,
      timeout: config.timeouts.install,
    });
    if (installResult.exitCode !== 0) {
      console.error("npm install failed:", installResult.stderr);
    }
    expect(installResult.exitCode).toBe(0);
  }, 300_000);

  afterAll(() => {
    if (projectDir && fs.existsSync(projectDir)) {
      fs.rmSync(projectDir, { recursive: true, force: true });
    }
  });

  it("all .res.mjs imports resolve against declared dependencies", () => {
    const envioDir = path.join(projectDir, "node_modules", "envio");
    const srcDir = path.join(envioDir, "src");
    expect(fs.existsSync(srcDir), "envio/src not found — was ReScript compiled before packing?").toBe(true);

    const mjsFiles = collectFiles(srcDir, ".res.mjs");
    expect(
      mjsFiles.length,
      "no .res.mjs files found — ReScript must be compiled before this test runs"
    ).toBeGreaterThan(0);

    // Resolve from the installed envio package location
    const envioRequire = createRequire(path.join(envioDir, "index.js"));

    // Match: import ... from "pkg", import "pkg", export ... from "pkg", import("pkg")
    const importPattern = /(?:from|import)\s*\(?["']([^"']+)["']/g;
    const checked = new Set<string>();
    const unresolvedMap = new Map<string, string[]>();

    for (const file of mjsFiles) {
      const content = fs.readFileSync(file, "utf-8");
      for (const match of content.matchAll(importPattern)) {
        const pkg = extractPackageName(match[1]);
        if (!pkg) continue;
        if (checked.has(pkg)) continue;
        checked.add(pkg);

        try {
          envioRequire.resolve(pkg);
        } catch {
          const relPath = path.relative(srcDir, file);
          if (!unresolvedMap.has(pkg)) unresolvedMap.set(pkg, []);
          unresolvedMap.get(pkg)!.push(relPath);
        }
      }
    }

    if (unresolvedMap.size > 0) {
      const details = [...unresolvedMap.entries()]
        .map(
          ([pkg, files]) =>
            `  "${pkg}" imported in:\n${files.map((f) => `    - ${f}`).join("\n")}`
        )
        .join("\n");

      expect.fail(
        `${unresolvedMap.size} package(s) imported in .res.mjs but not resolvable after install:\n${details}\n\n` +
          "Add these to packages/envio/package.json dependencies."
      );
    }
  });
});
