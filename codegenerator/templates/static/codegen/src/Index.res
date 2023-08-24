RegisterHandlers.registerAllHandlers()

open Express

let app = expressCjs()

app->use(jsonMiddleware())

let port = Config.expressPort

let _ = app->listen(port)

let main = () => {
  EventSyncing.startSyncingAllEvents()
}

main()

