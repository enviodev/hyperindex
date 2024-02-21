open Belt
open Types
open RescriptMocha
open Mocha
let {
  it: it_promise,
  it_skip: it_skip_promise,
  before: before_promise,
  after: after_promise,
} = module(RescriptMocha.Promise)

let inMemoryStore = IO.InMemoryStore.make()
describe("E2E Mock Event Batch", () => {
  before(() => {
    RegisterHandlers.registerAllHandlers()
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    //EventProcessing.processEventBatch(MockEvents.eventBatch)
    MockEvents.eventRouterBatch->Belt.Array.forEach(
      event => event->EventProcessing.eventRouter(~inMemoryStore, ~cb=_ => ()),
    )
  })

  after(() => {
    ContextMock.setMock->Sinon.resetStub
  })

  it("6 newgravatar event set calls in order", () => {
    let setCallFirstArgs =
      ContextMock.setMock->Sinon.getCalls->Belt.Array.map(call => call->Sinon.getCallFirstArg)

    Assert.deep_equal(
      setCallFirstArgs,
      [
        MockEvents.newGravatar1.id->Ethers.BigInt.toString,
        MockEvents.newGravatar2.id->Ethers.BigInt.toString,
        MockEvents.newGravatar3.id->Ethers.BigInt.toString,
        MockEvents.setGravatar1.id->Ethers.BigInt.toString,
        MockEvents.setGravatar2.id->Ethers.BigInt.toString,
        MockEvents.setGravatar3.id->Ethers.BigInt.toString,
      ],
    )
  })
})

// NOTE: skipping this test for now since there seems to be some invalid DB state. Need to investigate again.
// TODO: add a similar kind of test back again.
describe("E2E Db check", () => {
  before_promise(async () => {
    await DbHelpers.runUpDownMigration()

    RegisterHandlers.registerAllHandlers()

    let _ = await DbFunctions.Gravatar.batchSet(
      Migrations.sql,
      [MockEntities.gravatarSerialized1, MockEntities.gravatarSerialized2],
    )

    let checkContractIsRegisteredStub = (~chain, ~contractAddress, ~contractName) => {
      (chain, contractAddress, contractName)->ignore
      false
    }

    await EventProcessing.processEventBatch(
      ~inMemoryStore,
      ~eventBatch=MockEvents.eventBatchItems->List.fromArray,
      ~checkContractIsRegistered=checkContractIsRegisteredStub,
    )
    //// TODO: write code (maybe via dependency injection) to allow us to use the stub rather than the actual database here.
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    // await EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
  })

  it("Validate inmemory store state", () => {
    let inMemoryStoreRows = inMemoryStore.gravatar->IO.InMemoryStore.Gravatar.values

    let chainId = MockConfig.mockChainConfig.chain->ChainMap.Chain.toChainId
    let startBlock = MockConfig.mockChainConfig.startBlock

    Assert.deep_equal(
      inMemoryStoreRows,
      [
        MockEntities.makeDefaultSet(
          ~chainId,
          ~blockNumber=startBlock,
          ~logIndex=14,
          {
            id: "1001",
            owner_id: "0x1230000000000000000000000000000000000000",
            displayName: "update1",
            imageUrl: "https://gravatar1.com",
            updatesCount: Ethers.BigInt.fromInt(2),
            size: #MEDIUM,
          },
        ),
        MockEntities.makeDefaultSet(
          ~chainId,
          ~blockNumber=startBlock,
          ~logIndex=15,
          {
            id: "1002",
            owner_id: "0x4560000000000000000000000000000000000000",
            displayName: "update2",
            imageUrl: "https://gravatar2.com",
            updatesCount: Ethers.BigInt.fromInt(2),
            size: #MEDIUM,
          },
        ),
        MockEntities.makeDefaultSet(
          ~chainId,
          ~blockNumber=startBlock,
          ~logIndex=16,
          {
            id: "1003",
            owner_id: "0x7890000000000000000000000000000000000000",
            displayName: "update3",
            imageUrl: "https://gravatar3.com",
            updatesCount: Ethers.BigInt.fromInt(2),
            size: #MEDIUM,
          },
        ),
      ],
    )
  })
})
