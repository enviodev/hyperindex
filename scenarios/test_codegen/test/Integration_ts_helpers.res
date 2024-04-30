// import hre from "hardhat";

type hre
@module external hre: hre = "hardhat"
@get @scope("ethers") external getProvider: hre => Ethers.JsonRpcProvider.t = "provider"

@genType.opaque
type chainConfig = Config.chainConfig

@genType
let getLocalChainConfig = (nftFactoryContractAddress): chainConfig => {
  let provider = hre->getProvider

  {
    confirmedBlockThreshold: 200,
    syncSource: Rpc({
      provider,
      syncConfig: {
        initialBlockInterval: 10000,
        backoffMultiplicative: 10000.,
        accelerationAdditive: 10000,
        intervalCeiling: 10000,
        backoffMillis: 10000,
        queryTimeoutMillis: 10000,
      },
    }),
    startBlock: 1,
    endBlock:None,
    chain: Chain_1337,
    contracts: [
      {
        name: "NftFactory",
        abi: Abis.nftFactoryAbi->Ethers.makeAbi,
        addresses: [nftFactoryContractAddress],
        events: [NftFactory_SimpleNftCreated],
      },
      {
        name: "SimpleNft",
        abi: Abis.simpleNftAbi->Ethers.makeAbi,
        addresses: [],
        events: [SimpleNft_Transfer],
      },
    ],
  }
}

@genType.opaque
type chainManager = ChainManager.t

@genType
let makeChainManager = (cfg: chainConfig): chainManager => {
  // let getConfig = chain =>
  //   if chain == cfg.chain {
  //     cfg
  //   } else {
  //     chain->Config.getConfig
  //   }
  // let configs = ChainMap.make(getConfig)
  let configs = [(cfg.chain, cfg)]->Belt.Map.fromArray(~id=module(ChainMap.Chain.ChainIdCmp))
  let cm = ChainManager.makeFromConfig(~configs)
  {...cm, isUnorderedMultichainMode: true}
}

@genType
let startProcessing = (cfg: chainConfig, chainManager: chainManager) => {
  let globalState: GlobalState.t = {
    currentlyProcessingBatch: false,
    chainManager,
    maxBatchSize: Env.maxProcessBatchSize,
    maxPerChainQueueSize: {
      let numChains = Config.config->ChainMap.size
      Env.maxEventFetchedQueueSize / numChains
    },
    indexerStartTime: Js.Date.make(),
  }

  let gsManager = globalState->GlobalStateManager.make

  gsManager->GlobalStateManager.dispatchTask(NextQuery(Chain(cfg.chain)))
}
