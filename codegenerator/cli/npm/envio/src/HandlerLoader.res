@module("node:fs/promises")
external globIterator: string => Utils.asyncIterator<string> = "glob"

// Register tsx for TypeScript handler support
// Wrapped in try-catch because if tsx is already loaded via --import (e.g., in tests),
// calling module.register again will throw an error
try {
  NodeJs.Module.register("tsx/esm", NodeJs.ImportMeta.url)
} catch {
| _ => () // tsx already loaded, ignore
}

// Convert a relative path to a file:// URL for dynamic import
// Paths are resolved relative to process.cwd() (project root)
let toImportUrl = (relativePath: string) => {
  let absolutePath = NodeJs.Path.resolve([NodeJs.Process.cwd(), relativePath])->NodeJs.Path.toString
  NodeJs.Url.pathToFileURL(absolutePath)->NodeJs.Url.toString
}

let registerContractHandlers = async (~contractName, ~handler: option<string>) => {
  switch handler {
  | None => ()
  | Some(handlerPath) =>
    try {
      let _ = await Utils.importPath(toImportUrl(handlerPath))
    } catch {
    | exn =>
      Logging.errorWithExn(
        exn,
        `Failed to load handler file for contract ${contractName}: ${handlerPath}`,
      )
      JsError.throwWithMessage(
        `Failed to load handler file for contract ${contractName}: ${handlerPath}`,
      )
    }
  }
}

let autoLoadFromSrcHandlers = async (~handlers: string) => {
  // Relative to cwd (project root)
  let srcPattern = `./${handlers}/**/*.{js,mjs,ts}`
  let handlerFiles = try {
    let iterator = globIterator(srcPattern)
    let files = await iterator->Utils.Array.fromAsyncIterator
    // Filter out test and spec files
    files->Array.filter(file => {
      !(
        file->String.includes(".test.") ||
        file->String.includes(".spec.") ||
        file->String.includes("_test.")
      )
    })
  } catch {
  | exn =>
    JsError.throwWithMessage(
      `Failed to glob src/handlers directory for auto-loading handlers. Pattern: ${srcPattern}. Before continuing, check that you're using Node.js >=22 version. Error: ${exn
        ->Utils.prettifyExn
        ->Obj.magic}`,
    )
  }

  // Import handler files using absolute file:// URLs resolved from cwd
  let _ = await handlerFiles
  ->Array.map(file => {
    Utils.importPath(toImportUrl(file))->Promise_.catch(exn => {
      Logging.errorWithExn(exn, `Failed to auto-load handler file: ${file}`)
      JsError.throwWithMessage(`Failed to auto-load handler file: ${file}`)
    })
  })
  ->Promise_.all
}

// Register all handlers - must be called BEFORE creating the final config
// so that event registrations are captured in the config
let registerAllHandlers = async (~config: Config.t) => {
  EventRegister.startRegistration(~ecosystem=config.ecosystem, ~multichain=config.multichain)

  // Auto-load all .js files from src/handlers directory
  await autoLoadFromSrcHandlers(~handlers=config.handlers)

  // Load contract-specific handlers
  let _ = await config.contractHandlers
  ->Array.map(({name, handler}) => {
    registerContractHandlers(~contractName=name, ~handler)
  })
  ->Promise_.all

  EventRegister.finishRegistration()
}
