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

// Native `throw` so we can re-raise a caught JS error preserving its stack,
// `code`, and any other fields a diagnostic might rely on.
let rethrow: JsExn.t => 'a = %raw(`function(e) { throw e }`)

let loadAddon = () => {
  let req = createRequire(importMetaUrl)

  // npm's `libc` field installs only the matching package on Linux, so the
  // wrong name throws MODULE_NOT_FOUND immediately and the next candidate
  // wins. An empty list means the host isn't a publish target.
  let candidates = switch (processPlatform, processArch) {
  | ("linux", "x64") => [`envio-linux-x64`, `envio-linux-x64-musl`]
  | ("linux", "arm64") => [`envio-linux-arm64`]
  | ("darwin", "x64") => [`envio-darwin-x64`]
  | ("darwin", "arm64") => [`envio-darwin-arm64`]
  | _ => []
  }

  // Only swallow MODULE_NOT_FOUND (the optional package isn't installed on
  // this host). Any other failure — corrupt .node, ABI mismatch, dlopen
  // error — is a real load failure and must surface.
  let rec tryRequire = i =>
    switch candidates[i] {
    | None => None
    | Some(pkg) =>
      try Some(callRequire(req, pkg)) catch {
      | exn =>
        switch exn->JsExn.anyToExnInternal {
        | JsExn(e) if (e->(Utils.magic: JsExn.t => {..}))["code"] === "MODULE_NOT_FOUND" =>
          tryRequire(i + 1)
        | JsExn(e) => rethrow(e)
        | _ => throw(exn)
        }
      }
    }

  switch tryRequire(0) {
  | Some(addon) => addon
  | None =>
    // Dev build fallback (cargo build on every run)
    switch loadDevAddon(req, envioPackageDir)->(Utils.magic: addon => option<addon>) {
    | Some(addon) => addon
    | None =>
      let host = `${processPlatform}-${processArch}`
      let msg = if candidates->Array.length === 0 {
        `envio doesn't support ${host}. Supported: linux-x64 (glibc/musl), linux-arm64, darwin-x64, darwin-arm64.`
      } else {
        `Couldn't load the envio native addon for ${host}. Reinstall envio (ensure optional dependencies aren't skipped).`
      }
      JsError.throwWithMessage(msg)
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
