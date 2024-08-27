let chain1 = ChainMap.Chain.makeUnsafe(~chainId=1)
let chain137 = ChainMap.Chain.makeUnsafe(~chainId=137)
let chain1337 = ChainMap.Chain.makeUnsafe(~chainId=1337)

let contracts = [
  {
    Config.name: "Gravatar",
    abi: Abis.gravatarAbi->Ethers.makeAbi,
    addresses: ["0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Ethers.getAddressFromStringUnsafe],
    events: [
      module(Types.Gravatar.TestEvent),
      module(Types.Gravatar.NewGravatar),
      module(Types.Gravatar.UpdatedGravatar),
    ],
  },
  {
    name: "NftFactory",
    abi: Abis.nftFactoryAbi->Ethers.makeAbi,
    addresses: ["0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Ethers.getAddressFromStringUnsafe],
    events: [module(Types.NftFactory.SimpleNftCreated)],
  },
  {
    name: "SimpleNft",
    abi: Abis.simpleNftAbi->Ethers.makeAbi,
    addresses: [],
    events: [module(Types.SimpleNft.Transfer)],
  },
]

let mockChainConfig: Config.chainConfig = {
  confirmedBlockThreshold: 200,
  syncSource: Rpc({
    provider: Hardhat.hardhatProvider,
    syncConfig: {
      initialBlockInterval: 10000,
      backoffMultiplicative: 10000.0,
      accelerationAdditive: 10000,
      intervalCeiling: 10000,
      backoffMillis: 10000,
      queryTimeoutMillis: 10000,
    },
  }),
  startBlock: 1,
  endBlock: None,
  chain: chain1337,
  contracts,
  chainWorker: module(
    RpcWorker.Make({
      let chain = chain1337
      let contracts = contracts
      let rpcConfig: Config.rpcConfig = {
        provider: Ethers.JsonRpcProvider.make(
          ~rpcUrls=["http://localhost:8545"],
          ~chainId=1337,
          ~fallbackStallTimeout=3,
        ),
        syncConfig: Config.getSyncConfig({
          initialBlockInterval: 10000,
          backoffMultiplicative: 10000.0,
          accelerationAdditive: 10000,
          intervalCeiling: 10000,
          backoffMillis: 10000,
          queryTimeoutMillis: 10000,
        }),
      }
      let eventLookup = EventLookup.empty()
    })
  ),
}
