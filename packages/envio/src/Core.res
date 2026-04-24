// Resolution order:
//   1. Production: require("envio-{os}-{arch}") — platform-specific npm package
//   2. Dev build:  find repo → cargo build --lib → load from target/debug/

// NAPI encodes Rust `Option<T>` as `null | T` (never `undefined`), so the
// tighter `Null.t` captures the exact boundary shape.
type addon = {
  getConfigJson: (~configPath: Null.t<string>, ~directory: Null.t<string>) => string,
  runCli: (~args: array<string>, ~envioPackageDir: Null.t<string>) => promise<Null.t<string>>,
  upsertPersistedState: (~json: string) => promise<unit>,
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

// Keeps `node:fs` / `node:child_process` imports alive for the %raw
// loadDevAddon block, which references them as Nodefs / Nodechild_process.
let _keepFs = existsSync
let _keepCp = execSyncRaw

let callRequire: ({..}, string) => addon = %raw(`(req, id) => req(id)`)

let envioPackageDir = pathDirname(pathDirname(fileURLToPath(importMetaUrl)))

// Runs `cargo build` on every invocation (like `cargo run`).
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
  try {
    cp.execSync("cargo build --lib", { cwd: cliDir, stdio: "inherit" });
  } catch (e) {
    throw new Error("Failed to build envio NAPI addon. Run 'cargo build --lib' in " + cliDir + " manually.");
  }

  var libName = process.platform === "darwin" ? "libenvio.dylib"
    : process.platform === "win32" ? "envio.dll" : "libenvio.so";
  var srcPath = path.join(repoRoot, "target", "debug", libName);
  var nodePath = path.join(repoRoot, "target", "debug", "envio.node");
  if (!fs.existsSync(srcPath)) {
    throw new Error("cargo build succeeded but " + srcPath + " not found.");
  }

  if (!fs.existsSync(nodePath) || fs.statSync(nodePath).mtimeMs < fs.statSync(srcPath).mtimeMs) {
    fs.copyFileSync(srcPath, nodePath);
  }

  return req(nodePath);
}`)

// Returns "musl" when running on an Alpine-style (musl libc) Linux and "gnu"
// on glibc Linux. `process.report.header.glibcVersionRuntime` is only populated
// when Node was dynamically linked against glibc. Non-linux hosts return None.
let detectLinuxLibc: unit => option<string> = %raw(`function() {
  if (process.platform !== "linux") return undefined;
  try {
    var header = process.report.getReport().header;
    return header.glibcVersionRuntime ? "gnu" : "musl";
  } catch (e) { return undefined; }
}`)

let loadAddon = () => {
  let req = createRequire(importMetaUrl)
  let platformPkg = switch (processPlatform, detectLinuxLibc()) {
  | ("linux", Some("musl")) => `envio-linux-${processArch}-musl`
  | _ => `envio-${processPlatform}-${processArch}`
  }

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
    ~configPath=configPath->Null.fromOption,
    ~directory=directory->Null.fromOption,
  )
}

let runCli = args => {
  let addon = getAddon()
  addon.runCli(~args, ~envioPackageDir=Null.make(envioPackageDir))
}

let upsertPersistedState = json => {
  let addon = getAddon()
  addon.upsertPersistedState(~json)
}
