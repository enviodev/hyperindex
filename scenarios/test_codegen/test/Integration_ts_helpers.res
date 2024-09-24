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
      sighashes: [Types.NftFactory.SimpleNftCreated.sighash],
    },
    {
      name: "SimpleNft",
      abi: Types.SimpleNft.abi,
      addresses: [],
      events: [module(Types.SimpleNft.Transfer)],
      sighashes: [Types.SimpleNft.Transfer.sighash],
    },
  ]
  let rpcConfig: Config.rpcConfig = {
    provider,
    syncConfig: {
      initialBlockInterval: 10000,
      backoffMultiplicative: 10000.,
      accelerationAdditive: 10000,
      intervalCeiling: 10000,
      backoffMillis: 10000,
      queryTimeoutMillis: 10000,
    },
  }
  let chain = MockConfig.chain1337
  {
    confirmedBlockThreshold: 200,
    syncSource: Rpc(rpcConfig),
    startBlock: 1,
    endBlock: None,
    chain,
    contracts,
    chainWorker: module(
      RpcWorker.Make({
        let chain = chain
        let contracts = contracts
        let rpcConfig = rpcConfig
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
