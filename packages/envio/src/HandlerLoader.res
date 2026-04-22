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
      let cause = exn->Utils.prettifyExn->Obj.magic
      Logging.errorWithExn(
        exn,
        `Failed to load handler file for contract ${contractName}: ${handlerPath}`,
      )
      JsError.throwWithMessage(
        `Failed to load handler file for contract ${contractName}: ${handlerPath}. Cause: ${cause}`,
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
  let _ =
    await handlerFiles
    ->Array.map(file => {
      Utils.importPath(toImportUrl(file))->Promise.catch(exn => {
        let cause = exn->Utils.prettifyExn->Obj.magic
        Logging.errorWithExn(exn, `Failed to auto-load handler file: ${file}`)
        JsError.throwWithMessage(`Failed to auto-load handler file: ${file}. Cause: ${cause}`)
      })
    })
    ->Promise.all
}

// Register all handlers and return `(configWithRegistrations, registrations)`.
// The input `~config` is the pre-registration snapshot (from
// `Config.loadWithoutRegistrations`); the returned config applies
// `HandlerRegister` state to each event via the
// `rebuildWithRegistration` closure that `EventConfigBuilder` baked in
// at build time. `Config` itself never reads `HandlerRegister` — the
// knowledge of "post-registration config" lives here and flows to
// downstream callers via the return value.
let registerAllHandlers = async (~config: Config.t) => {
  HandlerRegister.startRegistration(~ecosystem=config.ecosystem, ~multichain=config.multichain)

  // Auto-load all .js files from src/handlers directory
  await autoLoadFromSrcHandlers(~handlers=config.handlers)

  // Load contract-specific handlers
  let _ =
    await config.contractHandlers
    ->Array.map(({name, handler}) => {
      registerContractHandlers(~contractName=name, ~handler)
    })
    ->Promise.all

  let registrations = HandlerRegister.finishRegistration()

  let newChainMap = config.chainMap->ChainMap.map(chain => {
    let newContracts = chain.contracts->Array.map(contract => {
      let newEvents = contract.events->Array.map(
        event => {
          let isWildcard = HandlerRegister.isWildcard(
            ~contractName=event.contractName,
            ~eventName=event.name,
          )
          let handler = HandlerRegister.getHandler(
            ~contractName=event.contractName,
            ~eventName=event.name,
          )
          let contractRegister = HandlerRegister.getContractRegister(
            ~contractName=event.contractName,
            ~eventName=event.name,
          )
          switch config.ecosystem.name {
          | Fuel =>
            let fuelEv = event->(Utils.magic: Internal.eventConfig => Internal.fuelEventConfig)

            (fuelEv.rebuildWithRegistration(
              ~isWildcard,
              ~handler,
              ~contractRegister,
            ) :> Internal.eventConfig)
          | Evm | Svm =>
            let evmEv = event->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)
            let eventFilters = HandlerRegister.getOnEventWhere(
              ~contractName=event.contractName,
              ~eventName=event.name,
            )

            (evmEv.rebuildWithRegistration(
              ~isWildcard,
              ~handler,
              ~contractRegister,
              ~eventFilters,
            ) :> Internal.eventConfig)
          }
        },
      )
      {...contract, events: newEvents}
    })
    {...chain, contracts: newContracts}
  })

  ({...config, chainMap: newChainMap}, registrations)
}
