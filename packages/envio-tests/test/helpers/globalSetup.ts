import { execSync } from "node:child_process";
import * as fs from "node:fs";
import { createRequire } from "node:module";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

// `Core.loadAddon` prefers the platform package over the dev build, so when
// one is installed (CI installs the prebuilt artifact) a cargo build here is
// minutes of work whose output is never loaded.
function hasPlatformAddon(): boolean {
  const envioRequire = createRequire(
    createRequire(import.meta.url).resolve("envio/package.json")
  );
  const base = `envio-${process.platform}-${process.arch}`;
  return [base, `${base}-musl`].some((pkg) => {
    try {
      envioRequire.resolve(pkg);
      return true;
    } catch {
      return false;
    }
  });
}

// Build the addon once before worker forks exist. Each fork otherwise runs
// `cargo build --lib` and can sit on cargo's lock through vitest's teardown.
function buildDevAddon(): void {
  if (hasPlatformAddon()) {
    return;
  }
  const repoRoot = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "..",
    "..",
    "..",
    ".."
  );
  const cliDir = path.join(repoRoot, "packages", "cli");
  // CI tests the pre-built addon (see .pnpmfile.cjs), which loadAddon picks
  // before any dev build, so compiling one here would only cost time.
  if (
    !fs.existsSync(path.join(cliDir, "Cargo.toml")) ||
    fs.existsSync(path.join(repoRoot, ".envio-artifacts"))
  ) {
    return;
  }

  execSync("cargo build --lib", { cwd: cliDir, stdio: "inherit" });

  const libName =
    process.platform === "darwin"
      ? "libenvio.dylib"
      : process.platform === "win32"
        ? "envio.dll"
        : "libenvio.so";
  const srcPath = path.join(repoRoot, "target", "debug", libName);
  const nodePath = path.join(repoRoot, "target", "debug", "envio.node");
  if (!fs.existsSync(srcPath)) {
    return;
  }
  if (
    !fs.existsSync(nodePath) ||
    fs.statSync(nodePath).mtimeMs < fs.statSync(srcPath).mtimeMs
  ) {
    fs.copyFileSync(srcPath, nodePath);
  }
}

// `fromUserApi` keeps its generated modules for the whole run so vitest
// can render code frames from them. Clearing here — once, before any worker
// starts — is what stops them accumulating, without a worker ever deleting a
// sibling worker's files mid-run.
export default function setup(): void {
  const tmpDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", ".tmp");
  fs.rmSync(tmpDir, { recursive: true, force: true });
  buildDevAddon();
}
