// Bindings to the native envio NAPI addon.
//
// Resolution order:
//   1. Production: require("envio-{os}-{arch}") — platform-specific npm package
//   2. Dev build:  find repo → cargo build --lib → load from target/debug/

type addon = {
  getConfigJson: (Nullable.t<string>, Nullable.t<string>, Nullable.t<string>) => string,
  runCli: (array<string>, Nullable.t<string>) => promise<string>,
  upsertPersistedState: string => promise<unit>,
}

@module("node:module") external createRequire: string => {..} = "createRequire"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external importMetaUrl: string = "import.meta.url"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:path") @variadic external pathResolve: array<string> => string = "resolve"
@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:child_process")
external execSyncRaw: (string, {..}) => string = "execSync"
@val external processPlatform: string = "process.platform"
@val external processArch: string = "process.arch"

// No-ops keep the `node:fs` / `node:child_process` imports alive for the
// %raw loadDevAddon block, which references them as Nodefs / Nodechild_process.
let _keepFs = existsSync
let _keepCp = execSyncRaw

let callRequire: ({..}, string) => addon = %raw(`(req, id) => req(id)`)

let envioPackageDir = pathDirname(pathDirname(fileURLToPath(importMetaUrl)))

// Local dev: find repo root, cargo build (if sources changed), load from target/debug/.
// Skips `cargo build --lib` when the built .so/.dylib/.dll is newer than
// every .rs in packages/cli/src/ and packages/cli/Cargo.toml. Cargo's own
// incremental build is usually <1s but the NAPI entrypoint still pays for
// process spawn + dependency graph walk on every command — skipping the
// spawn entirely drops ~400–800ms per invocation in tight dev loops.
// Set ENVIO_FORCE_REBUILD=1 to bypass the cache.
let loadDevAddon: ({..}, string) => addon = %raw(`function(req, envioDir) {
  var cp = Nodechild_process;
  var path = Nodepath;
  var fs = Nodefs;

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
    var result;
    try {
      result = cp.execSync("pnpm list envio --json", {
        encoding: "utf8", timeout: 10000,
        stdio: ["ignore", "pipe", "ignore"],
      });
    } catch (e) { return null; }

    var parsed;
    try {
      // pnpm list sometimes emits stray commas around the JSON object when
      // run from inside the workspace; strip them before parsing.
      var s = result.trim();
      if (s.startsWith(",")) s = s.slice(1);
      if (s.endsWith(",")) s = s.slice(0, -1);
      parsed = JSON.parse(s);
    } catch (e) { return null; }

    var ver;
    try {
      var pkg = Array.isArray(parsed) ? parsed[0] : parsed;
      ver = (pkg.dependencies || pkg.devDependencies || {}).envio.version;
    } catch (e) { return null; }

    if (!ver || !ver.startsWith("file:")) return null;
    repoRoot = path.resolve(path.resolve(ver.replace("file:", "")), "..", "..");
    if (!fs.existsSync(path.join(repoRoot, "packages", "cli", "Cargo.toml"))) return null;
  }

  var cliDir = path.join(repoRoot, "packages", "cli");
  var libName = process.platform === "darwin" ? "libenvio.dylib"
    : process.platform === "win32" ? "envio.dll" : "libenvio.so";
  var srcPath = path.join(repoRoot, "target", "debug", libName);
  var nodePath = path.join(repoRoot, "target", "debug", "envio.node");

  // Is the built .so newer than every source file under packages/cli?
  // Returns false if srcPath is missing.
  var isBuildFresh = function() {
    if (!fs.existsSync(srcPath)) return false;
    var builtMtime = fs.statSync(srcPath).mtimeMs;
    var sources = [
      path.join(cliDir, "Cargo.toml"),
      path.join(cliDir, "build.rs"),
    ];
    var srcDir = path.join(cliDir, "src");
    var templatesDir = path.join(cliDir, "templates");
    var stack = [srcDir];
    if (fs.existsSync(templatesDir)) stack.push(templatesDir);
    while (stack.length) {
      var d = stack.pop();
      var entries;
      try { entries = fs.readdirSync(d, { withFileTypes: true }); }
      catch (e) { continue; }
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var p = path.join(d, e.name);
        if (e.isDirectory()) stack.push(p);
        else sources.push(p);
      }
    }
    for (var j = 0; j < sources.length; j++) {
      try {
        if (fs.statSync(sources[j]).mtimeMs > builtMtime) return false;
      } catch (e) { /* missing file — ignore */ }
    }
    return true;
  };

  var force = process.env.ENVIO_FORCE_REBUILD === "1";
  if (force || !isBuildFresh()) {
    try {
      cp.execSync("cargo build --lib", { cwd: cliDir, stdio: "inherit" });
    } catch (e) {
      throw new Error("Failed to build envio NAPI addon. Run 'cargo build --lib' in " + cliDir + " manually.");
    }
    if (!fs.existsSync(srcPath)) {
      throw new Error("cargo build succeeded but " + srcPath + " not found.");
    }
  }

  if (!fs.existsSync(nodePath) || fs.statSync(nodePath).mtimeMs < fs.statSync(srcPath).mtimeMs) {
    fs.copyFileSync(srcPath, nodePath);
  }

  return req(nodePath);
}`)

let loadAddon = () => {
  let req = createRequire(importMetaUrl)
  let platformPkg = `envio-${processPlatform}-${processArch}`

  // 1. Platform package (production + CI via .pnpmfile.cjs redirect)
  try {
    callRequire(req, platformPkg)
  } catch {
  | _ =>
    // 2. Dev build (cargo build on every run)
    switch loadDevAddon(req, envioPackageDir)->(Utils.magic: addon => option<addon>) {
    | Some(addon) => addon
    | None =>
      JsError.throwWithMessage(`Couldn't load the envio native addon. Install the envio npm package.`)
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
