/**
 * Dependency Completeness Test
 *
 * Validates that every external npm module imported via @module("...") in
 * the envio package's ReScript source is declared in envio's package.json.
 *
 * This catches undeclared dependencies that work inside the pnpm workspace
 * (due to hoisting) but break for end users who install envio standalone.
 */

import { describe, it, expect } from "vitest";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, "../../../..");
const envioDir = path.join(rootDir, "packages/envio");

/** Collect all .res files recursively */
function collectResFiles(dir: string): string[] {
  const results: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...collectResFiles(full));
    } else if (entry.name.endsWith(".res")) {
      results.push(full);
    }
  }
  return results;
}

/** Node.js built-in modules (no need to declare in package.json) */
const NODE_BUILTINS = new Set([
  "assert",
  "buffer",
  "child_process",
  "cluster",
  "crypto",
  "dgram",
  "dns",
  "events",
  "fs",
  "http",
  "http2",
  "https",
  "module",
  "net",
  "os",
  "path",
  "perf_hooks",
  "process",
  "querystring",
  "readline",
  "stream",
  "string_decoder",
  "timers",
  "tls",
  "tty",
  "url",
  "util",
  "v8",
  "vm",
  "wasi",
  "worker_threads",
  "zlib",
]);

/**
 * Modules that are expected to be provided by the consumer (generated project),
 * not by envio itself. These are peer dependencies in spirit.
 */
const PEER_MODULES = new Set(["vitest"]);

/** Extract the npm package name from a module specifier */
function toPackageName(specifier: string): string | null {
  // Skip relative imports
  if (specifier.startsWith(".") || specifier.startsWith("/")) return null;
  // Skip node: prefixed builtins
  if (specifier.startsWith("node:")) return null;

  // Scoped package: @scope/name/sub → @scope/name
  if (specifier.startsWith("@")) {
    const parts = specifier.split("/");
    return parts.length >= 2 ? `${parts[0]}/${parts[1]}` : null;
  }

  // Regular package: name/sub → name
  return specifier.split("/")[0];
}

describe("envio package dependency completeness", () => {
  it("all @module imports should be declared in package.json", () => {
    const pkgJson = JSON.parse(
      fs.readFileSync(path.join(envioDir, "package.json"), "utf-8")
    );
    const declared = new Set(Object.keys(pkgJson.dependencies ?? {}));

    const resFiles = collectResFiles(path.join(envioDir, "src"));
    const modulePattern = /@module\("([^"]+)"\)/g;

    const undeclared = new Map<string, string[]>();

    for (const file of resFiles) {
      const content = fs.readFileSync(file, "utf-8");
      let match;
      while ((match = modulePattern.exec(content)) !== null) {
        const specifier = match[1];
        const pkgName = toPackageName(specifier);
        if (!pkgName) continue;
        if (NODE_BUILTINS.has(pkgName)) continue;
        if (PEER_MODULES.has(pkgName)) continue;
        if (declared.has(pkgName)) continue;

        const relPath = path.relative(rootDir, file);
        if (!undeclared.has(pkgName)) {
          undeclared.set(pkgName, []);
        }
        undeclared.get(pkgName)!.push(relPath);
      }
    }

    if (undeclared.size > 0) {
      const details = [...undeclared.entries()]
        .map(
          ([pkg, files]) =>
            `  "${pkg}" imported in:\n${files.map((f) => `    - ${f}`).join("\n")}`
        )
        .join("\n");

      expect.fail(
        `Found ${undeclared.size} undeclared dependency(ies) in packages/envio/package.json:\n${details}\n\n` +
          `These modules are imported via @module() in ReScript but not listed in envio's dependencies.\n` +
          `This works in the monorepo (pnpm hoists them) but breaks for end users.`
      );
    }
  });
});
