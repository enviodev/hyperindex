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


//Context types
