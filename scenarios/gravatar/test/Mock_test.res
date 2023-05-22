open Types
open RescriptMocha
open Mocha
let {it: it_promise, it_skip: it_skip_promise, before: before_promise} = module(
  RescriptMocha.Promise
)
let chainId = (Config.config->Js.Dict.values)[0].chainId

describe("E2E Mock Event Batch", () => {
  before(() => {
    RegisterHandlers.registerAllHandlers()
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    //EventProcessing.processEventBatch(MockEvents.eventBatch)
    MockEvents.eventBatchWithContext->Belt.Array.forEach(
      event => event->EventProcessing.eventRouter(~chainId),
    )
  })

  after(() => {
    ContextMock.insertMock->Sinon.resetStub
    ContextMock.updateMock->Sinon.resetStub
  })

  it("3 newgravatar event insert calls in order", () => {
    let insertCallFirstArgs =
      ContextMock.insertMock->Sinon.getCalls->Belt.Array.map(call => call->Sinon.getCallFirstArg)

    Assert.deep_equal(
      [
        MockEvents.newGravatar1.id->Ethers.BigInt.toString,
        MockEvents.newGravatar2.id->Ethers.BigInt.toString,
        MockEvents.newGravatar3.id->Ethers.BigInt.toString,
      ],
      insertCallFirstArgs,
    )
  })

  /* TODO: Make this update different entities
   this test tests the exact same thing as above since events have the same IDs. */
  it("3 updategravatar event insert calls in order", () => {
    let insertCallFirstArgs =
      ContextMock.insertMock->Sinon.getCalls->Belt.Array.map(call => call->Sinon.getCallFirstArg)

    Assert.deep_equal(
      insertCallFirstArgs,
      [
        MockEvents.updatedGravatar1.id->Ethers.BigInt.toString,
        MockEvents.updatedGravatar2.id->Ethers.BigInt.toString,
        MockEvents.updatedGravatar3.id->Ethers.BigInt.toString,
      ],
    )
  })
})

describe("E2E Db check", () => {
  before_promise(async () => {
    let _ = await DbFunctions.Gravatar.batchSetGravatar([
      MockEntities.mockInMemRow1,
      MockEntities.mockInMemRow2,
    ])
    await MockEvents.eventBatch->EventProcessing.processEventBatch(~chainId)
    //// TODO: write code (maybe via dependency injection) to allow us to use the stub rather than the actual database here.
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    // await EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
  })

  // TODO: work out why this test works locally, but not in pipeline!
  it("Validate inmemory store state", () => {
    let inMemoryStore = IO.InMemoryStore.Gravatar.gravatarDict.contents
    let inMemoryStoreRows = inMemoryStore->Js.Dict.values
    Assert.deep_equal(
      inMemoryStoreRows,
      [
        {
          crud: Update, // TODO: fix these tests, it should be an 'Update' here.
          eventData: {
            chainId: 1337,
            eventId: 65537->Ethers.BigInt.fromInt,
          },
          entity: {
            id: "1001",
            owner: "0x1230000000000000000000000000000000000000",
            displayName: "update1",
            imageUrl: "https://gravatar1.com",
            updatesCount: 2,
          },
        },
        {
          crud: Update,
          eventData: {
            chainId: 1337,
            eventId: 65537->Ethers.BigInt.fromInt,
          },
          entity: {
            id: "1002",
            owner: "0x4560000000000000000000000000000000000000",
            displayName: "update2",
            imageUrl: "https://gravatar2.com",
            updatesCount: 2,
          },
        },
        {
          crud: Create, // NOTE: if this is not run against a fresh database it will get an `Update` instead of `Create`
          eventData: {
            chainId: 1337,
            eventId: 65537->Ethers.BigInt.fromInt,
          },
          entity: {
            id: "1003",
            owner: "0x7890000000000000000000000000000000000000",
            displayName: "update3",
            imageUrl: "https://gravatar3.com",
            updatesCount: 2,
          },
        },
      ],
    )
  })
})
