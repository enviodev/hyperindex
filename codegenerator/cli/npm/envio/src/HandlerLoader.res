@module("node:fs/promises")
external globIterator: string => Utils.asyncIterator<string> = "glob"

let registerTsx = () => NodeJs.Module.register("tsx/esm", NodeJs.ImportMeta.url)

let registerContractHandlers = async (~contractName, ~handler: option<string>) => {
  switch handler {
  | None => ()
  | Some(handlerPath) =>
    try {
      let _ = await Utils.importPath(NodeJs.ImportMeta.resolve(handlerPath))
    } catch {
    | exn =>
      Logging.errorWithExn(exn, `Failed to load handler file for contract ${contractName}: ${handlerPath}`)
      Js.Exn.raiseError(
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
    files->Js.Array2.filter(file => {
      !(file->Js.String2.includes(".test.") || file->Js.String2.includes(".spec.") || file->Js.String2.includes("_test."))
    })
  } catch {
  | exn =>
    Js.Exn.raiseError(
      `Failed to glob src/handlers directory for auto-loading handlers. Pattern: ${srcPattern}. Before continuing, check that you're using Node.js >=22 version. Error: ${exn
          ->Utils.prettifyExn
          ->Obj.magic}`,
    )
  }

  // Since srcPattern is relative to project root,
  // we import using the file path directly (cwd is project root)
  let _ = await handlerFiles
    ->Js.Array2.map(file => {
      Utils.importPath(NodeJs.ImportMeta.resolve("./" ++ file))
      ->Promise.catch(exn => {
        Logging.errorWithExn(exn, `Failed to auto-load handler file: ${file}`)
        Js.Exn.raiseError(
          `Failed to auto-load handler file: ${file}`,
        )
      })
    })
    ->Promise.all
}

let registerAllHandlers = async (~config: Config.t) => {
  // Register tsx for TypeScript handler support before loading any handlers
  registerTsx()

  EventRegister.startRegistration(
    ~ecosystem=config.ecosystem,
    ~multichain=config.multichain,
  )

  // Auto-load all .js files from src/handlers directory
  await autoLoadFromSrcHandlers(~handlers=config.handlers)

  // Load contract-specific handlers
  let _ = await config.contractHandlers
    ->Js.Array2.map(({name, handler}) => {
      registerContractHandlers(~contractName=name, ~handler)
    })
    ->Promise.all

  EventRegister.finishRegistration()
}
