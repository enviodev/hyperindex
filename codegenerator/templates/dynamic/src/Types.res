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

{{#each events as | event |}}
type {{event.name.uncapitalized}}Event = {
  {{#each event.params as | param |}}
  {{param.key}} : {{param.type_}},
  {{/each}}
}

{{/each}}
type event =
{{#each events as | event |}}
  | {{event.name.capitalized}}(eventLog<{{event.name.uncapitalized}}Event>)
{{/each}}

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
  getById: id => option<'a>,
  getAllLoaded: unit => array<'a>,
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
