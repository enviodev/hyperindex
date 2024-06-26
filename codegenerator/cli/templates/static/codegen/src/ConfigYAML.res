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

let mapChainConfigToConfigYaml: Config.chainConfig => configYaml = chainConfig => {
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
            events: Belt.Array.map(contract.events, event => event->Types.eventNameToString),
          },
        )
      }),
    ),
  }
}

@genType
let getConfigByChainId: int => configYaml = chainId =>
  Config.getConfig(
    Belt.Result.getExn(ChainMap.Chain.fromChainId(chainId)),
  )->mapChainConfigToConfigYaml
