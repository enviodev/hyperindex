open RescriptMocha
open Belt

let config = RegisterHandlers.getConfig()

module Mock = {
  let makeTransferMock = (~from, ~to, ~value): Types.ERC20.Transfer.eventArgs => {
    from,
    to,
    value: value->BigInt.fromInt,
  }

  let makeTokenCreatedMock = (~token): Types.ERC20Factory.TokenCreated.eventArgs => {
    token: token,
  }

  let mintAddress = Ethers.Constants.zeroAddress
  let userAddress1 = Ethers.Addresses.mockAddresses[1]->Option.getExn

  let mockDyamicToken1 = Ethers.Addresses.mockAddresses[3]->Option.getExn
  let mockDyamicToken2 = Ethers.Addresses.mockAddresses[4]->Option.getExn
  let mockDyamicToken3 = Ethers.Addresses.mockAddresses[5]->Option.getExn

  let deployToken1 = makeTokenCreatedMock(~token=mockDyamicToken1)
  let deployToken2 = makeTokenCreatedMock(~token=mockDyamicToken2)
  let deployToken3 = makeTokenCreatedMock(~token=mockDyamicToken3)

  let mint50ToUser1 = makeTransferMock(~from=mintAddress, ~to=userAddress1, ~value=50)

  let chain = ChainMap.Chain.makeUnsafe(~chainId=1)
  let mockChainDataEmpty = MockChainData.make(
    ~chainConfig=config.chainMap->ChainMap.get(chain),
    ~maxBlocksReturned=2,
    ~blockTimestampInterval=25,
  )

  let defaultTokenAddress = ChainDataHelpers.getDefaultAddress(
    chain,
    ChainDataHelpers.ERC20.contractName,
  )

  let factoryAddress = ChainDataHelpers.ERC20Factory.getDefaultAddress(chain)

  open ChainDataHelpers.ERC20
  open ChainDataHelpers.ERC20Factory
  let mkTransferToken1EventConstr = Transfer.mkEventConstrWithParamsAndAddress(
    ~srcAddress=mockDyamicToken1,
    ~params=_,
    ...
  )
  let mkTransferToken2EventConstr = Transfer.mkEventConstrWithParamsAndAddress(
    ~srcAddress=mockDyamicToken2,
    ~params=_,
    ...
  )
  let mkTokenCreatedEventConstr = TokenCreated.mkEventConstrWithParamsAndAddress(
    ~srcAddress=factoryAddress,
    ~params=_,
    ...
  )

  let b0 = [deployToken1->mkTokenCreatedEventConstr, mint50ToUser1->mkTransferToken1EventConstr]
  let b1 = [deployToken2->mkTokenCreatedEventConstr, deployToken3->mkTokenCreatedEventConstr]
  let b2 = [deployToken3->mkTokenCreatedEventConstr, deployToken2->mkTokenCreatedEventConstr]

  let blocks = [b0, b1, b2]

  let mockChainData = blocks->Array.reduce(mockChainDataEmpty, (accum, makeLogConstructors) => {
    accum->MockChainData.addBlock(~makeLogConstructors)
  })
}

describe_only("dynamic contract event processing test", () => {
  Async.it("One registration event + non registration event", async () => {
    let block0 = Mock.mockChainData.blocks->Js.Array2.unsafe_get(0)
    let block0Events = block0.logs->Array.map(l => l.eventBatchQueueItem)
    let res = await EventProcessing.processEventBatch(
      ~eventBatch=block0Events,
      ~config,
      ~loadLayer=Utils.magic("Mock load layer"),
      ~inMemoryStore=InMemoryStore.make(),
      ~isInReorgThreshold=false,
      ~latestProcessedBlocks=EventProcessing.EventsProcessed.makeEmpty(~config),
      ~checkContractIsRegistered=(~chain as _, ~contractAddress as _, ~contractName as _) => false,
    )
    switch res {
    | Ok({dynamicContractRegistrations: Some({registrations, unprocessedBatch})}) =>
      let individualRegistrations = registrations->Array.flatMap(r => r.dynamicContracts)
      Assert.equal(
        individualRegistrations->Js.Array2.length,
        1,
        ~message="Should have registered 1 dynamic contract",
      )
      Assert.equal(
        unprocessedBatch->Array.length,
        2,
        ~message="The registration event & the following should be unprocessed",
      )
    | _ => Assert.fail("Should have processed event batch with dynamic contract registration")
    }
  })

  Async.it("One registration event with dynamicContracts, one without", async () => {
    let block1 = Mock.mockChainData.blocks->Js.Array2.unsafe_get(1)
    let block1Events = block1.logs->Array.map(l => l.eventBatchQueueItem)
    let res = await EventProcessing.processEventBatch(
      ~eventBatch=block1Events,
      ~config,
      ~loadLayer=Utils.magic("Mock load layer"),
      ~inMemoryStore=InMemoryStore.make(),
      ~isInReorgThreshold=false,
      ~latestProcessedBlocks=EventProcessing.EventsProcessed.makeEmpty(~config),
      //As if dynamic token 3 is already registered
      ~checkContractIsRegistered=(~chain as _, ~contractAddress, ~contractName as _) =>
        contractAddress == Mock.mockDyamicToken3,
    )
    switch res {
    | Ok({dynamicContractRegistrations: Some({registrations, unprocessedBatch})}) =>
      let individualRegistrations = registrations->Array.flatMap(r => r.dynamicContracts)
      Assert.equal(
        individualRegistrations->Js.Array2.length,
        1,
        ~message="Should have registered 1 dynamic contract, (the second registration already exists based on the passed in check function)",
      )
      Assert.equal(
        unprocessedBatch->Array.length,
        2,
        ~message="Both registration events should be unprocessed, even with a registration event that produces no contract registrations",
      )
    | _ => Assert.fail("Should have processed event batch with dynamic contract registration")
    }
  })
  Async.it("One event without dynamicContracts, one with", async () => {
    let block2 = Mock.mockChainData.blocks->Js.Array2.unsafe_get(2)
    let block2Events = block2.logs->Array.map(l => l.eventBatchQueueItem)
    let res = await EventProcessing.processEventBatch(
      ~eventBatch=block2Events,
      ~config,
      ~loadLayer=Utils.magic("Mock load layer"),
      ~inMemoryStore=InMemoryStore.make(),
      ~isInReorgThreshold=false,
      ~latestProcessedBlocks=EventProcessing.EventsProcessed.makeEmpty(~config),
      //As if dynamic token 3 is already registered
      ~checkContractIsRegistered=(~chain as _, ~contractAddress, ~contractName as _) =>
        contractAddress == Mock.mockDyamicToken3,
    )
    switch res {
    | Ok({dynamicContractRegistrations: Some({registrations, unprocessedBatch})}) =>
      let individualRegistrations = registrations->Array.flatMap(r => r.dynamicContracts)
      Assert.equal(
        individualRegistrations->Js.Array2.length,
        1,
        ~message="Should have registered 1 dynamic contract",
      )
      Assert.equal(
        unprocessedBatch->Array.length,
        1,
        ~message="The first event was processed before the actual registration, only one event should be unprocessed",
      )
    | _ => Assert.fail("Should have processed event batch with dynamic contract registration")
    }
  })
})
