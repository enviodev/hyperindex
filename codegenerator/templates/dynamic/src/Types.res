//*************
//***ENTITIES**
//*************

@genType.as("Id")
type id = string

//nested subrecord types

{{#each sub_record_dependencies as | subrecord |}}
   type {{subrecord.name.uncapitalized}} = {
    {{#each subrecord.params as | param |}}
      {{param.key}}: {{param.type_rescript}},
    {{/each}}
   }

{{/each}}

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

type rawEventsEntity = {
  @as("chain_id") chainId: int,
  @as("event_id") eventId: Ethers.BigInt.t,
  @as("block_number") blockNumber: int,
  @as("log_index") logIndex: int,
  @as("transaction_index") transactionIndex: int,
  @as("transaction_hash") transactionHash: string,
  @as("src_address") srcAddress: string,
  @as("block_hash") blockHash: string,
  @as("block_timestamp") blockTimestamp: int,
  @as("event_type") eventType: Js.Json.t,
  params: Js.Json.t,
}

{{#each entities as | entity |}}
@genType
type {{entity.name.uncapitalized}}Entity = {
  {{#each entity.params as | param |}}
  {{param.key}} : {{param.type_rescript}},
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

@genType
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
  @spice @genType
  type eventArgs = {
    {{#each event.params as | param |}}
    {{param.key}} : {{param.type_rescript}},
    {{/each}}
  }
    {{#each ../../entities as | entity |}}
    type {{entity.name.uncapitalized}}EntityHandlerContext = {
    {{#each event.required_entities as | required_entity |}}
      {{#if (eq entity.name.capitalized required_entity.name.capitalized)}}
        {{#each required_entity.labels as |label| }}
        {{label}}: unit => option<{{required_entity.name.uncapitalized}}Entity>,
        {{/each}}
      {{/if}}
    {{/each}}
      insert: {{entity.name.uncapitalized}}Entity => unit,
      update: {{entity.name.uncapitalized}}Entity => unit,
      delete: id => unit,
    }
    {{/each}}
    @genType
    type context = {
      {{#each ../../entities as | entity |}}
        {{entity.name.uncapitalized}}: {{entity.name.uncapitalized}}EntityHandlerContext,
      {{/each}}
    }

    {{#each event.required_entities as | required_entity |}}
    type {{required_entity.name.uncapitalized}}EntityLoaderContext = {
      {{#each required_entity.labels as | label |}}
      {{label}}Load: id => unit,
      {{/each}}
    }
    {{/each}}

    @genType
    type loaderContext = {
    {{#each event.required_entities as | required_entity |}}
    {{required_entity.name.uncapitalized}} : {{required_entity.name.uncapitalized}}EntityLoaderContext,
    {{/each}}
    }

  
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

@spice
type eventName =
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
  | @spice.as("{{contract.name.capitalized}}Contract_{{event.name.capitalized}}Event") {{contract.name.capitalized}}Contract_{{event.name.capitalized}}Event
{{/each}}
{{/each}}

let eventNameToString = (eventName: eventName) => switch eventName {
  {{#each contracts as | contract |}}
  {{#each contract.events as | event |}}
    | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}Event => "{{event.name.capitalized}}"
  {{/each}}
  {{/each}}
}

