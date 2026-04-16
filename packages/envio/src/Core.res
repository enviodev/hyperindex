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
@val external processCwd: unit => string = "process.cwd"

// Call the require function returned by createRequire.
let callRequire: ({..}, string) => addon = %raw(`(req, id) => req(id)`)

// statSync().mtimeMs
let getMtimeMs: string => float = %raw(`
  (function() {
    var statSync = Nodefs.statSync;
    return function(p) { return statSync(p).mtimeMs; };
  })()
`)

// Find the hyperindex repo root by looking for packages/cli/Cargo.toml.
// Tries multiple starting points because import.meta.url might resolve
// inside pnpm's content-addressable store (not the repo).
let findRepoRoot: unit => option<string> = %raw(`function() {
  var fs = Nodefs;
  var path = Nodepath;

  function walkUp(start) {
    var dir = start;
    for (var i = 0; i < 20; i++) {
      if (fs.existsSync(path.join(dir, "packages", "cli", "Cargo.toml"))) return dir;
      var parent = path.dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
    return null;
  }

  // 1. Walk up from cwd (works when running inside the repo)
  var fromCwd = walkUp(process.cwd());
  if (fromCwd) return fromCwd;

  // 2. Walk up from this file (works when file: dep points into the repo
  //    and pnpm didn't relocate to a separate store)
  var fromFile = walkUp(path.dirname(Nodeurl.fileURLToPath(import.meta.url)));
  if (fromFile) return fromFile;

  // 3. Decode pnpm store path. When envio is installed via file: protocol,
  //    pnpm encodes the source path in the directory name:
  //    envio@file+..+..+hyperindex+packages+envio_react-dom@...
  //    Decode: file+<path> where + = / (relative to project root)
  var thisFile = Nodeurl.fileURLToPath(import.meta.url);
  var parts = thisFile.split(path.sep);
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].startsWith("envio@file+")) {
      // Extract the file: path portion (before the first _)
      var encoded = parts[i].replace(/^envio@/, "");
      var filePart = encoded.split("_")[0];
      // file+..+..+hyperindex+packages+envio → ../../hyperindex/packages/envio
      var decoded = filePart.replace(/^file\+/, "").replace(/\+/g, path.sep);
      // Resolve relative to the project that installed envio.
      // Walk up from thisFile to find the project root (node_modules parent)
      for (var j = i - 1; j >= 0; j--) {
        if (parts[j] === "node_modules" || parts[j] === ".pnpm") {
          var projectRoot = parts.slice(0, j).join(path.sep) || path.sep;
          var envioSrc = path.resolve(projectRoot, decoded);
          var repoRoot = path.resolve(envioSrc, "..", "..");
          if (fs.existsSync(path.join(repoRoot, "packages", "cli", "Cargo.toml"))) {
            return repoRoot;
          }
          break;
        }
      }
      break;
    }
  }

  return undefined;
}`)

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
        // 3. Local dev: find the repo, build the addon, and load it.
        // Like `cargo run`, this always rebuilds if source changed
        // (cargo's incremental compilation makes no-op builds fast).
        let libName = if processPlatform === "darwin" {
          "libenvio.dylib"
        } else if processPlatform === "win32" {
          "envio.dll"
        } else {
          "libenvio.so"
        }

        switch findRepoRoot() {
        | Some(repoRoot) => {
            let cliDir = pathResolve([repoRoot, "packages", "cli"])
            let targetDebug = pathJoin2(repoRoot, pathJoin2("target", "debug"))
            let localPath = pathJoin2(targetDebug, libName)
            let nodePath = pathJoin2(targetDebug, "envio.node")

            // Always build — like cargo run, ensures fresh binary
            try {
              execSyncWith("cargo build --lib", {"cwd": cliDir, "stdio": "inherit"})
            } catch {
            | _ =>
              JsError.throwWithMessage(
                "Failed to build envio NAPI addon. Run 'cargo build --lib' in packages/cli manually.",
              )
            }

            // Copy to .node extension and load
            if existsSync(localPath) {
              let needsCopy = !existsSync(nodePath) || getMtimeMs(localPath) > getMtimeMs(nodePath)
              if needsCopy {
                copyFileSync(localPath, nodePath)
              }
              try {
                callRequire(req, nodePath)
              } catch {
              | _ =>
                JsError.throwWithMessage(
                  `Built addon at ${nodePath} but failed to load it. Check for missing shared libraries.`,
                )
              }
            } else {
              JsError.throwWithMessage(
                `cargo build succeeded but ${localPath} not found. Check Cargo.toml crate-type includes "cdylib".`,
              )
            }
          }
        | None =>
          JsError.throwWithMessage(
            "Couldn't load the envio native addon.\n" ++
            "  Platform package: " ++
            platformPkg ++
            " (not installed)\n" ++
            "  Sibling file: " ++
            siblingNode ++
            " (not found)\n" ++
            "  Local build: couldn't find hyperindex repo (looked from cwd and import.meta.url)\n" ++ "Run 'cargo build --lib' in packages/cli or install the envio npm package.",
          )
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
