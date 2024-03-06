@genType.opaque
type aliasChainConfig = Config.chainConfig
@genType.opaque
type aliasSyncSource = Config.syncSource
@genType.opaque
type aliasAbi = Ethers.abi

type eventName = string

type contract = {
  name: string,
  abi: aliasAbi,
  addresses: array<Ethers.ethAddress>,
  events: array<eventName>,
}

type configYaml = {
  syncSource: aliasSyncSource,
  startBlock: int,
  confirmedBlockThreshold: int,
  contracts: array<contract>,
}

let mapChainConfigToConfigYaml: aliasChainConfig => configYaml = chainConfig => {
  {
    syncSource: chainConfig.syncSource,
    startBlock: chainConfig.startBlock,
    confirmedBlockThreshold: chainConfig.confirmedBlockThreshold,
    contracts: Belt.Array.map(chainConfig.contracts, contract => {
      {
        name: contract.name,
        abi: contract.abi,
        addresses: contract.addresses,
        events: Belt.Array.map(contract.events, event => event->Types.eventNameToString),
      }
    }),
  }
}

@genType
let getConfigByChainId: int => configYaml = chainId =>
  Config.getConfig(
    Belt.Result.getExn(ChainMap.Chain.fromChainId(chainId)),
  )->mapChainConfigToConfigYaml
