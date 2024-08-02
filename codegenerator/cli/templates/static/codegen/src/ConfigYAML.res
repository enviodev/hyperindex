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

let contractSchema = S.object(s => {
  abi: s.field("abi", S.json(~validate=false)->Utils.magic),
  addresses: s.field("addresses", S.array(S.string)->Utils.magic),
  events: s.field("events", S.array(S.string)),
})

type configYaml = {
  syncSource: aliasSyncSource,
  startBlock: int,
  confirmedBlockThreshold: int,
  contracts: dict<contract>,
}

let configYamlSchema: S.t<configYaml> = S.object(s => {
  syncSource: s.field("syncSource", Config.syncSourceSchema),
  startBlock: s.field("startBlock", S.int),
  confirmedBlockThreshold: s.field("confirmedBlockThreshold", S.int),
  contracts: s.field("contracts", S.dict(contractSchema)),
})

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

type t = {
  historyConfig: Config.historyConfig,
  shouldUseHypersyncClientDecoder: bool,
  isUnorderedMultichainMode: bool,
  enableRawEvents: bool,
  chains: dict<configYaml>,
}

let schema: S.t<t> = S.object(s => {
  historyConfig: s.field("historyConfig", Config.historyConfigSchema),
  shouldUseHypersyncClientDecoder: s.field("shouldUseHypersyncClientDecoder", S.bool),
  isUnorderedMultichainMode: s.field("isUnorderedMultichainMode", S.bool),
  enableRawEvents: s.field("enableRawEvents", S.bool),
  chains: s.field("chains", S.dict(configYamlSchema)),
})

let fromConfig = (cfg: Config.t, ~shouldRemoveAddresses): t => {
  let {
    historyConfig,
    shouldUseHypersyncClientDecoder,
    isUnorderedMultichainMode,
    enableRawEvents,
    chainMap,
  } = cfg
  {
    historyConfig,
    shouldUseHypersyncClientDecoder,
    isUnorderedMultichainMode,
    enableRawEvents,
    chains: chainMap
    ->ChainMap.entries
    ->Belt.Array.map(((chain, chainConfig)) => (
      chain->ChainMap.Chain.toString,
      chainConfig->mapChainConfigToConfigYaml(~shouldRemoveAddresses),
    ))
    ->Js.Dict.fromArray,
  }
}
