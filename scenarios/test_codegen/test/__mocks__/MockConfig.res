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
  },
  {
    name: "NftFactory",
    abi: Types.NftFactory.abi,
    addresses: ["0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Address.Evm.fromStringOrThrow],
    events: [module(Types.NftFactory.SimpleNftCreated)],
  },
  {
    name: "SimpleNft",
    abi: Types.SimpleNft.abi,
    addresses: [],
    events: [module(Types.SimpleNft.Transfer)],
  },
]

let mockChainConfig: Config.chainConfig = {
  confirmedBlockThreshold: 200,
  startBlock: 1,
  endBlock: None,
  chain: chain1337,
  contracts,
  sources: [
    RpcSource.make({
      chain: chain1337,
      contracts,
      sourceFor: Sync,
      syncConfig: Config.getSyncConfig({
        initialBlockInterval: 10000,
        backoffMultiplicative: 10000.0,
        accelerationAdditive: 10000,
        intervalCeiling: 10000,
        backoffMillis: 10000,
        queryTimeoutMillis: 10000,
        fallbackStallTimeout: 3,
      }),
      url: "http://127.0.0.1:8545",
      eventRouter: contracts
      ->Belt.Array.flatMap(contract => contract.events)
      ->EventRouter.fromEvmEventModsOrThrow(~chain=chain1337),
    }),
  ],
}
