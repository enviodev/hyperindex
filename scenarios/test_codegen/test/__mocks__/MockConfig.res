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
  chainId: 1337,
  contracts: [
    {
      name: "Gravatar",
      abi: Abis.gravatarAbi->Ethers.makeAbi,
      addresses: ["0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Ethers.getAddressFromStringUnsafe],
      events: [Gravatar_TestEvent, Gravatar_NewGravatar, Gravatar_UpdatedGravatar],
    },
    {
      name: "NftFactory",
      abi: Abis.nftFactoryAbi->Ethers.makeAbi,
      addresses: ["0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Ethers.getAddressFromStringUnsafe],
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
