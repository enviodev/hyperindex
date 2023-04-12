{{#each contracts as | contract |}}
module {{contract.name.capitalized}}Contract = {
{{#each contract.events as | event |}}
@module("../../src/EventHandlers.bs.js")
external {{event.name.uncapitalized}}LoadEntities: Types.eventLog<Types.{{contract.name.capitalized}}Contract.{{event.name.uncapitalized}}Event> => array<
  Types.entityRead,
> = "{{event.name.capitalized}}LoadEntities"

@module("../../src/EventHandlers.bs.js")
external {{event.name.uncapitalized}}Handler: (
  Types.eventLog<Types.{{contract.name.capitalized}}Contract.{{event.name.uncapitalized}}Event>,
  Types.context,
) => unit = "{{event.name.capitalized}}Handler"

{{/each}}
}

{{/each}}

