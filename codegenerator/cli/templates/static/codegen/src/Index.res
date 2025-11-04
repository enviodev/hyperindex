open Belt

type chainData = {
  chainId: float,
  poweredByHyperSync: bool,
  firstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Js.Date.t>,
  numEventsProcessed: int,
  latestFetchedBlockNumber: int,
  currentBlockHeight: int,
  numBatchesFetched: int,
  endBlock: option<int>,
  numAddresses: int,
}
@tag("status")
type state =
  | @as("disabled") Disabled({})
  | @as("initializing") Initializing({})
  | @as("active")
  Active({
      envioVersion: option<string>,
      chains: array<chainData>,
      indexerStartTime: Js.Date.t,
      isPreRegisteringDynamicContracts: bool,
      isUnorderedMultichainMode: bool,
      rollbackOnReorg: bool,
    })

let chainDataSchema = S.schema((s): chainData => {
  chainId: s.matches(S.float),
  poweredByHyperSync: s.matches(S.bool),
  firstEventBlockNumber: s.matches(S.option(S.int)),
  latestProcessedBlock: s.matches(S.option(S.int)),
  timestampCaughtUpToHeadOrEndblock: s.matches(S.option(S.datetime(S.string))),
  numEventsProcessed: s.matches(S.int),
  latestFetchedBlockNumber: s.matches(S.int),
  currentBlockHeight: s.matches(S.int),
  numBatchesFetched: s.matches(S.int),
  endBlock: s.matches(S.option(S.int)),
  numAddresses: s.matches(S.int),
})
let stateSchema = S.union([
  S.literal(Disabled({})),
  S.literal(Initializing({})),
  S.schema(s => Active({
    envioVersion: s.matches(S.option(S.string)),
    chains: s.matches(S.array(chainDataSchema)),
    indexerStartTime: s.matches(S.datetime(S.string)),
    // Keep the field, since Dev Console expects it to be present
    isPreRegisteringDynamicContracts: false,
    isUnorderedMultichainMode: s.matches(S.bool),
    rollbackOnReorg: s.matches(S.bool),
  })),
])

let startServer = (~getState, ~indexer: Indexer.t, ~isDevelopmentMode: bool) => {
  open Express

  let app = makeCjs()

  let consoleCorsMiddleware = (req, res, next) => {
    switch req.headers->Js.Dict.get("origin") {
    | Some(origin) if origin === Env.prodEnvioAppUrl || origin === Env.envioAppUrl =>
      res->setHeader("Access-Control-Allow-Origin", origin)
    | _ => ()
    }

    res->setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
    res->setHeader(
      "Access-Control-Allow-Headers",
      "Origin, X-Requested-With, Content-Type, Accept",
    )

    if req.method === Options {
      res->sendStatus(200)
    } else {
      next()
    }
  }
  app->useFor("/console", consoleCorsMiddleware)
  app->useFor("/metrics", consoleCorsMiddleware)

  app->get("/healthz", (_req, res) => {
    // this is the machine readable port used in kubernetes to check the health of this service.
    //   aditional health information could be added in the future (info about errors, back-offs, etc).
    res->sendStatus(200)
  })

  app->get("/console/state", (_req, res) => {
    let state = if isDevelopmentMode {
      getState()
    } else {
      Disabled({})
    }

    res->json(state->S.reverseConvertToJsonOrThrow(stateSchema))
  })

  app->post("/console/syncCache", (_req, res) => {
    if isDevelopmentMode {
      (indexer.persistence->Persistence.getInitializedStorageOrThrow).dumpEffectCache()
      ->Promise.thenResolve(_ => res->json(Boolean(true)))
      ->Promise.done
    } else {
      res->json(Boolean(false))
    }
  })

  PromClient.collectDefaultMetrics()

  app->get("/metrics", (_req, res) => {
    res->set("Content-Type", PromClient.defaultRegister->PromClient.getContentType)
    let _ =
      PromClient.defaultRegister
      ->PromClient.metrics
      ->Promise.thenResolve(metrics => res->endWithData(metrics))
  })

  let _ = app->listen(Env.serverPort)
}

type args = {@as("tui-off") tuiOff?: bool}

type process
@val external process: process = "process"
@get external argv: process => 'a = "argv"

type mainArgs = Yargs.parsedArgs<args>

let makeAppState = (globalState: GlobalState.t): EnvioInkApp.appState => {
  let chains =
    globalState.chainManager.chainFetchers
    ->ChainMap.values
    ->Array.map(cf => {
      let {numEventsProcessed, fetchState, numBatchesFetched} = cf
      let latestFetchedBlockNumber = Pervasives.max(fetchState->FetchState.bufferBlockNumber, 0)
      let hasProcessedToEndblock = cf->ChainFetcher.hasProcessedToEndblock
      let currentBlockHeight =
        cf->ChainFetcher.hasProcessedToEndblock
          ? cf.fetchState.endBlock->Option.getWithDefault(cf.currentBlockHeight)
          : cf.currentBlockHeight

      let progress: ChainData.progress = if hasProcessedToEndblock {
        // If the endblock has been reached then set the progress to synced.
        // if there's chains that have no events in the block range start->end,
        // it's possible there are no events in that block  range (ie firstEventBlockNumber = None)
        // This ensures TUI still displays synced in this case
        let {
          committedProgressBlockNumber,
          timestampCaughtUpToHeadOrEndblock,
          numEventsProcessed,
          firstEventBlockNumber,
        } = cf

        Synced({
          firstEventBlockNumber: firstEventBlockNumber->Option.getWithDefault(0),
          latestProcessedBlock: committedProgressBlockNumber,
          timestampCaughtUpToHeadOrEndblock: timestampCaughtUpToHeadOrEndblock->Option.getWithDefault(
            Js.Date.now()->Js.Date.fromFloat,
          ),
          numEventsProcessed,
        })
      } else {
        switch cf {
        | {
            committedProgressBlockNumber,
            timestampCaughtUpToHeadOrEndblock: Some(timestampCaughtUpToHeadOrEndblock),
            firstEventBlockNumber: Some(firstEventBlockNumber),
          } =>
          Synced({
            firstEventBlockNumber,
            latestProcessedBlock: committedProgressBlockNumber,
            timestampCaughtUpToHeadOrEndblock,
            numEventsProcessed,
          })
        | {
            committedProgressBlockNumber,
            timestampCaughtUpToHeadOrEndblock: None,
            firstEventBlockNumber: Some(firstEventBlockNumber),
          } =>
          Syncing({
            firstEventBlockNumber,
            latestProcessedBlock: committedProgressBlockNumber,
            numEventsProcessed,
          })
        | {firstEventBlockNumber: None} => SearchingForEvents
        }
      }

      (
        {
          progress,
          currentBlockHeight,
          latestFetchedBlockNumber,
          numBatchesFetched,
          chain: ChainMap.Chain.makeUnsafe(~chainId=cf.chainConfig.id),
          endBlock: cf.fetchState.endBlock,
          poweredByHyperSync: (cf.sourceManager->SourceManager.getActiveSource).poweredByHyperSync,
        }: EnvioInkApp.chainData
      )
    })
  {
    config: globalState.indexer.config,
    indexerStartTime: globalState.indexerStartTime,
    chains,
  }
}

// Function to open the URL in the browser
// @module("child_process")
// external exec: (string, (Js.Nullable.t<Js.Exn.t>, 'a, 'b) => unit) => unit = "exec"
// @module("process") external platform: string = "platform"
// let openConsole = () => {
//   let host = "https://envio.dev"
//   let command = switch platform {
//   | "win32" => "start"
//   | "darwin" => "open"
//   | _ => "xdg-open"
//   }
//   exec(`${command} ${host}/console`, (_, _, _) => ())
// }

let main = async () => {
  try {
    let mainArgs: mainArgs = process->argv->Yargs.hideBin->Yargs.yargs->Yargs.argv
    let shouldUseTui = !(mainArgs.tuiOff->Belt.Option.getWithDefault(Env.tuiOffEnvVar))
    // The most simple check to verify whether we are running in development mode
    // and prevent exposing the console to public, when creating a real deployment.
    let isDevelopmentMode = Env.Db.password === "testing"

    let indexer = Generated.getIndexer()

    let gsManagerRef = ref(None)

    let envioVersion =
      PersistedState.getPersistedState()->Result.mapWithDefault(None, p => Some(p.envioVersion))

    switch envioVersion {
    | Some(version) => Prometheus.Info.set(~version)
    | None => ()
    }
    Prometheus.RollbackEnabled.set(~enabled=indexer.config.shouldRollbackOnReorg)

    startServer(
      ~indexer,
      ~isDevelopmentMode,
      ~getState=() =>
        switch gsManagerRef.contents {
        | None => Initializing({})
        | Some(gsManager) => {
            let state = gsManager->GlobalStateManager.getState
            let appState = state->makeAppState
            Active({
              envioVersion,
              chains: appState.chains->Js.Array2.map(c => {
                let cf = state.chainManager.chainFetchers->ChainMap.get(c.chain)
                {
                  chainId: c.chain->ChainMap.Chain.toChainId->Js.Int.toFloat,
                  poweredByHyperSync: c.poweredByHyperSync,
                  latestFetchedBlockNumber: c.latestFetchedBlockNumber,
                  currentBlockHeight: c.currentBlockHeight,
                  numBatchesFetched: c.numBatchesFetched,
                  endBlock: c.endBlock,
                  firstEventBlockNumber: switch c.progress {
                  | SearchingForEvents => None
                  | Syncing({firstEventBlockNumber}) | Synced({firstEventBlockNumber}) =>
                    Some(firstEventBlockNumber)
                  },
                  latestProcessedBlock: switch c.progress {
                  | SearchingForEvents => None
                  | Syncing({latestProcessedBlock}) | Synced({latestProcessedBlock}) =>
                    Some(latestProcessedBlock)
                  },
                  timestampCaughtUpToHeadOrEndblock: switch c.progress {
                  | SearchingForEvents
                  | Syncing(_) =>
                    None
                  | Synced({timestampCaughtUpToHeadOrEndblock}) =>
                    Some(timestampCaughtUpToHeadOrEndblock)
                  },
                  numEventsProcessed: switch c.progress {
                  | SearchingForEvents => 0
                  | Syncing({numEventsProcessed})
                  | Synced({numEventsProcessed}) => numEventsProcessed
                  },
                  numAddresses: cf.fetchState->FetchState.numAddresses,
                }
              }),
              indexerStartTime: appState.indexerStartTime,
              isPreRegisteringDynamicContracts: false,
              rollbackOnReorg: indexer.config.shouldRollbackOnReorg,
              isUnorderedMultichainMode: switch indexer.config.multichain {
              | Unordered => true
              | Ordered => false
              },
            })
          }
        },
    )

    await indexer.persistence->Persistence.init(
      ~chainConfigs=indexer.config.chainMap->ChainMap.values,
    )

    let chainManager = await ChainManager.makeFromDbState(
      ~initialState=indexer.persistence->Persistence.getInitializedState,
      ~config=indexer.config,
      ~registrations=indexer.registrations,
      ~persistence=indexer.persistence,
    )
    let globalState = GlobalState.make(~indexer, ~chainManager, ~isDevelopmentMode, ~shouldUseTui)
    let stateUpdatedHook = if shouldUseTui {
      let rerender = EnvioInkApp.startApp(makeAppState(globalState))
      Some(globalState => globalState->makeAppState->rerender)
    } else {
      None
    }
    let gsManager = globalState->GlobalStateManager.make(~stateUpdatedHook?)
    gsManagerRef := Some(gsManager)
    gsManager->GlobalStateManager.dispatchTask(NextQuery(CheckAllChains))
    /*
    NOTE:
      This `ProcessEventBatch` dispatch shouldn't be necessary but we are adding for safety, it should immediately return doing 
      nothing since there is no events on the queues.
 */

    gsManager->GlobalStateManager.dispatchTask(ProcessEventBatch)
  } catch {
  | e => {
      e->ErrorHandling.make(~msg="Failed at initialization")->ErrorHandling.log
      NodeJs.process->NodeJs.exitWithCode(Failure)
    }
  }
}

main()->ignore
