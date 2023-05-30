let config: Postgres.poolConfig = {
  ...Config.db,
  transform: {undefined: Js.null},
}
let sql = Postgres.makeSql(~config)

type chainId = int
type eventId = string
type blockNumberRow = {
  @as("block_number") blockNumber: int
}

module RawEvents = {
  type rawEventRowId = (chainId, eventId)
  @module("./DbFunctionsImplementation.js")
  external batchSetRawEvents: (Postgres.sql, array<Types.rawEventsEntity>) => promise<unit> =
    "batchSetRawEvents"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteRawEvents: (Postgres.sql, array<rawEventRowId>) => promise<unit> =
    "batchDeleteRawEvents"

  @module("./DbFunctionsImplementation.js")
  external readRawEventsEntities: (
    Postgres.sql,
    array<rawEventRowId>,
  ) => promise<array<Types.rawEventsEntity>> = "readRawEventsEntities"

  ///Returns an array with 1 block number (the highest processed on the given chainId)
  @module("./DbFunctionsImplementation.js")
  external readLatestRawEventsBlockNumberProcessedOnChainId: (
    Postgres.sql,
    chainId,
  ) => promise<array<blockNumberRow>> = "readLatestRawEventsBlockNumberProcessedOnChainId"

  let getLatestProcessedBlockNumber = async (~chainId) => {
    let row = await sql->readLatestRawEventsBlockNumberProcessedOnChainId(chainId)

    row->Belt.Array.get(0)->Belt.Option.map(row => row.blockNumber)
  }
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
     {{param.key}} : {{#if (eq param.type_rescript "Ethers.BigInt.t")}} string{{else}}{{#if (eq param.type_rescript "option<Ethers.BigInt.t>")}} option<string>{{else}}{{param.type_rescript}}{{/if}}{{/if}},
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
        {{param.key}} {{#if  (eq param.type_rescript "Ethers.BigInt.t")}} : {{param.key}}->Ethers.BigInt.fromStringUnsafe{{else}}{{#if (eq param.type_rescript "option<Ethers.BigInt.t>")}}: {{param.key}}->Belt.Option.map(opt =>
      opt->Ethers.BigInt.fromStringUnsafe){{/if}}{{/if}},
        {{/each}}
      },
      eventData: {
        chainId,
        eventId: eventId->Ethers.BigInt.toString,
      }
    }
  }

  @module("./DbFunctionsImplementation.js")
  external batchSet{{entity.name.capitalized}}: (Postgres.sql, array<Types.inMemoryStoreRow<Types.{{entity.name.uncapitalized}}EntitySerialized>>) => promise<(unit)> = "batchSet{{entity.name.capitalized}}"

  @module("./DbFunctionsImplementation.js")
  external batchDelete{{entity.name.capitalized}}: (Postgres.sql, array<Types.id>) => promise<(unit)> = "batchDelete{{entity.name.capitalized}}"

  @module("./DbFunctionsImplementation.js")
  external read{{entity.name.capitalized}}Entities: (Postgres.sql, array<Types.id>) => promise<array<{{entity.name.uncapitalized}}ReadRow>> = "read{{entity.name.capitalized}}Entities"
}
{{/each}}
