 ff//************
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
type {{event.name_lower_camel}}Event = {
  {{#each event.params as | param |}}
  {{param.key_string}} : {{param.type_string}},
  {{/each}}
}

{{/each}}

type event =
{{#each events as | event |}}
  | {{event.name_upper_camel}}(eventLog<{{event.name_lower_camel}}Event>)
{{/each}}


//*************
//***ENTITIES**
//*************


type id = string


type entityRead = 
{{#each entities as | entity |}}
| {{entity.name_upper_camel}}Read(id)
{{/each}}

let entitySerialize = (entity: entityRead) => {
  switch entity {
  {{#each entities as | entity |}}
  | {{entity.name_upper_camel}}Read(id) => `{{entity.name_lower_camel}}{id}`
  {{/each}}
  }
}

{{#each entities as | entity |}}
type {{entity.name_lower_camel}}Entity = {
  {{#each entity.params as | param |}}
  {{param.key_string}} : {{param.type_string}},
  {{/each}}
}

{{/each}}
type entity = 
{{#each entities as | entity |}}
  | {{entity.name_upper_camel}}Entity({{entity.name_lower_camel}}Entity)
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
type {{entity.name_lower_camel}}Controller = entityController<{{entity.name_lower_camel}}Entity>
{{/each}}


type context = {
  {{#each entities as | entity |}}
  @as("{{entity.name_upper_camel}}") {{entity.name_lower_camel}}: {{entity.name_lower_camel}}Controller
  {{/each}}
}
