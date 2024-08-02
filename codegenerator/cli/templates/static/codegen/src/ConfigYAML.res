@genType.opaque
type aliasSyncSource = Config.syncSource
@genType.opaque
type aliasAbi = Ethers.abi

type eventName = string

type contract = {
  abi: aliasAbi,
  addresses: array<Ethers.ethAddress>,
  events: array<eventName>,
}

type configYaml = {
  syncSource: aliasSyncSource,
  startBlock: int,
  confirmedBlockThreshold: int,
  contracts: dict<contract>,
}

let mapChainConfigToConfigYaml = (
  chainConfig: Config.chainConfig,
  ~shouldRemoveAddresses=false,
): configYaml => {
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
            addresses: shouldRemoveAddresses ? [] : contract.addresses,
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
  let config = Config.getGenerated()
  config.chainMap->ChainMap.get(config->Config.getChain(~chainId))->mapChainConfigToConfigYaml
}
