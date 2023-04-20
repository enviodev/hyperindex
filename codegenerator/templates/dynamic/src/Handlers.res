let getDefaultHandler: (string, 'a, 'b) => unit = (handlerName, _, _) => {
  Js.Console.warn(
    // TODO: link to our docs.
    `${handlerName} was not registered, ignoring event. Please register a handler for this event using the register${handlerName}.`,
  )
}

{{#each contracts as | contract |}}
module {{contract.name.capitalized}}Contract = {
    %%private(
      {{#each contract.events as | event |}}
      let {{event.name.uncapitalized}}LoadEntities = ref(None)
      let {{event.name.uncapitalized}}Handler = ref(None)
      {{/each}}
  )

  {{#each contract.events as | event |}}
  let register{{event.name.capitalized}}LoadEntities = (handler: (Types.eventLog<Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs>,
Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.loaderContext
) => unit) => {
    {{event.name.uncapitalized}}LoadEntities := Some(handler)
}
{{/each}}

{{#each contract.events as | event |}}
let register{{event.name.capitalized}}Handler = (handler: (
  Types.eventLog<Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs>,
  Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.context,
) => unit) => {
  {{event.name.uncapitalized}}Handler := Some(handler)
}
{{/each}}

{{#each contract.events as | event |}}
let get{{event.name.capitalized}}LoadEntities = () =>
{{event.name.uncapitalized}}LoadEntities.contents->Belt.Option.getWithDefault(getDefaultHandler("{{event.name.uncapitalized}}LoadEntities"))
{{/each}}

{{#each contract.events as | event |}}
let get{{event.name.capitalized}}Handler = () => 
{{event.name.uncapitalized}}Handler.contents->Belt.Option.getWithDefault(getDefaultHandler("{{event.name.uncapitalized}}Handler"))
{{/each}}
}

{{/each}}

