/**
 * This function can be used to override the console.log (and related functions for users). This means these logs will also be available to the user
 */
let overrideConsoleLog: Pino.t => unit = %raw(`function (logger) {
    console.log = function() {
      var args = Array.from(arguments);

      logger.uinfo(args.length > 1 ? args : args[0])
    };
    console.info = console.log; // Use uinfo for both console.log and console.info

    console.debug = function() {
      var args = Array.from(arguments);

      logger.udebug(args.length > 1 ? args : args[0]);
    };
    console.warn = function() {
      var args = Array.from(arguments);

      logger.uwarn(args.length > 1 ? args : args[0]);
    };
    console.error = function() {
      var args = Array.from(arguments);

      logger.uerror(args.length > 1 ? args : args[0]);
    };
  }
`)
// overrideConsoleLog(Logging.logger)
open Express

let app = expressCjs()

app->use(jsonMiddleware())

let port = Env.metricsPort

app->get("/healthz", (_req, res) => {
  // this is the machine readable port used in kubernetes to check the health of this service.
  //   aditional health information could be added in the future (info about errors, back-offs, etc).
  let _ = res->sendStatus(200)
})

let _ = app->listen(port)

PromClient.collectDefaultMetrics()

app->get("/metrics", (_req, res) => {
  res->set("Content-Type", PromClient.defaultRegister->PromClient.getContentType)
  let _ =
    PromClient.defaultRegister
    ->PromClient.metrics
    ->Promise.thenResolve(metrics => res->endWithData(metrics))
})

type args = {
  @as("sync-from-raw-events") syncFromRawEvents?: bool,
  @as("tui-off") tuiOff?: bool,
}

type process
@val external process: process = "process"
@get external argv: process => 'a = "argv"

type mainArgs = Yargs.parsedArgs<args>

let makeAppState = (globalState: GlobalState.t): EnvioInkApp.appState => {
  open Belt
  {
    config: globalState.config,
    indexerStartTime: globalState.indexerStartTime,
    chains: globalState.chainManager.chainFetchers
    ->ChainMap.values
    ->Array.map(cf => {
      let {numEventsProcessed, fetchState, numBatchesFetched} = cf
      let latestFetchedBlockNumber = PartitionedFetchState.getLatestFullyFetchedBlock(
        fetchState,
      ).blockNumber
      let hasProcessedToEndblock = cf->ChainFetcher.hasProcessedToEndblock
      let currentBlockHeight =
        cf->ChainFetcher.hasProcessedToEndblock
          ? cf.chainConfig.endBlock->Option.getWithDefault(cf.currentBlockHeight)
          : cf.currentBlockHeight

      let progress: ChainData.progress = if hasProcessedToEndblock {
        // If the endblock has been reached then set the progress to synced.
        // if there's chains that have no events in the block range start->end,
        // it's possible there are no events in that block  range (ie firstEventBlockNumber = None)
        // This ensures TUI still displays synced in this case
        let {
          firstEventBlockNumber,
          latestProcessedBlock,
          timestampCaughtUpToHeadOrEndblock,
          numEventsProcessed,
        } = cf
        Synced({
          firstEventBlockNumber: firstEventBlockNumber->Option.getWithDefault(0),
          latestProcessedBlock: latestProcessedBlock->Option.getWithDefault(currentBlockHeight),
          timestampCaughtUpToHeadOrEndblock: timestampCaughtUpToHeadOrEndblock->Option.getWithDefault(
            Js.Date.now()->Js.Date.fromFloat,
          ),
          numEventsProcessed,
        })
      } else {
        switch cf {
        | {
            firstEventBlockNumber: Some(firstEventBlockNumber),
            latestProcessedBlock,
            timestampCaughtUpToHeadOrEndblock: Some(timestampCaughtUpToHeadOrEndblock),
          } =>
          let latestProcessedBlock =
            latestProcessedBlock->Option.getWithDefault(firstEventBlockNumber)
          Synced({
            firstEventBlockNumber,
            latestProcessedBlock,
            timestampCaughtUpToHeadOrEndblock,
            numEventsProcessed,
          })
        | {
            firstEventBlockNumber: Some(firstEventBlockNumber),
            latestProcessedBlock,
            timestampCaughtUpToHeadOrEndblock: None,
          } =>
          let latestProcessedBlock =
            latestProcessedBlock->Option.getWithDefault(firstEventBlockNumber)
          Syncing({
            firstEventBlockNumber,
            latestProcessedBlock,
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
          chainId: cf.chainConfig.chain->ChainMap.Chain.toChainId,
          endBlock: cf.chainConfig.endBlock,
          poweredByHyperSync: switch cf.chainConfig.syncSource {
          | HyperSync(_)
          | HyperFuel(_) => true
          | Rpc(_) => false
          },
        }: EnvioInkApp.chainData
      )
    }),
  }
}

let main = async () => {
  try {
    let config = RegisterHandlers.registerAllHandlers()
    let mainArgs: mainArgs = process->argv->Yargs.hideBin->Yargs.yargs->Yargs.argv
    let shouldUseTui = !(mainArgs.tuiOff->Belt.Option.getWithDefault(Env.tuiOffEnvVar))
    let chainManager = await ChainManager.makeFromDbState(~config)
    let globalState = GlobalState.make(~config, ~chainManager)
    let stateUpdatedHook = if shouldUseTui {
      let rerender = EnvioInkApp.startApp(makeAppState(globalState))
      Some(globalState => globalState->makeAppState->rerender)
    } else {
      None
    }
    let gsManager = globalState->GlobalStateManager.make(~stateUpdatedHook?)
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
      NodeJsLocal.process->NodeJsLocal.exitWithCode(Failure)
    }
  }
}

main()->ignore
