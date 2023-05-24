let config: Postgres.poolConfig = {
  ...Config.db,
  transform: {undefined: Js.null},
}
let sql = Postgres.makeSql(~config)

type chainId = int
type eventId = Ethers.BigInt.t

module RawEvents = {
  type rawEventRowId = (chainId, eventId)
  @module("./DbFunctionsImplementation.js")
  external batchSetRawEvents: (Postgres.sql, array<Types.rawEventsEntity>) => promise<unit> = "batchSetRawEvents"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteRawEvents: (Postgres.sql, array<rawEventRowId>) => promise<unit> = "batchDeleteRawEvents"

  @module("./DbFunctionsImplementation.js")
  external readRawEventsEntities: (Postgres.sql, array<rawEventRowId>) => promise<array<Types.rawEventsEntity>> =
    "readRawEventsEntities"
}

type readEntityData<'a> = {
   entity: 'a,
   eventData: Types.eventData
}

{{#each entities as |entity|}}
module {{entity.name.capitalized}} = {
  open Types
  type {{entity.name.uncapitalized}}ReadRow = {
  {{#each entity.params as |param|}}
     {{param.key}}: {{param.type_rescript}}, 
  {{/each}}
  @as("event_chain_id") chainId: int,
  @as("event_id") eventId: Ethers.BigInt.t,
  }

  let readRowToReadEntityData = (readRow: {{entity.name.uncapitalized}}ReadRow): readEntityData<Types.{{entity.name.uncapitalized}}Entity> => {
    let {
      {{#each entity.params as | param |}}
      {{param.key}},
      {{/each}}
      chainId,
      eventId
    } = readRow

    {
      entity: {
        {{#each entity.params as | param |}}
        {{param.key}},
        {{#if param.maybe_entity_name}}{{param.key}}Data : None, {{/if}}
        {{/each}}
      },
      eventData: {
        chainId,
        eventId
      }
    }
  }

  @module("./DbFunctionsImplementation.js")
  external batchSet{{entity.name.capitalized}}: (Postgres.sql, array<Types.inMemoryStoreRow<Types.{{entity.name.uncapitalized}}Entity>>) => promise<(unit)> = "batchSet{{entity.name.capitalized}}"

  @module("./DbFunctionsImplementation.js")
  external batchDelete{{entity.name.capitalized}}: (Postgres.sql, array<Types.id>) => promise<(unit)> = "batchDelete{{entity.name.capitalized}}"

  @module("./DbFunctionsImplementation.js")
  external read{{entity.name.capitalized}}Entities: (Postgres.sql, array<Types.id>) => promise<array<{{entity.name.uncapitalized}}ReadRow>> = "read{{entity.name.capitalized}}Entities"
}
{{/each}}
