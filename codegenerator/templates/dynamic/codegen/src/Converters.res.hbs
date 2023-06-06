exception UndefinedEvent(string)
exception UndefinedContract(Ethers.ethAddress, int)

let getContractNameFromAddress = (contractAddress: Ethers.ethAddress, chainId: int): string => {
  switch (contractAddress->Ethers.ethAddressToString, chainId->Belt.Int.toString) {
    {{#each chain_configs as |chain_config|}}
    {{#each chain_config.contracts as |contract|}}
    // TODO: make 'contracts' be per contract type/name, and have addresses as an array inside each contract.
    | ("{{contract.address}}", "{{chain_config.network_config.id}}") => "{{contract.name.capitalized}}"
    {{/each}}
    {{/each}}
    | _ => UndefinedContract(contractAddress, chainId)->raise
  }
}
let eventStringToEvent = (eventName: string, contractName: string): Types.eventName => {
  switch (eventName, contractName) {
    {{#each contracts as |contract|}}
    {{#each contract.events as |event|}}
    | ("{{event.name.capitalized}}", "{{contract.name.capitalized}}") => {{contract.name.capitalized}}Contract_{{event.name.capitalized}}Event
    {{/each}}
    {{/each}}
    | _ => UndefinedEvent(eventName)->raise
  }
}

{{#each contracts as |contract|}}
module {{contract.name.capitalized}} = {
{{#each contract.events as |event|}}
  let convert{{event.name.capitalized}}LogDescription = (log: Ethers.logDescription<'a>): Ethers.logDescription<
    Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs,
  > => {
    log->Obj.magic
  }

  let convert{{event.name.capitalized}}Log = async (
    logDescription: Ethers.logDescription<Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs>,
    ~log: Ethers.log,
    ~blockPromise: promise<Ethers.JsonRpcProvider.block>,
  ) => {
    let params: Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs = {
      {{#each event.params as | param |}}
        {{param.key}}: logDescription.args.{{param.key}},
      {{/each}}
    }
    let block = await blockPromise

    let {{event.name.uncapitalized}}Log: Types.eventLog<Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs> = {
      params,
      blockNumber: block.number,
      blockTimestamp: block.timestamp,
      blockHash: log.blockHash,
      srcAddress: log.address->Ethers.ethAddressToString,
      transactionHash: log.transactionHash,
      transactionIndex: log.transactionIndex,
      logIndex: log.logIndex,
    }
    Types.{{contract.name.capitalized}}Contract_{{event.name.capitalized}}({{event.name.uncapitalized}}Log)
  }

{{/each}}
}

{{/each}}
