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
let loadDevAddon: ({..}, string, string) => addon = %raw(`function(req, platformPkg, envioDir) {
  var cp = Nodechild_process;
  var path = Nodepath;
  var fs = Nodefs;

  // Walk up from envioDir looking for the repo root (has packages/cli/Cargo.toml).
  // Works whether envioDir is packages/envio or deep in node_modules/.pnpm/.
  var repoRoot = null;
  var dir = path.resolve(envioDir);
  for (var i = 0; i < 10; i++) {
    dir = path.dirname(dir);
    if (dir === path.dirname(dir)) break;
    if (fs.existsSync(path.join(dir, "packages", "cli", "Cargo.toml"))) {
      repoRoot = dir;
      break;
    }
  }

  if (!repoRoot) {
    // Not in the source repo — try pnpm list to find it
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
    repoRoot = path.resolve(envioSrc, "..", "..");

    if (!fs.existsSync(path.join(repoRoot, "packages", "cli", "Cargo.toml"))) {
      return null;
    }
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
    throw new Error("cargo build succeeded but " + localPath + " not found. Check Cargo.toml has crate-type = ['cdylib'].");
  }

  if (!fs.existsSync(nodePath) || fs.statSync(nodePath).mtimeMs < fs.statSync(localPath).mtimeMs) {
    fs.copyFileSync(localPath, nodePath);
  }

  process.env.ENVIO_NATIVE_ADDON_PATH = nodePath;
  return req(nodePath);
}`)

let envioPackageDir = pathDirname(pathDirname(fileURLToPath(importMetaUrl)))

// Try require from multiple contexts to handle pnpm's virtual store.
// In pnpm, import.meta.url resolves deep in node_modules/.pnpm/ where
// the platform package isn't linked. Requiring from cwd handles pnpm
// workspaces where deps are hoisted to the project root.
let makeCwdRequire: unit => {..} = %raw(`() => Nodemodule.createRequire(process.cwd() + "/package.json")`)

let tryRequire = (platformPkg): option<addon> => {
  let reqFromFile = createRequire(importMetaUrl)
  // 1. From file location (production npm install)
  try {
    Some(callRequire(reqFromFile, platformPkg))
  } catch {
  | _ =>
    // 2. From cwd (pnpm workspace)
    try {
      Some(callRequire(makeCwdRequire(), platformPkg))
    } catch {
    | _ =>
      // 3. Sibling .node file (CI artifact)
      let siblingNode = pathJoin2(envioPackageDir, "envio.node")
      try {
        Some(callRequire(reqFromFile, siblingNode))
      } catch {
      | _ => None
      }
    }
  }
}

let loadAddon = () => {
  let platformPkg = `envio-${processPlatform}-${processArch}`

  // Fast path: pre-resolved addon path from env (CI or parent process)
  let envAddonPath: option<string> = %raw(`process.env.ENVIO_NATIVE_ADDON_PATH || undefined`)
  switch envAddonPath {
  | Some(p) if existsSync(p) =>
    let req = createRequire(importMetaUrl)
    try {
      callRequire(req, p)
    } catch {
    | _ =>
      switch tryRequire(platformPkg) {
      | Some(addon) => addon
      | None =>
        switch loadDevAddon(createRequire(importMetaUrl), platformPkg, envioPackageDir)->(
          Utils.magic: addon => option<addon>
        ) {
        | Some(addon) => addon
        | None =>
          JsError.throwWithMessage(`Couldn't load the envio native addon. Install the envio npm package.`)
        }
      }
    }
  | _ =>
    switch tryRequire(platformPkg) {
    | Some(addon) => addon
    | None =>
      switch loadDevAddon(createRequire(importMetaUrl), platformPkg, envioPackageDir)->(
        Utils.magic: addon => option<addon>
      ) {
      | Some(addon) => addon
      | None =>
        JsError.throwWithMessage(`Couldn't load the envio native addon. Install the envio npm package.`)
      }
    }
  }
}

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
