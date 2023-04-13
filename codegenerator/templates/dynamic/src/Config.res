type contract = {
  name: string,
  abi: Ethers.abi,
  address: Ethers.ethAddress,
  events: array<Types.eventName>,
}

type chainConfig = {
  rpcUrl: string,
  chainId: int,
  startBlock: int,
  contracts: array<contract>,
}

type chainConfigs = Js.Dict.t<chainConfig>

let config: chainConfigs = [
{{#each chain_configs as | chain_config |}}
(
  "{{chain_config.network_config.id}}",
  {
    rpcUrl: "{{chain_config.network_config.rpc_url}}",
    chainId: {{chain_config.network_config.id}},
    startBlock: {{chain_config.network_config.start_block}},
    contracts: [
      {{#each chain_config.contracts as | contract |}}
      {
        name: "{{contract.name.capitalized}}",
          abi: Abis.{{contract.name.uncapitalized}}Abi->Ethers.makeAbi,
          address: "{{contract.address}}"->Ethers.getAddressFromStringUnsafe,
          events: [
            {{#each contract.events as | event |}}
            {{contract.name.capitalized}}Contract_{{event.capitalized}}Event,
            {{/each}}
            ],
      }
      {{/each}}
    ]

  }
)
{{/each}}
]->Js.Dict.fromArray
