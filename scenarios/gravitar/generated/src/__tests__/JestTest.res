open Jest
open Expect
open Types
describe("E2E Mock Event Batch", () => {
  beforeAllPromise(async () => {
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    await EventProcessing.processEventBatch(MockEvents.eventBatch)
  })

  afterAll(() => {
    ContextStub.insertMock->MockJs.mockClear
    ContextStub.updateMock->MockJs.mockClear
  })

  test("3 newGravitar event insert calls in order", () => {
    let insertCalls = ContextStub.insertMock->MockJs.calls
    expect(insertCalls)->toEqual([
      MockEvents.newGravatar1.id,
      MockEvents.newGravatar2.id,
      MockEvents.newGravatar3.id,
    ])
  })

  test("3 updateGravitar event insert calls in order", () => {
    let insertCalls = ContextStub.insertMock->MockJs.calls
    expect(insertCalls)->toEqual([
      MockEvents.updatedGravatar1.id,
      MockEvents.updatedGravatar2.id,
      MockEvents.updatedGravatar3.id,
    ])
  })

  test("Validate inmemory store state", () => {
    let inMemoryStore = IO.InMemoryStore.gravatarDict.contents
    let inMemoryStoreRows = inMemoryStore->Js.Dict.values
    expect(inMemoryStoreRows)->toEqual([
      {
        crud: Update,
        entity: {
          id: "1",
          owner: "0x123",
          displayName: "update1",
          imageUrl: "https://gravatar1.com",
          updatesCount: 2,
        },
      },
      {
        crud: Update,
        entity: {
          id: "2",
          owner: "0x456",
          displayName: "update2",
          imageUrl: "https://gravatar2.com",
          updatesCount: 2,
        },
      },
      {
        crud: Create,
        entity: {
          id: "3",
          owner: "0x789",
          displayName: "update3",
          imageUrl: "https://gravatar3.com",
          updatesCount: 2,
        },
      },
    ])
  })
})
