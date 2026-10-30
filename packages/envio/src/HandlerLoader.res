@module("node:fs/promises")
external globIterator: string => Utils.asyncIterator<string> = "glob"

type tsHooksAddon = {
  loadTs: string => string,
  tsResolveCandidates: (string, Null.t<string>) => array<string>,
  tsNotFoundCandidates: (string, Null.t<string>, string) => array<string>,
}

@module("./TsModuleHooks.mjs")
external registerTsHooksWith: tsHooksAddon => unit = "register"

// The resolve hook calls into the addon, and loading the addon goes through
// the resolve hook, so the addon has to be loaded before the hooks exist.
let registerTsHooks = () => {
  let addon = Core.getAddon()
  registerTsHooksWith({
    loadTs: addon.loadTs,
    tsResolveCandidates: addon.tsResolveCandidates,
    tsNotFoundCandidates: addon.tsNotFoundCandidates,
  })
}

let isTypeScript = file => /\.m?tsx?$/->RegExp.test(file)

// Paths are relative to the project root, which is the working directory.
let toAbsolutePath = (file: string) =>
  NodeJs.Path.resolve([NodeJs.Process.cwd(), file])->NodeJs.Path.toString

let importHandler = async file => {
  if isTypeScript(file) {
    Core.getAddon().tsCheckHandlerFormat(toAbsolutePath(file))
  }
  await Utils.importPath(toAbsolutePath(file)->NodeJs.Url.pathToFileURL->NodeJs.Url.toString)
}

let registerContractHandlers = async (~logger, ~contractName, ~handler: option<string>) => {
  switch handler {
  | None => ()
  | Some(handlerPath) =>
    try {
      let _ = await importHandler(handlerPath)
    } catch {
    | exn =>
      let cause = exn->Utils.prettifyExn->Obj.magic
      logger->Logger.errorWithExn(
        `Failed to load handler file for contract ${contractName}: ${handlerPath}`,
        exn,
      )
      JsError.throwWithMessage(
        `Failed to load handler file for contract ${contractName}: ${handlerPath}. Cause: ${cause}`,
      )
    }
  }
}

let globAutoLoadFiles = async (~handlers) => {
  let srcPattern = `./${handlers}/**/*.{js,mjs,ts}`
  try {
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
      `Failed to glob src/handlers directory for auto-loading handlers. Pattern: ${srcPattern}. Error: ${exn
        ->Utils.prettifyExn
        ->Obj.magic}`,
    )
  }
}

let getAutoLoadFiles = async (~config: Config.t) =>
  switch config.subgraph {
  // A subgraph project's `src/` holds AssemblyScript mappings, not envio
  // handlers: auto-loading or type-checking them as TypeScript would fail.
  | Some(_) => []
  | None => await globAutoLoadFiles(~handlers=config.handlers)
  }

let typeCheck = async (~config: Config.t, ~logger, ~autoLoadFiles) => {
  // A contract's `handler:` may also be an auto-loaded file.
  let files =
    autoLoadFiles
    ->Array.concat(config.contractHandlers->Array.filterMap(({handler}) => handler))
    ->Array.filter(isTypeScript)
    ->Array.map(toAbsolutePath)
    ->Utils.Set.fromArray
    ->Utils.Set.toArray
  if files->Array.length > 0 {
    switch await HandlerTypeCheck.check(~cwd=NodeJs.Process.cwd(), ~files) {
    | TypeErrors(errors) =>
      JsError.throwWithMessage(
        `The handler type check found errors. Fix them to start the indexer:\n\n${errors}`,
      )
    | Skipped(warning) => logger->Logger.warn(warning)
    | Passed => ()
    }
  }
}

// `Config` holds only event definitions; handler + per-chain `where`
// registration state is layered on separately as `onEventRegistration`s by
// `HandlerRegister.finishRegistration`. This loads the user handler files
// (populating the global `HandlerRegister` registry as a side effect) and
// returns the resulting per-chain registrations.
// The subgraph runtime lives in this package but is never exported: it's
// reached only from here, when the resolved config carries a translated
// manifest.
let registerSubgraph: (
  JSON.t,
  ~isDev: bool,
  ~logger: Logger.t,
) => promise<unit> = %raw(`(subgraph, isDev, logger) =>
  import("./subgraph/runtime.ts").then((m) => m.registerSubgraph({ ...subgraph, isDev }, logger))`)

let registerAllHandlers = async (
  ~config: Config.t,
  ~logger,
  ~autoLoadFiles,
): HandlerRegister.registrationsByChainId => {
  HandlerRegister.startRegistration(~config, ~logger)
  registerTsHooks()

  switch config.subgraph {
  // Registered after the TypeScript hooks, so the subgraph runtime's own hooks
  // see a mapping first.
  | Some(subgraph) => await registerSubgraph(subgraph, ~isDev=config.isDev, ~logger)
  | None =>
    let _ = await autoLoadFiles
    ->Array.map(file => {
      importHandler(file)->Promise.catch(exn => {
        let cause = exn->Utils.prettifyExn->Obj.magic
        logger->Logger.errorWithExn(`Failed to auto-load handler file: ${file}`, exn)
        JsError.throwWithMessage(`Failed to auto-load handler file: ${file}. Cause: ${cause}`)
      })
    })
    ->Promise.all

    let _ = await config.contractHandlers
    ->Array.map(({name, handler}) => {
      registerContractHandlers(~logger, ~contractName=name, ~handler)
    })
    ->Promise.all
  }

  HandlerRegister.finishRegistration(~config)
}
