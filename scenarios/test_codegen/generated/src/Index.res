RegisterHandlers.registerAllHandlers()

open Express

let app = expressCjs()

app->use(jsonMiddleware())

let port = 3000

app->get("/_healthz", (_req, res) => {
  let _ = res->sendStatus(200)
})

let _ = app->listen(port)

let main = () => {
  EventSyncing.startSyncingAllEvents()
  ->Promise.then(_ => EventSubscription.startWatchingEvents())
  ->ignore
}

main()
