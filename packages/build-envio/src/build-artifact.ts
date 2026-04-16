/**
 * Builds the envio npm artifact ready for publishing.
 *
 * Steps:
 * 1. Compiles ReScript sources (in-source, inside packages/envio)
 * 2. Copies publish-worthy files into a dist directory
 * 3. Writes a publish-ready package.json into dist
 *
 * Usage:
 *   node src/build-artifact.ts --version <version> [--platform-pkg-version <version>] [--out <dir>]
 *
 * The source envio package is never mutated; output goes to --out (default: packages/envio/dist).
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { execSync } from "node:child_process";
import { parseArgs } from "node:util";

// ── Types ────────────────────────────────────────────────────────────

export type BuildOptions = {
  version: string;
  /** Version for platform-specific optional deps. Defaults to `version`. */
  platformPkgVersion?: string;
  /** Absolute path to the envio package. Defaults to packages/envio. */
  envioDir?: string;
  /** Absolute path to the output dist directory. Defaults to <envioDir>/dist. */
  outDir?: string;
  /** Absolute path to the README to copy. Defaults to packages/cli/README.md. */
  readmePath?: string;
  /** Skip ReScript compilation (useful for tests). */
  skipRescript?: boolean;
};

// ── Helpers ──────────────────────────────────────────────────────────

const REPO_ROOT = path.resolve(
  import.meta.dirname ?? path.dirname(new URL(import.meta.url).pathname),
  "../../../"
);

export const ENVIO_DIR = path.join(REPO_ROOT, "packages/envio");

const README_PATH = path.join(REPO_ROOT, "packages/cli/README.md");

/** Files/dirs to copy from envio package into dist. */
const PUBLISH_FILES = [
  "evm.schema.json",
  "fuel.schema.json",
  "svm.schema.json",
  "rescript.json",
  "index.d.ts",
  "index.js",
  "src",
];

/** Files to copy into the platform packages (envio-{os}-{arch}). */
const PLATFORM_PKG_FILES = ["bin/envio"] as const;

// ── Core logic ──────────────────────────────────────────────────────

/**
 * Builds the publish-ready package.json from the dev package.json.
 * Returns the new package.json contents as an object.
 */
export function buildPackageJson(
  devPkg: Record<string, unknown>,
  version: string,
  platformPkgVersion: string
): Record<string, unknown> {
  const pkg: Record<string, unknown> = { ...devPkg };

  // Set version, remove dev-only fields
  pkg.version = version;
  delete pkg.private;
  delete pkg.scripts;

  // Keep bin pointing to bin.mjs (same path as dev, but production content)
  // Note: envio.node is listed in files but won't exist in the published
  // package (production gets the addon via envio-linux-x64). npm/pnpm
  // silently ignore missing files entries. In CI artifacts, envio.node IS
  // present and pnpm needs the files entry to install it.
  pkg.bin = "./bin.mjs";

  // Add optional platform-specific dependencies
  pkg.optionalDependencies = {
    "envio-linux-x64": platformPkgVersion,
    "envio-linux-arm64": platformPkgVersion,
    "envio-darwin-x64": platformPkgVersion,
    "envio-darwin-arm64": platformPkgVersion,
  };

  return pkg;
}

/**
 * Compiles ReScript sources in the envio directory.
 */
export function compileRescript(envioDir: string): void {
  console.log("Compiling ReScript...");
  // Use the rescript-legacy binary directly to avoid pnpm workspace detection issues.
  // With pnpm's default isolated layout, the bin is in envio's own node_modules.
  execSync("./node_modules/.bin/rescript-legacy", {
    cwd: envioDir,
    stdio: "inherit",
  });
  console.log("ReScript compilation complete.");
}

/**
 * Copies the README into the target directory.
 */
export function copyReadme(readmePath: string, destDir: string): void {
  const dest = path.join(destDir, "README.md");
  fs.copyFileSync(readmePath, dest);
  console.log(`Copied README to ${dest}`);
}

/**
 * Copies a file or directory recursively from src to dest.
 */
function copyRecursive(src: string, dest: string): void {
  const stat = fs.statSync(src);
  if (stat.isDirectory()) {
    fs.mkdirSync(dest, { recursive: true });
    for (const entry of fs.readdirSync(src)) {
      copyRecursive(path.join(src, entry), path.join(dest, entry));
    }
  } else {
    fs.copyFileSync(src, dest);
  }
}

/**
 * Copies publish-worthy files from envioDir into outDir.
 */
export function copyPublishFiles(envioDir: string, outDir: string): void {
  fs.mkdirSync(outDir, { recursive: true });
  for (const file of PUBLISH_FILES) {
    const src = path.join(envioDir, file);
    const dest = path.join(outDir, file);
    if (!fs.existsSync(src)) {
      throw new Error(`Required publish file not found: ${src}`);
    }
    copyRecursive(src, dest);
  }
}

/**
 * Runs the full build: compile ReScript, copy files to dist, write package.json, copy README.
 */
export function build(opts: BuildOptions): void {
  const envioDir = opts.envioDir ?? ENVIO_DIR;
  const outDir = opts.outDir ?? path.join(envioDir, "dist");
  const readmePath = opts.readmePath ?? README_PATH;
  const platformPkgVersion = opts.platformPkgVersion ?? opts.version;

  // 1. Compile ReScript (in-source, before copying)
  if (!opts.skipRescript) {
    compileRescript(envioDir);
  }

  // 2. Copy publish files to dist (bin.mjs is now the same for dev and
  //    production — it imports Core.res.mjs which resolves the NAPI addon)
  copyPublishFiles(envioDir, outDir);
  // Copy bin.mjs from source (no longer replaced with a production variant)
  fs.copyFileSync(path.join(envioDir, "bin.mjs"), path.join(outDir, "bin.mjs"));
  console.log(`Copied publish files to ${outDir}`);

  // 3. Write publish-ready package.json into dist
  const devPkg = JSON.parse(
    fs.readFileSync(path.join(envioDir, "package.json"), "utf-8")
  );
  const publishPkg = buildPackageJson(devPkg, opts.version, platformPkgVersion);
  fs.writeFileSync(
    path.join(outDir, "package.json"),
    JSON.stringify(publishPkg, null, 2) + "\n"
  );
  console.log(`Wrote publish package.json (version=${opts.version})`);

  // 5. Copy README
  copyReadme(readmePath, outDir);

  console.log("Build complete.");
}

// ── CLI entry point ──────────────────────────────────────────────────

function main(): void {
  // Strip the leading "--" that pnpm inserts when forwarding args via `pnpm build -- --version …`
  const args = process.argv.slice(2).filter((a) => a !== "--");
  const { values } = parseArgs({
    args,
    options: {
      version: { type: "string" },
      "platform-pkg-version": { type: "string" },
      out: { type: "string" },
      "skip-rescript": { type: "boolean", default: false },
    },
    strict: true,
  });

  if (!values.version) {
    console.error("Usage: build-artifact --version <version>");
    process.exit(1);
  }

  build({
    version: values.version,
    platformPkgVersion: values["platform-pkg-version"],
    outDir: values.out ? path.resolve(values.out) : undefined,
    skipRescript: values["skip-rescript"],
  });
}

// Only run CLI when executed directly (not imported)
if (
  process.argv[1] &&
  (process.argv[1].endsWith("build-artifact.ts") ||
    process.argv[1].endsWith("build-artifact.js"))
) {
  main();
}
