// Bindings to the native envio NAPI addon.
//
// Source of truth for both bin.mjs (CLI entry) and Config.fromConfigView
// (in-process config loading). The addon is loaded once per process and
// cached by Node's module system.
//
// All Node builtins are imported via @module (compiles to ESM `import`)
// instead of require() which is unavailable in .mjs files.

type addon = {
  getConfigJson: (Nullable.t<string>, Nullable.t<string>, Nullable.t<string>) => string,
  runCli: (array<string>, Nullable.t<string>) => promise<int>,
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

// Call the require function returned by createRequire.
let callRequire: ({..}, string) => addon = %raw(`(req, id) => req(id)`)

// statSync().mtimeMs
let getMtimeMs: string => float = %raw(`
  (function() {
    var statSync = Nodefs.statSync;
    return function(p) { return statSync(p).mtimeMs; };
  })()
`)

let loadAddon = () => {
  let req = createRequire(importMetaUrl)

  // 1. Try platform-specific package (production npm install)
  let platformPkg = `envio-${processPlatform}-${processArch}`
  try {
    callRequire(req, platformPkg)
  } catch {
  | _ =>
    // 2. Try envio.node next to this file (CI artifact or bundled addon)
    let thisFile = fileURLToPath(importMetaUrl)
    let siblingNode = pathJoin2(pathDirname(thisFile), pathJoin2("..", "envio.node"))
    try {
      callRequire(req, siblingNode)
    } catch {
    | _ => {
        // 3. Try local dev build (cargo target/debug)
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

        let errMsg =
          "Couldn't load the envio native addon.\n" ++
          "  Platform package: " ++
          platformPkg ++
          " (not installed)\n" ++
          "  Sibling file: " ++
          siblingNode ++
          " (not found)\n" ++
          "  Local build: " ++
          localPath ++
          " (not found)\n" ++ "Run 'cargo build --lib' in packages/cli or install the envio npm package."

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
}

let addonRef: ref<option<addon>> = ref(None)

// The envio package directory, computed once from import.meta.url.
// Passed to Rust NAPI functions so get_envio_version can find the
// package without relying on current_exe or current_dir.
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
