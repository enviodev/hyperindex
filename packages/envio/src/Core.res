// Bindings to the native envio NAPI addon.
//
// Source of truth for both Bin.run (CLI entry) and Config.fromConfigView
// (in-process config loading). The addon is loaded once per process and
// cached in addonRef.
//
// Resolution has two completely separate flows:
//   Production: require("envio-{os}-{arch}") → .node addon
//   Local dev:  pnpm list → find repo → cargo build --lib → load

type addon = {
  getConfigJson: (Nullable.t<string>, Nullable.t<string>, Nullable.t<string>) => string,
  runCli: (array<string>, Nullable.t<string>) => promise<string>,
  upsertPersistedState: string => promise<unit>,
}

// ESM-safe Node imports. @module compiles to top-level `import` statements.
// Some of these are used in %raw blocks via their compiled names (Nodefs,
// Nodechild_process, etc.). ReScript tree-shakes unused imports, so we
// ensure every module needed by %raw is also referenced in typed code.
@module("node:module") external createRequire: string => {..} = "createRequire"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external importMetaUrl: string = "import.meta.url"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:path") external pathJoin2: (string, string) => string = "join"
@module("node:path") @variadic external pathResolve: array<string> => string = "resolve"
@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:child_process")
external execSyncRaw: (string, {..}) => string = "execSync"
@val external processPlatform: string = "process.platform"
@val external processArch: string = "process.arch"

// Keep node:fs and node:child_process imports alive for %raw blocks.
// These no-ops are optimized away but prevent tree-shaking the imports.
let _keepFs = existsSync
let _keepCp = execSyncRaw

let callRequire: ({..}, string) => addon = %raw(`(req, id) => req(id)`)

// ── Local dev: find repo root via pnpm list, build, and load ──────
//
// This flow is ONLY used when the production paths fail (no platform
// package, no sibling .node). Production users never reach this code.
// It uses the same `pnpm list envio --json` approach as the old bin.mjs
// to reliably find the source repo regardless of cwd or pnpm store layout.
let loadDevAddon: ({..}, string) => addon = %raw(`function(req, platformPkg) {
  var cp = Nodechild_process;
  var path = Nodepath;
  var fs = Nodefs;

  var result;
  try {
    result = cp.execSync("pnpm list envio --json", {
      encoding: "utf8",
      timeout: 10000,
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch (e) {
    return null;
  }

  var parsed;
  try {
    var jsonStr = result.trim();
    if (jsonStr.startsWith(",")) jsonStr = jsonStr.slice(1);
    if (jsonStr.endsWith(",")) jsonStr = jsonStr.slice(0, -1);
    parsed = JSON.parse(jsonStr);
  } catch (e) {
    return null;
  }

  var envioVersion;
  try {
    var pkg = Array.isArray(parsed) ? parsed[0] : parsed;
    envioVersion = (pkg.dependencies || pkg.devDependencies || {}).envio.version;
  } catch (e) {
    return null;
  }

  if (!envioVersion || !envioVersion.startsWith("file:")) {
    return null;
  }

  var envioSrcRelative = envioVersion.replace("file:", "");
  var envioSrc = path.resolve(envioSrcRelative);
  var repoRoot = path.resolve(envioSrc, "..", "..");

  if (!fs.existsSync(path.join(repoRoot, "packages", "cli", "Cargo.toml"))) {
    return null;
  }

  var cliDir = path.join(repoRoot, "packages", "cli");
  try {
    cp.execSync("cargo build --lib", { cwd: cliDir, stdio: "inherit" });
  } catch (e) {
    throw new Error("Failed to build envio NAPI addon. Run 'cargo build --lib' in " + cliDir + " manually.");
  }

  var libName = process.platform === "darwin" ? "libenvio.dylib"
    : process.platform === "win32" ? "envio.dll"
    : "libenvio.so";
  var targetDebug = path.join(repoRoot, "target", "debug");
  var localPath = path.join(targetDebug, libName);
  var nodePath = path.join(targetDebug, "envio.node");

  if (!fs.existsSync(localPath)) {
    throw new Error("cargo build succeeded but " + localPath + " not found. Check Cargo.toml has crate-type = [\\"cdylib\\"].");
  }

  if (!fs.existsSync(nodePath) || fs.statSync(nodePath).mtimeMs < fs.statSync(localPath).mtimeMs) {
    fs.copyFileSync(localPath, nodePath);
  }

  process.env.ENVIO_NATIVE_ADDON_PATH = nodePath;
  return req(nodePath);
}`)

let setEnvVar: (string, string) => unit = %raw(`(k, v) => { process.env[k] = v; }`)
let resolveRequire: ({..}, string) => string = %raw(`(req, id) => req.resolve(id)`)

// Propagate the resolved .node path via env var so forked processes
// (vitest forks, pnpm install sub-processes) can skip resolution.
let propagateAddonPath = (req, id) =>
  try {
    setEnvVar("ENVIO_NATIVE_ADDON_PATH", resolveRequire(req, id))
  } catch {
  | _ => ()
  }

let loadAddonFromPaths = (req, platformPkg) => {
  // 1. Platform-specific package (envio-linux-x64, envio-darwin-arm64)
  try {
    let addon = callRequire(req, platformPkg)
    propagateAddonPath(req, platformPkg)
    addon
  } catch {
  | _ =>
    // 2. Sibling .node file (CI artifact injected post-install)
    let thisFile = fileURLToPath(importMetaUrl)
    let siblingNode = pathJoin2(pathDirname(thisFile), pathJoin2("..", "envio.node"))
    try {
      let addon = callRequire(req, siblingNode)
      setEnvVar("ENVIO_NATIVE_ADDON_PATH", siblingNode)
      addon
    } catch {
    | _ =>
      // 3. Local dev: pnpm list → cargo build → load
      switch loadDevAddon(req, platformPkg)->(Utils.magic: addon => option<addon>) {
      | Some(addon) => addon
      | None =>
        JsError.throwWithMessage(
          `Couldn't load the envio native addon.\n` ++
          `Tried:\n` ++
          `  1. require("${platformPkg}") — not installed\n` ++
          `  2. ${siblingNode} — not found\n` ++
          `  3. Local dev build via pnpm list — envio is not a local file: dependency\n` ++
          `Install the envio npm package, or if developing locally, ensure envio is\n` ++ `installed via file: protocol and cargo/pnpm are available.`,
        )
      }
    }
  }
}

let loadAddon = () => {
  let req = createRequire(importMetaUrl)
  let platformPkg = `envio-${processPlatform}-${processArch}`

  // Check env var first — set by parent process after successful load.
  // Vitest forks and template tests in temp dirs may not resolve the
  // platform package, but inherit this env var from the parent.
  let envAddonPath: option<string> = %raw(`process.env.ENVIO_NATIVE_ADDON_PATH || undefined`)
  switch envAddonPath {
  | Some(p) if existsSync(p) =>
    try {
      callRequire(req, p)
    } catch {
    | _ => loadAddonFromPaths(req, platformPkg)
    }
  | _ => loadAddonFromPaths(req, platformPkg)
  }
}

let addonRef: ref<option<addon>> = ref(None)

let envioPackageDir = pathDirname(pathDirname(fileURLToPath(importMetaUrl)))

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
  addon.getConfigJson(
    configPath->Nullable.fromOption,
    directory->Nullable.fromOption,
    Nullable.Value(envioPackageDir),
  )
}

let runCli = args => {
  let addon = getAddon()
  addon.runCli(args, Nullable.Value(envioPackageDir))
}

let upsertPersistedState = json => {
  let addon = getAddon()
  addon.upsertPersistedState(json)
}
