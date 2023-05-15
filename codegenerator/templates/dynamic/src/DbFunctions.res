module RawEvents = {
  type chainId = int
  type eventId = Ethers.BigInt.t
  type rawEventRowId = (chainId, eventId)
  @module("./DbFunctionsImplementation.js")
  external batchSetRawEvents: array<Types.rawEventsEntity> => promise<unit> = "batchSetRawEvents"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteRawEvents: array<rawEventRowId> => promise<unit> = "batchDeleteRawEvents"

  @module("./DbFunctionsImplementation.js")
  external readRawEventsEntities: array<rawEventRowId> => promise<array<Types.rawEventsEntity>> =
    "readRawEventsEntities"
}

{{#each entities as |entity|}}
module {{entity.name.capitalized}} = {
  @module("./DbFunctionsImplementation.js")
  external batchSet{{entity.name.capitalized}}: array<Types.{{entity.name.uncapitalized}}Entity,> => promise<(unit)> = "batchSet{{entity.name.capitalized}}"

  @module("./DbFunctionsImplementation.js")
  external batchDelete{{entity.name.capitalized}}: array<Types.id> => promise<(unit)> = "batchDelete{{entity.name.capitalized}}"

  @module("./DbFunctionsImplementation.js")
  external read{{entity.name.capitalized}}Entities: array<Types.id> => promise<array<Types.{{entity.name.uncapitalized}}Entity>> = "read{{entity.name.capitalized}}Entities"
}
{{/each}}
