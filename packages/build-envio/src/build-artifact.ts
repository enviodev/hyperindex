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

/** Production bin.mjs — resolves the platform-specific binary and spawns it. */
const PRODUCTION_BIN_MJS = `#!/usr/bin/env node
//@ts-check

import { spawnSync } from "child_process";
import { createRequire } from "module";
import { chmodSync, accessSync, constants } from "fs";

const require = createRequire(import.meta.url);

/**
 * Returns the executable path for envio located inside node_modules
 * The naming convention is envio-\${os}-\${arch}
 * If the platform is \`win32\` or \`cygwin\`, executable will include a \`.exe\` extension
 * @see https://nodejs.org/api/os.html#osarch
 * @see https://nodejs.org/api/os.html#osplatform
 * @example "x/xx/node_modules/envio-darwin-arm64"
 */
function getExePath() {
  const arch = process.arch;
  /**
   * @type {string}
   */
  let os = process.platform;
  let extension = "";
  if (["win32", "cygwin"].includes(process.platform)) {
    os = "windows";
    extension = ".exe";
  }

  const pkg = \`envio-\${os}-\${arch}\`;
  const bin = \`bin/envio\${extension}\`;

  try {
    return require.resolve(\`\${pkg}/\${bin}\`);
  } catch {}

  throw new Error(
    \`Couldn't find envio binary package "\${pkg}".\\n\` +
      \`Checked: require.resolve("\${pkg}/\${bin}")\\n\` +
      \`If you're using pnpm, yarn, or npm with --omit=optional, ensure optional \` +
      \`dependencies are installed:\\n\` +
      \`  npm install \${pkg}\\n\`
  );
}

/**
 * npm/pnpm may strip execute permissions from the binary during install.
 * Ensure the binary is executable before spawning it.
 */
function ensureExecutable(filePath) {
  try {
    accessSync(filePath, constants.X_OK);
  } catch {
    chmodSync(filePath, 0o755);
  }
}

/**
 * Runs \`envio\` with args using nodejs spawn
 */
function runEnvio() {
  const args = process.argv.slice(2);
  const exePath = getExePath();
  ensureExecutable(exePath);

  const processResult = spawnSync(exePath, args, { stdio: "inherit" });

  if (processResult.error) {
    console.error(\`Failed to run envio binary at \${exePath}: \${processResult.error.message}\`);
    process.exit(1);
  }
  process.exit(processResult.status ?? 1);
}

runEnvio();
`;

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
  // Use the rescript binary directly to avoid pnpm workspace detection issues
  execSync("./node_modules/.bin/rescript", {
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

  // 2. Copy publish files to dist
  copyPublishFiles(envioDir, outDir);
  console.log(`Copied publish files to ${outDir}`);

  // 3. Write production bin.mjs (replaces the dev version)
  fs.writeFileSync(path.join(outDir, "bin.mjs"), PRODUCTION_BIN_MJS);
  console.log("Wrote production bin.mjs");

  // 4. Write publish-ready package.json into dist
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
