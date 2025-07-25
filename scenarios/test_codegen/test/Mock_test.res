open RescriptMocha

let inMemoryStore = InMemoryStore.make()

describe("E2E Mock Event Batch", () => {
  Async.before(async () => {
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    // EventProcessing.processEventBatch(MockEvents.eventBatch)

    let loadManager = LoadManager.make()
    let storage = Config.codegenPersistence.storage

    try {
      await MockEvents.eventBatchItems->EventProcessing.runBatchHandlersOrThrow(
        ~inMemoryStore,
        ~loadManager,
        ~storage,
        ~config=RegisterHandlers.getConfig(),
        ~shouldSaveHistory=false,
        ~shouldBenchmark=false,
      )
    } catch {
    | EventProcessing.ProcessingError({message, exn, eventItem}) =>
      exn
      ->ErrorHandling.make(~msg=message, ~logger=eventItem->Logging.getEventLogger)
      ->ErrorHandling.logAndRaise
    }
  })
})

// NOTE: skipping this test for now since there seems to be some invalid DB state. Need to investigate again.
// TODO: add a similar kind of test back again.
// describe_skip("E2E Db check", () => {
//   Async.before(async () => {
//     await DbHelpers.runUpDownMigration()

//     let config = RegisterHandlers.registerAllHandlers()
//     let loadLayer = LoadLayer.makeWithDbConnection()

//     let _ = await DbFunctionsEntities.batchSet(~entityMod=module(Entities.Gravatar))(
//       Migrations.sql,
//       [MockEntities.gravatarEntity1, MockEntities.gravatarEntity2],
//     )

//     let _ = await EventProcessing.processEventBatch(
//       ~inMemoryStore,
//       ~eventBatch=MockEvents.eventBatchItems,
//       ~latestProcessedBlocks=EventProcessing.EventsProcessed.makeEmpty(~config),
//       ~loadLayer,
//       ~config,
//       ~isInReorgThreshold=false,
//     )

//     //// TODO: write code (maybe via dependency injection) to allow us to use the stub rather than the actual database here.
//     // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
//     // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
//     // await EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
//   })

//   it("Validate inmemory store state", () => {
//     let gravatars =
//       inMemoryStore.entities
//       ->InMemoryStore.EntityTables.get(module(Entities.Gravatar))
//       ->InMemoryTable.Entity.values

//     Assert.deepEqual(
//       gravatars,
//       [
//         {
//           id: "1001",
//           owner_id: "0x1230000000000000000000000000000000000000",
//           displayName: "update1",
//           imageUrl: "https://gravatar1.com",
//           updatesCount: BigInt.fromInt(2),
//           size: MEDIUM,
//         },
//         {
//           id: "1002",
//           owner_id: "0x4560000000000000000000000000000000000000",
//           displayName: "update2",
//           imageUrl: "https://gravatar2.com",
//           updatesCount: BigInt.fromInt(2),
//           size: MEDIUM,
//         },
//         {
//           id: "1003",
//           owner_id: "0x7890000000000000000000000000000000000000",
//           displayName: "update3",
//           imageUrl: "https://gravatar3.com",
//           updatesCount: BigInt.fromInt(2),
//           size: MEDIUM,
//         },
//       ],
//     )
//   })
// })
