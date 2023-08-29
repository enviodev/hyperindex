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

let main = () => {
  EventSyncing.startSyncingAllEvents()
}

main()

