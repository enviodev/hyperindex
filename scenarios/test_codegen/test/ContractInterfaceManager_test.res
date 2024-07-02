open RescriptMocha

open ContractInterfaceManager

describe("Test ContractInterfaceManager", () => {
  it("Full config contractInterfaceManager gets all topics and addresses for filters", () => {
    let logger = Logging.logger
    let chainConfig = Config.config->ChainMap.get(Chain_1337)
    let contractAddressMapping = ContractAddressingMap.make()
    contractAddressMapping->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)

    let contractInterfaceManager = make(~contractAddressMapping, ~chainConfig)

    let {topics, addresses} = contractInterfaceManager->getAllTopicsAndAddresses

    Assert.equal(
      addresses->Array.length,
      2,
      ~message="Expected same amount of addresses as contract adderesses in config",
    )

    Assert.equal(
      topics->Array.length,
      7,
      ~message="Expected same amount of topics as number of events in config",
    )
  })

  it("Single address config gets all topics and addresses for filters", () => {
    let chainConfig = Config.config->ChainMap.get(Chain_1337)
    let contractAddress =
      "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Ethers.getAddressFromStringUnsafe

    let singleContractIM = makeFromSingleContract(
      ~contractAddress,
      ~contractName="Gravatar",
      ~chainConfig,
    )
    let {addresses, topics} = singleContractIM->getAllTopicsAndAddresses
    Assert.equal(
      addresses->Array.length,
      1,
      ~message="Expected same amount of addresses as contract adderesses in config",
    )

    Assert.equal(
      addresses[0],
      contractAddress,
      ~message="Expected contract address to be the same as passed in",
    )

    Assert.equal(
      topics->Array.length,
      6,
      ~message="Expected same amount of topics as number of events in config",
    )
  })

  it("Combined Interface Manager matches the values from single Interface Managers", () => {
    let chainConfig = Config.config->ChainMap.get(Chain_1337)
    let gravatarAddress =
      "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Ethers.getAddressFromStringUnsafe

    let gravatarIM = makeFromSingleContract(
      ~contractAddress=gravatarAddress,
      ~contractName="Gravatar",
      ~chainConfig,
    )
    let {addresses: gravatarAddresses, topics: gravatarTopics} =
      gravatarIM->getAllTopicsAndAddresses

    let nftFactoryAddress =
      "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Ethers.getAddressFromStringUnsafe

    let nftFactoryIM = makeFromSingleContract(
      ~contractAddress=nftFactoryAddress,
      ~contractName="NftFactory",
      ~chainConfig,
    )

    let {addresses: nftFactoryAddresses, topics: nftFactoryTopics} =
      nftFactoryIM->getAllTopicsAndAddresses

    let combinedIM = [gravatarIM, nftFactoryIM]->combineInterfaceManagers

    let {addresses: allAddresses, topics: allTopics} = combinedIM->getAllTopicsAndAddresses

    Assert.deepStrictEqual(
      Belt.Array.concat(gravatarAddresses, nftFactoryAddresses),
      allAddresses,
      ~message="combined addresses should contain addresses of single ContractInterfaceManager",
    )

    Assert.deepStrictEqual(
      Belt.Array.concat(gravatarTopics, nftFactoryTopics),
      allTopics,
      ~message="combined topics should contain addresses of single ContractInterfaceManager",
    )
  })
})
