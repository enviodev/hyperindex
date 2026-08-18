import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

// Left to itself, every one of the ~60 worker forks runs `cargo build --lib`
// (Core.res's `loadDevAddon`) and may copy a ~600MB addon into place. Cargo
// serialises those on its own file locks, so a fork can sit inside a
// synchronous build for tens of seconds — and a fork blocked in `execSync`
// cannot answer vitest's teardown request, so vitest kills it. The file it was
// running drops out of the totals with no failure to show for it. Building
// here, once, before any fork exists, also settles which addon they all load:
// the per-fork path decides freshness by mtime and can hand a worker a binary
// older than the sources it is meant to be testing.
function buildDevAddon(): void {
  const repoRoot = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "..",
    "..",
    "..",
    ".."
  );
  const cliDir = path.join(repoRoot, "packages", "cli");
  if (!fs.existsSync(path.join(cliDir, "Cargo.toml"))) {
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
  process.env.ENVIO_DEV_ADDON = nodePath;
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
