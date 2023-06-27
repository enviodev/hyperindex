let mockChainConfig: Config.chainConfig = {
  provider: Hardhat.hardhatProvider,
  startBlock: 1,
  chainId: 1337,
  syncConfig: {
    initialBlockInterval: 10000,
    backoffMultiplicative: 10000.0,
    accelerationAdditive: 10000,
    intervalCeiling: 10000,
    backoffMillis: 10000,
    queryTimeoutMillis: 10000,
  },
  contracts: [
    {
      name: "Gravatar",
      abi: Abis.gravatarAbi->Ethers.makeAbi,
      addresses: ["0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Ethers.getAddressFromStringUnsafe],
      events: [
        GravatarContract_TestEventEvent,
        GravatarContract_NewGravatarEvent,
        GravatarContract_UpdatedGravatarEvent,
      ],
    },
    {
      name: "NftFactory",
      abi: Abis.nftFactoryAbi->Ethers.makeAbi,
      addresses: ["0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Ethers.getAddressFromStringUnsafe],
      events: [NftFactoryContract_SimpleNftCreatedEvent],
    },
    {
      name: "SimpleNft",
      abi: Abis.simpleNftAbi->Ethers.makeAbi,
      addresses: [],
      events: [SimpleNftContract_TransferEvent],
    },
  ],
}
