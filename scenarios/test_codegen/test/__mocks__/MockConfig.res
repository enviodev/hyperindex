let chain1 = ChainMap.Chain.makeUnsafe(~chainId=1)
let chain137 = ChainMap.Chain.makeUnsafe(~chainId=137)
let chain1337 = ChainMap.Chain.makeUnsafe(~chainId=1337)

let contracts = [
  {
    Config.name: "Gravatar",
    abi: Types.Gravatar.abi,
    addresses: ["0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Address.Evm.fromStringOrThrow],
    events: [
      module(Types.Gravatar.TestEvent),
      module(Types.Gravatar.NewGravatar),
      module(Types.Gravatar.UpdatedGravatar),
    ],
    sighashes: [
      Types.Gravatar.TestEvent.sighash,
      Types.Gravatar.NewGravatar.sighash,
      Types.Gravatar.UpdatedGravatar.sighash,
    ],
  },
  {
    name: "NftFactory",
    abi: Types.NftFactory.abi,
    addresses: ["0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Address.Evm.fromStringOrThrow],
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

let mockChainConfig: Config.chainConfig = {
  confirmedBlockThreshold: 200,
  syncSource: Rpc,
  startBlock: 1,
  endBlock: None,
  chain: chain1337,
  contracts,
  chainWorker: module(
    RpcWorker.Make({
      let chain = chain1337
      let contracts = contracts
      let syncConfig = Config.getSyncConfig({
        initialBlockInterval: 10000,
        backoffMultiplicative: 10000.0,
        accelerationAdditive: 10000,
        intervalCeiling: 10000,
        backoffMillis: 10000,
        queryTimeoutMillis: 10000,
      })
      let provider = Ethers.JsonRpcProvider.make(
        ~rpcUrls=["http://localhost:8545"],
        ~chainId=1337,
        ~fallbackStallTimeout=3,
      )
      let eventRouter =
        contracts
        ->Belt.Array.flatMap(contract => contract.events)
        ->EventRouter.fromEvmEventModsOrThrow(~chain)
    })
  ),
}
