//************
//** EVENTS **
//************

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
type {{event.name.uncapitalized}}Event = {
  {{#each event.params as | param |}}
  {{param.key}} : {{param.type_}},
  {{/each}}
}

{{/each}}
}

{{/each}}

type event =
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
  | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}(eventLog<{{contract.name.capitalized}}Contract.{{event.name.uncapitalized}}Event>)
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
{{/each}}
}


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
//** CONTEXT **
//*************

type loadedEntitiesReader<'a> = {
  {{#each entities as |entity|}}
  get{{entity.name.capitalized}}ById: id => option<'a>,
  getAllLoaded{{entity.name.capitalized}}: unit => array<'a>,
  {{/each}}
}

type entityController<'a> = {
  insert: 'a => unit,
  update: 'a => unit,
  loadedEntities: loadedEntitiesReader<'a>,
}

{{#each entities as | entity |}}
type {{entity.name.uncapitalized}}Controller = entityController<{{entity.name.uncapitalized}}Entity>
{{/each}}


type context = {
  {{#each entities as | entity |}}
  @as("{{entity.name.capitalized}}") {{entity.name.uncapitalized}}: {{entity.name.uncapitalized}}Controller
  {{/each}}
}
