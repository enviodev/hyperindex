@genType.opaque
type chainConfig = Config.chain

@genType
let getLocalChainConfig = (nftFactoryContractAddress): chainConfig => {
  let contracts = [
    {
      Config.name: "NftFactory",
      abi: Types.NftFactory.abi,
      addresses: [nftFactoryContractAddress],
      events: [(Types.NftFactory.SimpleNftCreated.register() :> Internal.eventConfig)],
      startBlock: None,
    },
    {
      name: "SimpleNft",
      abi: Types.SimpleNft.abi,
      addresses: [],
      events: [(Types.SimpleNft.Transfer.register() :> Internal.eventConfig)],
      startBlock: None,
    },
  ]
  let evmContracts = contracts->Js.Array2.map((contract): Internal.evmContractConfig => {
    name: contract.name,
    abi: contract.abi,
    events: contract.events->(
      Utils.magic: array<Internal.eventConfig> => array<Internal.evmEventConfig>
    ),
  })
  let chain = MockConfig.chain1337
  {
    name: "LocalChain",
    maxReorgDepth: 200,
    startBlock: 1,
    id: 1337,
    contracts,
    sources: [
      RpcSource.make({
        chain,
        sourceFor: Sync,
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
        allEventSignatures: [],
        lowercaseAddresses: false,
      }),
    ],
  }
}

@genType.opaque
type chainManager = ChainManager.t

// @genType
// let makeChainManager = (cfg: chainConfig): chainManager => {
//   // FIXME: Should fork from the main ChainMap?
//   ChainManager.makeFromConfig(
//     ~config=Config.makeForTest(~multichain=Unordered, ~chains=[cfg]),
//     ~registrations={onBlockByChainId: Js.Dict.empty(), hasEvents: false},
//   )
// }

@genType
let startProcessing = (_config, _cfg: chainConfig, _chainManager: chainManager) => {
  // let globalState = GlobalState.make(
  //   ~indexer=indexer->(
  //     // Workaround for genType to treat the type as unknown, since we don't want to expose Config.t to TS users
  //     Utils.magic: unknown => Config.t
  //   ),
  //   ~chainManager,
  // )
  // let gsManager = globalState->GlobalStateManager.make
  // gsManager->GlobalStateManager.dispatchTask(
  //   NextQuery(Chain(ChainMap.Chain.makeUnsafe(~chainId=cfg.id))),
  // )
  ()
}
