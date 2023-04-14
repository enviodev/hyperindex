open Jest
open Expect
open Types

describe("E2E Mock Event Batch", () => {
  beforeAllPromise(async () => {
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    await EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=ContextMock.mockContext)
  })

  afterAll(() => {
    ContextMock.insertMock->MockJs.mockClear
    ContextMock.updateMock->MockJs.mockClear
  })

  test("3 newgravatar event insert calls in order", () => {
    let insertCalls = ContextMock.insertMock->MockJs.calls
    expect(insertCalls)->toEqual([
      MockEvents.newGravatar1.id,
      MockEvents.newGravatar2.id,
      MockEvents.newGravatar3.id,
    ])
  })

  test("3 updategravatar event insert calls in order", () => {
    let insertCalls = ContextMock.insertMock->MockJs.calls
    expect(insertCalls)->toEqual([
      MockEvents.updatedGravatar1.id,
      MockEvents.updatedGravatar2.id,
      MockEvents.updatedGravatar3.id,
    ])
  })
})

describe("E2E Db check", () => {
  beforeAllPromise(async () => {
    let _ = await DbFunctions.batchSetGravatar([
      MockEntities.gravatarEntity1,
      MockEntities.gravatarEntity2,
    ])
    await EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
    //// TODO: write code (maybe via dependency injection) to allow us to use the stub rather than the actual database here.
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    // await EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
  })

  test("Validate inmemory store state", () => {
    let inMemoryStore = IO.InMemoryStore.gravatarDict.contents
    let inMemoryStoreRows = inMemoryStore->Js.Dict.values
    expect(inMemoryStoreRows)->toEqual([
      {
        crud: Update,
        entity: {
          id: "1001",
          owner: "0x123",
          displayName: "update1",
          imageUrl: "https://gravatar1.com",
          updatesCount: 2,
        },
      },
      {
        crud: Update,
        entity: {
          id: "1002",
          owner: "0x456",
          displayName: "update2",
          imageUrl: "https://gravatar2.com",
          updatesCount: 2,
        },
      },
      {
        crud: Create, // NOTE: if this is not run against a fresh database it will get an `Update` instead of `Create`
        entity: {
          id: "1003",
          owner: "0x789",
          displayName: "update3",
          imageUrl: "https://gravatar3.com",
          updatesCount: 2,
        },
      },
    ])
  })
})
