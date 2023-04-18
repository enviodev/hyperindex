{{#each contracts as | contract |}}
module {{contract.name.capitalized}}Contract = {
{{#each contract.events as | event |}}
@module("../../src/EventHandlers.bs.js")
external {{event.name.uncapitalized}}LoadEntities: (Types.eventLog<Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs>,
Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.loaderContext
) => array<
  Types.entityRead,
> = "{{contract.name.uncapitalized}}{{event.name.capitalized}}LoadEntities"

@module("../../src/EventHandlers.bs.js")
external {{event.name.uncapitalized}}Handler: (
  Types.eventLog<Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs>,
  Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.context,
) => unit = "{{contract.name.uncapitalized}}{{event.name.capitalized}}EventHandler"

{{/each}}
}

{{/each}}

