%%raw(`globalThis.fetch = require('node-fetch')`)

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
overrideConsoleLog(Logging.logger)

RegisterHandlers.registerAllHandlers()

open Express

let app = expressCjs()

app->use(jsonMiddleware())

let port = Config.metricsPort

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

type args = {@as("sync-from-raw-events") syncFromRawEvents?: bool}

type mainArgs = Yargs.parsedArgs<args>

let main = async () => {
  // let mainArgs: mainArgs = Node.Process.argv->Yargs.hideBin->Yargs.yargs->Yargs.argv
  //
  // let shouldSyncFromRawEvents = mainArgs.syncFromRawEvents->Belt.Option.getWithDefault(false)
  //
  // EventSyncing.startSyncingAllEvents(~shouldSyncFromRawEvents)
  let chainManager = await ChainManager.makeFromDbState(~configs=Config.config)

  let globalState: GlobalState.t = {
    currentlyProcessingBatch: false,
    chainManager,
    maxBatchSize: Env.maxProcessBatchSize,
    maxPerChainQueueSize: Env.maxPerChainQueueSize,
  }

  let gsManager = globalState->GlobalStateManager.make

  gsManager->GlobalStateManager.dispatchTask(NextQuery(CheckAllChains))

  /*
    NOTE:
      This `ProcessEventBatch` dispatch shouldn't be necessary but we are adding for safety, it should immediately return doing 
      nothing since there is no events on the queues.
  */
  gsManager->GlobalStateManager.dispatchTask(ProcessEventBatch) 
}

main()->ignore
