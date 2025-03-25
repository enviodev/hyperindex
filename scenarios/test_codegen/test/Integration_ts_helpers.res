@genType.opaque
type chainConfig = Config.chainConfig

@genType
let getLocalChainConfig = (nftFactoryContractAddress): chainConfig => {
  let contracts = [
    {
      Config.name: "NftFactory",
      abi: Types.NftFactory.abi,
      addresses: [nftFactoryContractAddress],
      events: [(Types.NftFactory.SimpleNftCreated.register() :> Internal.baseEventConfig)],
    },
    {
      name: "SimpleNft",
      abi: Types.SimpleNft.abi,
      addresses: [],
      events: [(Types.SimpleNft.Transfer.register() :> Internal.baseEventConfig)],
    },
  ]
  let evmContracts = contracts->Js.Array2.map((contract): Internal.evmContractConfig => {
    name: contract.name,
    abi: contract.abi,
    events: contract.events->(
      Utils.magic: array<Internal.baseEventConfig> => array<Internal.evmEventConfig>
    ),
  })
  let chain = MockConfig.chain1337
  {
    confirmedBlockThreshold: 200,
    startBlock: 1,
    endBlock: None,
    chain,
    contracts,
    sources: [
      RpcSource.make({
        chain,
        sourceFor: Sync,
        contracts: evmContracts,
        syncConfig: {
          initialBlockInterval: 10000,
          backoffMultiplicative: 10000.,
          accelerationAdditive: 10000,
          intervalCeiling: 10000,
          backoffMillis: 10000,
          queryTimeoutMillis: 10000,
          fallbackStallTimeout: 1000,
        },
        url: "http://127.0.0.1:8545",
        eventRouter: evmContracts
        ->Belt.Array.flatMap(contract => contract.events)
        ->EventRouter.fromEvmEventModsOrThrow(~chain),
      }),
    ],
  }
}

@genType.opaque
type chainManager = ChainManager.t

@genType
let makeChainManager = (cfg: chainConfig): chainManager => {
  // FIXME: Should fork from the main ChainMap?
  ChainManager.makeFromConfig(~config=Config.make(~isUnorderedMultichainMode=true, ~chains=[cfg]))
}

@genType
let startProcessing = (config, cfg: chainConfig, chainManager: chainManager) => {
  let loadLayer = LoadLayer.makeWithDbConnection()
  let globalState = GlobalState.make(
    ~config=config->(
      // Workaround for genType to treat the type as unknown, since we don't want to expose Config.t to TS users
      Utils.magic: unknown => Config.t
    ),
    ~loadLayer,
    ~chainManager,
  )

  let gsManager = globalState->GlobalStateManager.make

  gsManager->GlobalStateManager.dispatchTask(NextQuery(Chain(cfg.chain)))
}
