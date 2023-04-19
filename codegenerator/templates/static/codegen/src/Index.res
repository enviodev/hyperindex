let main = () => {
  // create provider from config rpc on each network
  // create filters for all contracts and events
  // interface for all the contracts that we need to parse
  // setup getLogs function on the provider
  // based on the address of the log parse the log with correct interface
  // convert to general eventType that the handler takes
  Config.config
  ->Js.Dict.values
  ->Belt.Array.forEach(chainConfig => {
    chainConfig->EventSyncing.processAllEvents->ignore
  })
}

main()
