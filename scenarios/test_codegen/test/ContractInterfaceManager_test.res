open RescriptMocha

open ContractInterfaceManager

// Insert the static address into the Contract <-> Address bi-mapping
let registerStaticAddresses = (mapping, ~chainConfig: Config.chainConfig, ~logger: Pino.t) => {
  chainConfig.contracts->Belt.Array.forEach(contract => {
    contract.addresses->Belt.Array.forEach(address => {
      Logging.childTrace(
        logger,
        {
          "msg": "adding contract address",
          "contractName": contract.name,
          "address": address,
        },
      )

      mapping->ContractAddressingMap.addAddress(~name=contract.name, ~address)
    })
  })
}

describe("Test ContractInterfaceManager", () => {
  it("Full config contractInterfaceManager gets all topics and addresses for filters", () => {
    let logger = Logging.logger
    let chainConfig =
      RegisterHandlers.registerAllHandlers().chainMap->ChainMap.get(MockConfig.chain1337)
    let contractAddressMapping = ContractAddressingMap.make()
    contractAddressMapping->registerStaticAddresses(~chainConfig, ~logger)

    let contractInterfaceManager = make(~contractAddressMapping, ~contracts=chainConfig.contracts)

    let {topics, addresses} = contractInterfaceManager->getAllTopicsAndAddresses

    Assert.equal(
      addresses->Array.length,
      2,
      ~message="Expected same amount of addresses as contract adderesses in config",
    )

    Assert.equal(
      topics->Array.length,
      9,
      ~message="Expected same amount of topics as number of events in config",
    )
  })

  it("Single address config gets all topics and addresses for filters", () => {
    let chainConfig =
      RegisterHandlers.registerAllHandlers().chainMap->ChainMap.get(MockConfig.chain1337)
    let contractAddress =
      "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Address.Evm.fromStringOrThrow

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
      8,
      ~message="Expected same amount of topics as number of events in config",
    )
  })

  it("Combined Interface Manager matches the values from single Interface Managers", () => {
    let chainConfig =
      RegisterHandlers.registerAllHandlers().chainMap->ChainMap.get(MockConfig.chain1337)
    let gravatarAddress =
      "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Address.Evm.fromStringOrThrow

    let gravatarIM = makeFromSingleContract(
      ~contractAddress=gravatarAddress,
      ~contractName="Gravatar",
      ~chainConfig,
    )
    let {addresses: gravatarAddresses, topics: gravatarTopics} =
      gravatarIM->getAllTopicsAndAddresses

    let nftFactoryAddress =
      "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Address.Evm.fromStringOrThrow

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
