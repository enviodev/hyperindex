RegisterHandlers.registerAllHandlers()

open Express

let app = expressCjs()

app->use(jsonMiddleware())

let port = Config.healthCheckPort

app->get("/_healthz", (_req, res) => {
  let _ = res->sendStatus(200)
})

let _ = app->listen(port)

let main = () => {
  EventSyncing.startSyncingAllEvents()
}

main()

