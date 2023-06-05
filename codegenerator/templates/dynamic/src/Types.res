//*************
//***ENTITIES**
//*************

@genType.as("Id")
type id = string

//nested subrecord types

{{#each sub_record_dependencies as | subrecord |}}
  @spice
   type {{subrecord.name.uncapitalized}} = {
    {{#each subrecord.params as | param |}}
      {{param.key}}: {{param.type_rescript}},
    {{/each}}
   }

{{/each}}

@@warning("-30")
@genType
type rec {{#each entities as | entity |}}{{#unless @first}}
and {{/unless}}{{entity.name.uncapitalized}}LoaderConfig = {{#if entity.relational_params.[0]}}{
  {{#each entity.relational_params as | relational_param |}}
  load{{relational_param.relational_key.capitalized}}?: {{relational_param.mapped_entity.uncapitalized}}LoaderConfig,{{/each}}
}{{else}}bool{{/if}}{{/each}}

@@warning("+30")

type entityRead = 
{{#each entities as | entity |}}
| {{entity.name.capitalized}}Read(id{{#if entity.relational_params.[0]}}, {{entity.name.uncapitalized}}LoaderConfig{{/if}})
{{/each}}


let entitySerialize = (entity: entityRead) => {
  switch entity {
  {{#each entities as | entity |}}
  | {{entity.name.capitalized}}Read(id{{#if entity.relational_params.[0]}}, _{{/if}}) => `{{entity.name.uncapitalized}}${id}`
  {{/each}}
  }
}

type rawEventsEntity = {
  @as("chain_id") chainId: int,
  @as("event_id") eventId: string,
  @as("block_number") blockNumber: int,
  @as("log_index") logIndex: int,
  @as("transaction_index") transactionIndex: int,
  @as("transaction_hash") transactionHash: string,
  @as("src_address") srcAddress: string,
  @as("block_hash") blockHash: string,
  @as("block_timestamp") blockTimestamp: int,
  @as("event_type") eventType: Js.Json.t,
  params: string,
}

{{#each entities as | entity |}}
@genType
type {{entity.name.uncapitalized}}Entity = {
  {{#each entity.params as | param |}}
  {{param.key}} : {{param.type_rescript}},
  {{/each}}
}

type {{entity.name.uncapitalized}}EntitySerialized = {
  {{#each entity.params as | param |}}
  {{param.key}} : {{#if (eq param.type_rescript "Ethers.BigInt.t")}} string{{else}}{{#if (eq param.type_rescript "option<Ethers.BigInt.t>")}} option<string>{{else}}{{param.type_rescript}}{{/if}}{{/if}},
  {{/each}}
}

let serialize{{entity.name.capitalized}}Entity = (entity: {{entity.name.uncapitalized}}Entity ): {{entity.name.uncapitalized}}EntitySerialized => {
  {
    {{#each entity.params as | param |}}
    {{param.key}} : entity.{{param.key}}{{#if (eq param.type_rescript "Ethers.BigInt.t")}}->Ethers.BigInt.toString{{else}}{{#if (eq param.type_rescript "option<Ethers.BigInt.t>")}}->Belt.Option.map(opt =>
      opt->Ethers.BigInt.toString){{/if}}{{/if}},
    {{/each}}
  }
}

{{/each}}
type entity = 
{{#each entities as | entity |}}
  | {{entity.name.capitalized}}Entity({{entity.name.uncapitalized}}Entity)
{{/each}}



type crud = Create | Read | Update | Delete

type eventData = {
  @as("event_chain_id") chainId: int,
  @as("event_id") eventId: string,
}

type inMemoryStoreRow<'a> = {
  crud: crud,
  entity: 'a,
  eventData: eventData,
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
        {{#each required_entity.entity_fields_of_required_entity as | entity_field_of_required_entity |}}
        // TODO: make this type correspond to if the field is optional or not.
          get{{entity_field_of_required_entity.field_name.capitalized}}: {{entity.name.uncapitalized}}Entity => 
          {{#if entity_field_of_required_entity.is_optional}}
            option<{{entity_field_of_required_entity.type_name.uncapitalized}}Entity>,
          {{else}}
            {{#if entity_field_of_required_entity.is_array}}
              array<{{entity_field_of_required_entity.type_name.uncapitalized}}Entity>,
            {{else}}
              {{entity_field_of_required_entity.type_name.uncapitalized}}Entity,
            {{/if}}
          {{/if}}
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
    @genType
    type {{required_entity.name.uncapitalized}}EntityLoaderContext = {
      {{#each required_entity.labels as | label |}}
      {{label}}Load: (id{{#if required_entity.entity_fields_of_required_entity.[0]}}, ~loaders: {{required_entity.name.uncapitalized}}LoaderConfig=?{{/if}}) => unit,
      {{/each}}
    }
    {{/each}}

    // NOTE: this only allows single level deep linked entity data loading. TODO: make it recursive
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

