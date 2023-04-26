// TODO: this code will create duplicates :/ (no native way to do this in handlebars [stumped chatgpt at least])
//       - need to change the rust structure.
%%raw(`
try {
  require("../../src/EventHandlers.bs.js")
} catch (e) {
  console.error(
    "Unable to find the handler file for Gravatar. Please place a file at "
  );
}
`)

let main = () => {
  EventSyncing.startSyncingAllEvents()
  ->Promise.then(_ => EventSubscription.startWatchingEvents())
  ->ignore
}

main()
