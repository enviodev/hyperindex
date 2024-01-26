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
let makeChainManager = (cfg: chainConfig, shouldSyncFromRawEvents, maxQueueSize): chainManager =>
  ChainManager.make(
    ~configs=Belt.Map.fromArray([(cfg.chain, cfg)], ~id=module(ChainMap.Chain.ChainIdCmp)),
    ~shouldSyncFromRawEvents,
    ~maxQueueSize,
  )

@genType
let startFetchers: chainManager => unit = ChainManager.startFetchers

@genType
let startProcessingEventsOnQueue: (
  ~chainManager: chainManager,
) => promise<unit> = EventProcessing.startProcessingEventsOnQueue
