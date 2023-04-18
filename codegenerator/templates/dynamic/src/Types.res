//*************
//***ENTITIES**
//*************

type id = string

type entityRead = 
{{#each entities as | entity |}}
| {{entity.name.capitalized}}Read(id)
{{/each}}

let entitySerialize = (entity: entityRead) => {
  switch entity {
  {{#each entities as | entity |}}
  | {{entity.name.capitalized}}Read(id) => `{{entity.name.uncapitalized}}${id}`
  {{/each}}
  }
}

{{#each entities as | entity |}}
type {{entity.name.uncapitalized}}Entity = {
  {{#each entity.params as | param |}}
  {{param.key}} : {{param.type_}},
  {{/each}}
}

{{/each}}
type entity = 
{{#each entities as | entity |}}
  | {{entity.name.capitalized}}Entity({{entity.name.uncapitalized}}Entity)
{{/each}}



type crud = Create | Read | Update | Delete

type inMemoryStoreRow<'a> = {
  crud: crud,
  entity: 'a,
}

//*************
//**CONTRACTS**
//*************

type eventLog<'a> = {
  params: 'a,
  blockNumber: int,
  blockTimestamp: int,
  blockHash: string,
  srcAddress: string,
  transactionHash: string,
  transactionIndex: int,
  logIndex: int,
}

{{#each contracts as | contract |}}
module {{contract.name.capitalized}}Contract = {
{{#each contract.events as | event |}}
module {{event.name.capitalized}}Event = {
  type eventArgs = {
    {{#each event.params as | param |}}
    {{param.key}} : {{param.type_}},
    {{/each}}
  }
    {{#each ../../entities as | entity |}}
    type {{entity.name.uncapitalized}}EntityHandlerContext = {
      /// TODO: add named entities (this is hardcoded)
      gravatarWithChanges: unit => option<gravatarEntity>,
      insert: {{entity.name.uncapitalized}}Entity => unit,
      update: {{entity.name.uncapitalized}}Entity => unit,
      delete: id => unit,
    }
    {{/each}}
    type context = {
      {{#each ../../entities as | entity |}}
        {{entity.name.uncapitalized}}: {{entity.name.uncapitalized}}EntityHandlerContext,
      {{/each}}
    }

    // TODO: these are hardcoded on all events, but should be generated based on the read config
    type gravatarEntityLoaderContext = {gravatarWithChangesLoad: id => unit}
    type loaderContext = {gravatar: gravatarEntityLoaderContext}
  
}
{{/each}}
}
{{/each}}

type event =
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
  | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}(eventLog<{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs>)
{{/each}}
{{/each}}

type eventAndContext =
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
  | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}WithContext(eventLog<{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs>, {{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.context)
{{/each}}
{{/each}}

type eventName =
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
  | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}Event
{{/each}}
{{/each}}

let eventNameToString = (eventName: eventName) => switch eventName {
  {{#each contracts as | contract |}}
  {{#each contract.events as | event |}}
    | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}Event => "{{event.name.capitalized}}"
  {{/each}}
}
{{/each}}
