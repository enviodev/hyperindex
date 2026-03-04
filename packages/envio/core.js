/* eslint-disable */

/**
 * Loads the platform-specific native module (envio.node).
 *
 * Resolution order:
 *   1. Platform package installed as optional dependency (envio-{os}-{arch})
 *   2. Local envio.node next to this file (CI artifacts or local dev build)
 *   3. Auto-compile from source via cargo build (dev convenience)
 */

import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { existsSync, copyFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { platform, arch } from "node:process";

const require = createRequire(import.meta.url);
const __dirname = import.meta.dirname ?? dirname(fileURLToPath(import.meta.url));
// Resolve symlinks so we find the real repo when installed via pnpm link / file: protocol
const __realdir = realpathSync(__dirname);

const PLATFORM_MAP = {
  darwin: "darwin",
  linux: "linux",
};

const ARCH_MAP = {
  x64: "x64",
  arm64: "arm64",
};

function loadNativeModule() {
  const os = PLATFORM_MAP[platform];
  const cpu = ARCH_MAP[arch];

  if (!os || !cpu) {
    throw new Error(
      `Unsupported platform: ${platform}-${arch}. ` +
        `Supported: darwin-x64, darwin-arm64, linux-x64, linux-arm64`
    );
  }

  const pkgName = `envio-${os}-${cpu}`;

  // Try platform package first (installed via optionalDependencies)
  try {
    return require(`${pkgName}/envio.node`);
  } catch (_) {}

  // Fallback: local .node file (CI artifacts or local dev build)
  try {
    return require("./envio.node");
  } catch (_) {}

  // Also check the real path (pnpm installs via symlinks, so ./envio.node
  // relative to __dirname may not find the file at __realdir)
  if (__realdir !== __dirname) {
    try {
      return require(join(__realdir, "envio.node"));
    } catch (_) {}
  }

  // Auto-compile: build from source and copy the cdylib
  return buildAndLoad(os);
}

function buildAndLoad(os) {
  // Walk up from the real path (resolves pnpm symlinks) to find the workspace root
  let dir = __realdir;
  while (dir !== dirname(dir)) {
    if (existsSync(join(dir, "Cargo.toml")) && existsSync(join(dir, "packages", "cli"))) {
      break;
    }
    dir = dirname(dir);
  }
  if (dir === dirname(dir)) {
    throw new Error(
      "Cannot auto-compile: could not find workspace root with Cargo.toml. " +
        "Run 'cargo build --lib --features napi' manually from the repo root."
    );
  }

  const ext = os === "darwin" ? "dylib" : "so";
  const cdylib = join(dir, "target", "debug", `libenvio.${ext}`);
  const dest = join(__realdir, "envio.node");

  // Always run cargo build — it's a no-op (~200ms) when nothing changed,
  // but picks up source changes automatically (like cargo run would).
  execSync("cargo build --lib --features napi", {
    cwd: dir,
    stdio: "inherit",
  });

  copyFileSync(cdylib, dest);
  return require(dest);
}

const native = loadNativeModule();

export const run = native.run;
