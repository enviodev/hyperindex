open Types
open RescriptMocha
open Mocha
let {it: it_promise, it_skip: it_skip_promise, before: before_promise} = module(
  RescriptMocha.Promise
)

describe("E2E Mock Event Batch", () => {
  before(() => {
    RegisterHandlers.registerAllHandlers()
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    //EventProcessing.processEventBatch(MockEvents.eventBatch)
    MockEvents.eventRouterBatch->Belt.Array.forEach(event => event->EventProcessing.eventRouter)
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

describe("E2E Db check", () => {
  before_promise(async () => {
    RegisterHandlers.registerAllHandlers()

    let _ = await DbFunctions.Gravatar.batchSetGravatar(
      Migrations.sql,
      [MockEntities.mockInMemRow1, MockEntities.mockInMemRow2],
    )

    let arbitraryMaxQueueSize = 100

    //Note this is not a matching config for the mock events
    //Unneeded for this test since the chain manager does not need
    //to fetch nested events from dynamic contracts
    let mockChainManager = ChainManager.make(
      ~configs=Config.config,
      ~maxQueueSize=arbitraryMaxQueueSize,
      ~shouldSyncFromRawEvents=false,
    )

    await EventProcessing.processEventBatch(
      ~eventBatch=MockEvents.eventBatchItems,
      ~chainManager=mockChainManager,
    )
    //// TODO: write code (maybe via dependency injection) to allow us to use the stub rather than the actual database here.
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    // await EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
  })

  it("Validate inmemory store state", () => {
    let inMemoryStoreRows = IO.InMemoryStore.Gravatar.values()

    Assert.deep_equal(
      inMemoryStoreRows,
      [
        {
          dbOp: Set,
          eventData: {
            chainId: 1337,
            eventId: "65537",
          },
          entity: {
            id: "1001",
            owner: "0x1230000000000000000000000000000000000000",
            displayName: "update1",
            imageUrl: "https://gravatar1.com",
            updatesCount: Ethers.BigInt.fromInt(2),
          },
        },
        {
          dbOp: Set,
          eventData: {
            chainId: 1337,
            eventId: "65537",
          },
          entity: {
            id: "1002",
            owner: "0x4560000000000000000000000000000000000000",
            displayName: "update2",
            imageUrl: "https://gravatar2.com",
            updatesCount: Ethers.BigInt.fromInt(2),
          },
        },
        {
          dbOp: Set,
          eventData: {
            chainId: 1337,
            eventId: "65537",
          },
          entity: {
            id: "1003",
            owner: "0x7890000000000000000000000000000000000000",
            displayName: "update3",
            imageUrl: "https://gravatar3.com",
            updatesCount: Ethers.BigInt.fromInt(2),
          },
        },
      ],
    )
  })
})
