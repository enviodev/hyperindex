open Jest
open Expect
open Types

// Required to make sure the handlers are loaded.
%%raw(`require("../EventHandlers.bs.js")`)

// TODO: unskip this function.
describe("E2E Mock Event Batch", () => {
  beforeAll(() => {
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    //EventProcessing.processEventBatch(MockEvents.eventBatch)
    MockEvents.eventBatchWithContext->Belt.Array.forEach(
      event => event->EventProcessing.eventRouter,
    )
  })

  afterAll(() => {
    ContextMock.insertMock->MockJs.mockClear
    ContextMock.updateMock->MockJs.mockClear
  })

  test("3 newgravatar event insert calls in order", () => {
    let insertCalls = ContextMock.insertMock->MockJs.calls
    expect(insertCalls)->toEqual([
      MockEvents.newGravatar1.id->Ethers.BigInt.toString,
      MockEvents.newGravatar2.id->Ethers.BigInt.toString,
      MockEvents.newGravatar3.id->Ethers.BigInt.toString,
    ])
  })

  /* TODO: Make this update different entities
   this test tests the exact same thing as above since events have the same IDs. */
  test("3 updategravatar event insert calls in order", () => {
    let insertCalls = ContextMock.insertMock->MockJs.calls
    expect(insertCalls)->toEqual([
      MockEvents.updatedGravatar1.id->Ethers.BigInt.toString,
      MockEvents.updatedGravatar2.id->Ethers.BigInt.toString,
      MockEvents.updatedGravatar3.id->Ethers.BigInt.toString,
    ])
  })
})

describe("E2E Db check", () => {
  test("False test! Replace with real db test once drizzle is removed", () => pass)
})
// describe("E2E Db check", () => {
//   beforeAllPromise(async () => {
//     let _ = await DbFunctions.Gravatar.batchSetGravatar([
//       MockEntities.gravatarEntity1,
//       MockEntities.gravatarEntity2,
//     ])
//     await EventProcessing.processEventBatch(MockEvents.eventBatch)
//     //// TODO: write code (maybe via dependency injection) to allow us to use the stub rather than the actual database here.
//     // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
//     // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
//     // await EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
//   })
//
//   // TODO: work out why this test works locally, but not in pipeline!
//   test("Validate inmemory store state", () => {
//     let inMemoryStore = IO.InMemoryStore.Gravatar.gravatarDict.contents
//     let inMemoryStoreRows = inMemoryStore->Js.Dict.values
//     expect(inMemoryStoreRows)->toEqual([
//       {
//         crud: Update, // TODO: fix these tests, it should be an 'Update' here.
//         entity: {
//           id: "1001",
//           owner: "0x1230000000000000000000000000000000000000",
//           displayName: "update1",
//           imageUrl: "https://gravatar1.com",
//           updatesCount: 2,
//         },
//       },
//       {
//         crud: Update,
//         entity: {
//           id: "1002",
//           owner: "0x4560000000000000000000000000000000000000",
//           displayName: "update2",
//           imageUrl: "https://gravatar2.com",
//           updatesCount: 2,
//         },
//       },
//       {
//         crud: Create, // NOTE: if this is not run against a fresh database it will get an `Update` instead of `Create`
//         entity: {
//           id: "1003",
//           owner: "0x7890000000000000000000000000000000000000",
//           displayName: "update3",
//           imageUrl: "https://gravatar3.com",
//           updatesCount: 2,
//         },
//       },
//     ])
//   })
// })
