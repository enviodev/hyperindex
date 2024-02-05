%%raw(`globalThis.fetch = require('node-fetch')`)

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

let main = () => {
  // let mainArgs: mainArgs = Node.Process.argv->Yargs.hideBin->Yargs.yargs->Yargs.argv
  //
  // let shouldSyncFromRawEvents = mainArgs.syncFromRawEvents->Belt.Option.getWithDefault(false)
  //
  // EventSyncing.startSyncingAllEvents(~shouldSyncFromRawEvents)
  let chainManager = ChainManager.make(
    ~maxQueueSize=Env.maxPerChainQueueSize,
    ~configs=Config.config,
    ~shouldSyncFromRawEvents=false,
  )

  let globalState: GlobalState.t = {
    currentlyProcessingBatch: false,
    chainManager,
    maxBatchSize: Env.maxProcessBatchSize,
    maxPerChainQueueSize: Env.maxPerChainQueueSize,
  }

  let gsManager = globalState->GlobalStateManager.make

  gsManager->GlobalStateManager.dispatchTask(NextQuery(CheckAllChainsRoot))
  gsManager->GlobalStateManager.dispatchTask(ProcessEventBatch)
}

main()
