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
  "sidecar.d.ts",
  "sidecar.js",
  "README.md",
  "licenses",
  "src",
];

// License files that must ship inside the licenses/ directory.
const REQUIRED_LICENSES = [
  "licenses/EULA.md",
  "licenses/LICENSE.md",
  "licenses/CLA.md",
  "licenses/README.md",
];

// Some .res.mjs files that must exist (proves ReScript compiled)
const REQUIRED_COMPILED = [
  "src/Envio.res.mjs",
  "src/Config.res.mjs",
  "src/Main.res.mjs",
  "src/Bin.res.mjs",
];

// tsc emit for the sidecar runtime, which the top-level sidecar.js/sidecar.d.ts re-export
const REQUIRED_SIDECAR_EMIT = ["src/sidecar/index.js", "src/sidecar/index.d.ts"];

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

  // Check license files shipped inside licenses/
  for (const file of REQUIRED_LICENSES) {
    if (!fs.existsSync(path.join(dir, file))) {
      errors.push(`Missing license file: ${file}`);
    }
  }

  // Check compiled ReScript files exist
  for (const file of REQUIRED_COMPILED) {
    if (!fs.existsSync(path.join(dir, file))) {
      errors.push(`Missing compiled file: ${file}`);
    }
  }

  for (const file of REQUIRED_SIDECAR_EMIT) {
    if (!fs.existsSync(path.join(dir, file))) {
      errors.push(`Missing sidecar TypeScript emit: ${file}`);
    }
  }

  // TypeScript resolves `./x.js` to `x.ts` before `x.d.ts`, so a shipped source
  // would be compiled under the user's own compiler settings instead of the
  // declaration being read.
  const sidecarDir = path.join(dir, "src", "sidecar");
  if (fs.existsSync(sidecarDir)) {
    for (const entry of fs.readdirSync(sidecarDir)) {
      if (entry.endsWith(".ts") && !entry.endsWith(".d.ts")) {
        errors.push(`Sidecar TypeScript source must not ship: src/sidecar/${entry}`);
      }
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
