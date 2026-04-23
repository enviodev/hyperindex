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

let autoLoadFromSrcHandlers = async (~handlers: string, ~hasContractHandlers: bool) => {
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

  // When auto-load is the sole source of handlers and the directory matches
  // nothing, every event silently skips indexing — surface the misconfiguration.
  if handlerFiles->Array.length === 0 && !hasContractHandlers {
    Logging.warn(
      `No handler files found under \`${handlers}/\`. Add a handler file (e.g. \`${handlers}/MyContract.ts\`) or set the \`handlers\` path in your config to the directory that contains them.`,
    )
  }

  // Import handler files using absolute file:// URLs resolved from cwd
  let _ = await handlerFiles
  ->Array.map(file => {
    Utils.importPath(toImportUrl(file))->Promise.catch(exn => {
      let cause = exn->Utils.prettifyExn->Obj.magic
      Logging.errorWithExn(exn, `Failed to auto-load handler file: ${file}`)
      JsError.throwWithMessage(`Failed to auto-load handler file: ${file}. Cause: ${cause}`)
    })
  })
  ->Promise.all
}

// EVM re-runs `parseEventFiltersOrThrow` with the registered `where:` JSON so
// per-event filters propagate into `getEventFiltersOrThrow` / `filterByAddresses`
// — which is why `evmEventConfig` has to retain `sighash` and `indexedParams`.
// `dependsOnAddresses` is routed through `Internal.dependsOnAddresses` so the
// formula stays in sync with `EventConfigBuilder.build{Evm,Fuel}EventConfig`.
let applyRegistrations = (~config: Config.t): Config.t => {
  let newChainMap = config.chainMap->ChainMap.map(chain => {
    let newContracts = chain.contracts->Array.map(contract => {
      let newEvents = contract.events->Array.map(
        ev => {
          let isWildcard = HandlerRegister.isWildcard(
            ~contractName=ev.contractName,
            ~eventName=ev.name,
          )
          let handler = HandlerRegister.getHandler(
            ~contractName=ev.contractName,
            ~eventName=ev.name,
          )
          let contractRegister = HandlerRegister.getContractRegister(
            ~contractName=ev.contractName,
            ~eventName=ev.name,
          )
          switch config.ecosystem.name {
          | Fuel =>
            let fuelEv = ev->(Utils.magic: Internal.eventConfig => Internal.fuelEventConfig)

            ({
              ...fuelEv,
              isWildcard,
              handler,
              contractRegister,
              dependsOnAddresses: Internal.dependsOnAddresses(
                ~isWildcard,
                ~filterByAddresses=false,
              ),
            } :> Internal.eventConfig)
          | Evm =>
            let evmEv = ev->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)
            let eventFilters = HandlerRegister.getOnEventWhere(
              ~contractName=ev.contractName,
              ~eventName=ev.name,
            )
            let {getEventFiltersOrThrow, filterByAddresses} = LogSelection.parseEventFiltersOrThrow(
              ~eventFilters,
              ~sighash=evmEv.sighash,
              ~params=evmEv.indexedParams->Array.map(p => p.name),
              ~contractName=ev.contractName,
              ~probeChainId=chain.id,
              ~onEventBlockFilterSchema=config.ecosystem.onEventBlockFilterSchema,
              ~topic1=?evmEv.indexedParams
              ->Array.get(0)
              ->Option.map(EventConfigBuilder.buildTopicGetter),
              ~topic2=?evmEv.indexedParams
              ->Array.get(1)
              ->Option.map(EventConfigBuilder.buildTopicGetter),
              ~topic3=?evmEv.indexedParams
              ->Array.get(2)
              ->Option.map(EventConfigBuilder.buildTopicGetter),
            )

            ({
              ...evmEv,
              isWildcard,
              handler,
              contractRegister,
              getEventFiltersOrThrow,
              filterByAddresses,
              dependsOnAddresses: Internal.dependsOnAddresses(~isWildcard, ~filterByAddresses),
            } :> Internal.eventConfig)
          | Svm =>
            JsError.throwWithMessage(`SVM does not support indexer.onEvent or indexer.contractRegister. Use indexer.onSlot for per-slot handlers.`)
          }
        },
      )
      {...contract, events: newEvents}
    })
    {...chain, contracts: newContracts}
  })
  {...config, chainMap: newChainMap}
}

// `Config` never reads `HandlerRegister`. The only way to get a config that
// reflects registration state is through the returned value here.
let registerAllHandlers = async (~config: Config.t) => {
  HandlerRegister.startRegistration(~ecosystem=config.ecosystem, ~multichain=config.multichain)

  let hasContractHandlers =
    config.contractHandlers->Array.some(({handler}) => handler->Option.isSome)

  await autoLoadFromSrcHandlers(~handlers=config.handlers, ~hasContractHandlers)

  // Load contract-specific handlers
  let _ = await config.contractHandlers
  ->Array.map(({name, handler}) => {
    registerContractHandlers(~contractName=name, ~handler)
  })
  ->Promise.all

  let registrations = HandlerRegister.finishRegistration()
  (applyRegistrations(~config), registrations)
}
