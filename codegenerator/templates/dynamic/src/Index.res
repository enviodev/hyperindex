// TODO: this code will create duplicates :/ (no native way to do this in handlebars [stumped chatgpt at least])
//       - need to change the rust structure.
{{#each contracts as | contract |}}
%%raw(`
try {
  require("{{contract.handler.relative_to_generated_src}}")
} catch (e) {
  console.error(
    "Unable to find the handler file for {{contract.name.capitalized}}. Please place a file at "
  );
}
`)

{{/each}}

let main = () => {
 EventSyncing.startSyncingAllEvents()
  ->Promise.then(_ => EventSubscription.startWatchingEvents())
  ->ignore
  
}

main()
