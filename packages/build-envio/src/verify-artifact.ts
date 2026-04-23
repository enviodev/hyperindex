#!/usr/bin/env node
/**
 * Verifies that a built envio artifact directory is complete and correct.
 *
 * Usage:
 *   node src/verify-artifact.ts <artifact-dir>
 */

import * as fs from "node:fs";
import * as path from "node:path";

const REQUIRED_FILES = [
  "package.json",
  "bin.mjs",
  "evm.schema.json",
  "fuel.schema.json",
  "svm.schema.json",
  "rescript.json",
  "index.d.ts",
  "index.js",
  "README.md",
  "src",
];

// Some .res.mjs files that must exist (proves ReScript compiled)
const REQUIRED_COMPILED = [
  "src/Envio.res.mjs",
  "src/Config.res.mjs",
  "src/Main.res.mjs",
  "src/Bin.res.mjs",
];

function verify(dir: string): void {
  const errors: string[] = [];

  // Check all required files/dirs exist
  for (const file of REQUIRED_FILES) {
    if (!fs.existsSync(path.join(dir, file))) {
      errors.push(`Missing: ${file}`);
    }
  }

  // Check no unexpected top-level files/dirs leaked in.
  // The native addon ships via the envio-{os}-{arch} platform package,
  // never bundled in the envio package itself.
  const allowed = new Set(REQUIRED_FILES);
  for (const entry of fs.readdirSync(dir)) {
    if (!allowed.has(entry)) {
      errors.push(`Unexpected file in artifact: ${entry}`);
    }
  }

  // Check compiled ReScript files exist
  for (const file of REQUIRED_COMPILED) {
    if (!fs.existsSync(path.join(dir, file))) {
      errors.push(`Missing compiled file: ${file}`);
    }
  }

  // Validate package.json
  const pkgPath = path.join(dir, "package.json");
  if (fs.existsSync(pkgPath)) {
    let pkg: Record<string, unknown> | undefined;
    try {
      pkg = JSON.parse(fs.readFileSync(pkgPath, "utf-8"));
    } catch (e) {
      errors.push(`package.json read/parse error: ${(e as Error).message} for ${pkgPath}`);
    }
    if (pkg) {
      if (pkg.private) errors.push("package.json still has private: true");
      if (pkg.bin !== "./bin.mjs") errors.push(`package.json bin is "${pkg.bin}", expected "./bin.mjs"`);
      if (!pkg.optionalDependencies) errors.push("package.json missing optionalDependencies");
      if (!pkg.dependencies) errors.push("package.json missing dependencies");
      if (pkg.devDependencies) errors.push("package.json still has devDependencies");
      const deps = pkg.dependencies as Record<string, unknown> | undefined;
      if (deps && "rescript" in deps) {
        errors.push("package.json dependencies must not include 'rescript' (compiler is build-time only)");
      }
    }
  }

  if (errors.length > 0) {
    console.error("Artifact verification failed:");
    for (const e of errors) console.error(`  - ${e}`);
    process.exit(1);
  }

  console.log(`Artifact verified: ${dir}`);
}

const dir = process.argv[2];
if (!dir) {
  console.error("Usage: verify-artifact <artifact-dir>");
  process.exit(1);
}
verify(path.resolve(dir));
