// Bindings to the native envio NAPI addon.
//
// Source of truth for both bin.mjs (CLI entry) and Config.fromConfigView
// (in-process config loading). The addon is loaded once per process and
// cached by Node's module system.
//
// All Node builtins are imported via @module (compiles to ESM `import`)
// instead of require() which is unavailable in .mjs files.

type addon = {
  getConfigJson: (Nullable.t<string>, Nullable.t<string>) => string,
  runCli: array<string> => promise<int>,
}

// ESM-safe Node imports
@module("node:module") external createRequire: string => {..} = "createRequire"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external importMetaUrl: string = "import.meta.url"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:path") external pathJoin2: (string, string) => string = "join"
@module("node:path") @variadic external pathResolve: array<string> => string = "resolve"
@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:fs") external copyFileSync: (string, string) => unit = "copyFileSync"
@module("node:child_process")
external execSyncWith: (string, {"cwd": string, "stdio": string}) => unit = "execSync"
@val external processPlatform: string = "process.platform"
@val external processArch: string = "process.arch"

// Call the require function returned by createRequire. We can't type
// this in ReScript because require is a callable object (function +
// properties) — so we use a thin %raw wrapper that receives the
// already-imported createRequire result.
let callRequire: ({..}, string) => addon = %raw(`(req, id) => req(id)`)

// statSync().mtimeMs — single-purpose helper to avoid binding the
// full Stats type.
let getMtimeMs: string => float = %raw(`
  (function() {
    // Import at definition time (module scope) so it's captured once.
    // This IIFE runs during module evaluation where the ESM import
    // (Nodefs) is already available.
    var statSync = Nodefs.statSync;
    return function(p) { return statSync(p).mtimeMs; };
  })()
`)

let loadAddon = () => {
  let req = createRequire(importMetaUrl)

  // 1. Try platform-specific package (production + CI)
  let platformPkg = `envio-${processPlatform}-${processArch}`
  try {
    callRequire(req, platformPkg)
  } catch {
  | _ => {
      // 2. Try local dev build
      let thisFile = fileURLToPath(importMetaUrl)
      let repoRoot = pathResolve([pathDirname(thisFile), "..", "..", ".."])
      let cliDir = pathResolve([repoRoot, "packages", "cli"])
      let targetDebug = pathJoin2(repoRoot, pathJoin2("target", "debug"))

      let libName = if processPlatform === "darwin" {
        "libenvio.dylib"
      } else if processPlatform === "win32" {
        "envio.dll"
      } else {
        "libenvio.so"
      }
      let localPath = pathJoin2(targetDebug, libName)
      let nodePath = pathJoin2(targetDebug, "envio.node")

      let tryLoadLocal = () =>
        if existsSync(localPath) {
          try {
            let needsCopy = !existsSync(nodePath) || getMtimeMs(localPath) > getMtimeMs(nodePath)
            if needsCopy {
              copyFileSync(localPath, nodePath)
            }
            Some(callRequire(req, nodePath))
          } catch {
          | _ => None
          }
        } else {
          None
        }

      let errMsg = "Couldn't load the envio native addon. Run 'cargo build --lib' in packages/cli or install the envio npm package."

      switch tryLoadLocal() {
      | Some(addon) => addon
      | None =>
        if existsSync(pathJoin2(cliDir, "Cargo.toml")) {
          try {
            Js.log("Building envio NAPI addon (first run)...")
            execSyncWith("cargo build --lib", {"cwd": cliDir, "stdio": "inherit"})
            switch tryLoadLocal() {
            | Some(addon) => addon
            | None => JsError.throwWithMessage(errMsg)
            }
          } catch {
          | _ => JsError.throwWithMessage(errMsg)
          }
        } else {
          JsError.throwWithMessage(errMsg)
        }
      }
    }
  }
}

let addonRef: ref<option<addon>> = ref(None)

// Tell the Rust side where the envio package lives. This is needed
// because `get_envio_version` walks up from current_exe/current_dir
// to find packages/envio, but with NAPI the exe is Node (outside the
// repo) and cwd may be a temp dir (template tests). JS knows its own
// package path via import.meta.url, so we propagate it.
let setEnvVar: (string, string) => unit = %raw(`(k, v) => { process.env[k] = v; }`)
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

let ensureEnvioPackageDir = () => setEnvVar("ENVIO_PACKAGE_DIR", envioPackageDir)

let getConfigJson = (~configPath=?, ~directory=?) => {
  ensureEnvioPackageDir()
  let addon = getAddon()
  addon.getConfigJson(configPath->Nullable.fromOption, directory->Nullable.fromOption)
}

let runCli = args => {
  ensureEnvioPackageDir()
  let addon = getAddon()
  addon.runCli(args)
}
