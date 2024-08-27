@genType.opaque
type aliasSyncSource = Config.syncSource
@genType.opaque
type aliasAbi = Ethers.abi

type eventName = string

type contract = {
  abi: aliasAbi,
  addresses: array<Address.t>,
  events: array<eventName>,
}

type configYaml = {
  syncSource: aliasSyncSource,
  startBlock: int,
  confirmedBlockThreshold: int,
  contracts: dict<contract>,
}

let mapChainConfigToConfigYaml = (chainConfig: Config.chainConfig): configYaml => {
  {
    syncSource: chainConfig.syncSource,
    startBlock: chainConfig.startBlock,
    confirmedBlockThreshold: chainConfig.confirmedBlockThreshold,
    contracts: Js.Dict.fromArray(
      Belt.Array.map(chainConfig.contracts, contract => {
        (
          contract.name,
          {
            abi: contract.abi,
            addresses: contract.addresses,
            events: contract.events->Belt.Array.map(event => {
              let module(Event) = event
              Event.name
            }),
          },
        )
      }),
    ),
  }
}

@genType
let getGeneratedByChainId: int => configYaml = chainId => {
  let config = RegisterHandlers.getConfig()
  config.chainMap->ChainMap.get(config->Config.getChain(~chainId))->mapChainConfigToConfigYaml
}
