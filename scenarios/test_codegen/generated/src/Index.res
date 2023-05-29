RegisterHandlers.registerAllHandlers()

let main = () => {
 
 EventSyncing.startSyncingAllEvents()
  ->Promise.then(_ => EventSubscription.startWatchingEvents())
  ->ignore
  
}

main()
