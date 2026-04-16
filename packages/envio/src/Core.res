// Bindings to the native envio NAPI addon.
//
// Source of truth for both bin.mjs (CLI entry) and Config.fromConfigView
// (in-process config loading). The addon is loaded once per process and
// cached by Node's module system.
//
// Resolution order:
// 1. Platform-specific npm package (envio-{os}-{arch}) — production.
// 2. Local dev build at target/debug/ — after `cargo build --lib`.
// 3. Auto cargo-build fallback — runs `cargo build --lib` and retries.

@val external platform: string = "process.platform"
@val external arch: string = "process.arch"

type addon = {
  getConfigJson: (Nullable.t<string>, Nullable.t<string>) => string,
  runCli: array<string> => promise<int>,
}

// Load the NAPI addon. In production, the platform-specific package
// (e.g., envio-linux-x64) ships the .node file. In local dev, the
// cargo-built cdylib is at target/debug/. If neither exists, we
// attempt a one-time cargo build.
let loadAddon: unit => addon = %raw(`function() {
  const { createRequire } = require("node:module");
  const { fileURLToPath } = require("node:url");
  const path = require("node:path");
  const fs = require("node:fs");
  const { execSync } = require("node:child_process");

  const req = createRequire(import.meta.url);

  // 1. Try platform-specific package (production + CI)
  const platformPkg = "envio-" + process.platform + "-" + process.arch;
  try {
    return req(platformPkg);
  } catch {}

  // 2. Try local dev build.
  // This file lives at packages/envio/src/Core.res.mjs. Walk up to find
  // the repo root (3 levels: src → envio → packages → root) and the
  // cargo target directory. We use import.meta.url instead of
  // require.resolve("envio/...") because a package can't resolve itself.
  const thisFile = fileURLToPath(import.meta.url);
  const repoRoot = path.resolve(path.dirname(thisFile), "../../..");
  const cliDir = path.join(repoRoot, "packages", "cli");
  const targetDebug = path.join(repoRoot, "target", "debug");

  // cdylib output name varies by platform
  const libName = process.platform === "darwin"
    ? "libenvio.dylib"
    : process.platform === "win32"
      ? "envio.dll"
      : "libenvio.so";
  const localPath = path.join(targetDebug, libName);

  // Node requires .node extension for native addons. Copy the cdylib
  // with a clean .node name (symlinks with double extensions like
  // .so.node don't work — Node gets confused by the extension).
  const nodePath = path.join(targetDebug, "envio.node");

  function tryLoadLocal() {
    if (!fs.existsSync(localPath)) return null;
    try {
      if (!fs.existsSync(nodePath) || fs.statSync(nodePath).mtimeMs < fs.statSync(localPath).mtimeMs) {
        fs.copyFileSync(localPath, nodePath);
      }
      return req(nodePath);
    } catch { return null; }
  }

  // Try loading existing local build
  const local = tryLoadLocal();
  if (local) return local;

  // 3. Auto cargo-build fallback
  if (fs.existsSync(path.join(cliDir, "Cargo.toml"))) {
    try {
      console.log("Building envio NAPI addon (first run)...");
      execSync("cargo build --lib", {
        cwd: cliDir,
        stdio: "inherit",
      });
      const built = tryLoadLocal();
      if (built) return built;
    } catch {}
  }

  throw new Error(
    "Couldn't load the envio native addon. " +
    "Run 'cargo build --lib' in packages/cli or install the envio npm package."
  );
}`)

// Cached addon instance — loaded once per process.
let addonRef: ref<option<addon>> = ref(None)
let getAddon = () =>
  switch addonRef.contents {
  | Some(a) => a
  | None => {
      let a = loadAddon()
      addonRef := Some(a)
      a
    }
  }

let getConfigJson = (~configPath=?, ~directory=?) => {
  let addon = getAddon()
  addon.getConfigJson(configPath->Nullable.fromOption, directory->Nullable.fromOption)
}

let runCli = args => {
  let addon = getAddon()
  addon.runCli(args)
}
