// import hre from "hardhat";

type hre
@module external hre: hre = "hardhat"
@get @scope("ethers") external getProvider: hre => Ethers.JsonRpcProvider.t = "provider"

@genType.opaque
type chainConfig = Config.chainConfig

@genType
let getLocalChainConfig = (nftFactoryContractAddress): chainConfig => {
  let provider = hre->getProvider

  let contracts = [
    {
      Config.name: "NftFactory",
      abi: Types.NftFactory.abi,
      addresses: [nftFactoryContractAddress],
      events: [module(Types.NftFactory.SimpleNftCreated)],
    },
    {
      name: "SimpleNft",
      abi: Types.SimpleNft.abi,
      addresses: [],
      events: [module(Types.SimpleNft.Transfer)],
    },
  ]
  let chain = MockConfig.chain1337
  {
    confirmedBlockThreshold: 200,
    syncSource: Rpc,
    startBlock: 1,
    endBlock: None,
    chain,
    contracts,
    source: module(
      RpcSource.Make({
        let chain = chain
        let contracts = contracts
        let syncConfig: Config.syncConfig = {
          initialBlockInterval: 10000,
          backoffMultiplicative: 10000.,
          accelerationAdditive: 10000,
          intervalCeiling: 10000,
          backoffMillis: 10000,
          queryTimeoutMillis: 10000,
        }
        let provider = provider
        let eventRouter =
          contracts
          ->Belt.Array.flatMap(contract => contract.events)
          ->EventRouter.fromEvmEventModsOrThrow(~chain)
      })
    ),
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
