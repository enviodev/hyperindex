open Belt
open RescriptMocha

let inMemoryStore = InMemoryStore.make()

describe("E2E Mock Event Batch", () => {
  Async.before(async () => {
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    // EventProcessing.processEventBatch(MockEvents.eventBatch)

    let loadLayer = LoadLayer.makeWithDbConnection()

    let runEventHandler = async (eventBatchQueueItem: Types.eventBatchQueueItem) => {
      switch eventBatchQueueItem.handlerRegister->Types.HandlerTypes.Register.getLoaderHandler {
      | Some(loaderHandler) =>
        await eventBatchQueueItem->EventProcessing.runEventHandler(
          ~loaderHandler,
          ~inMemoryStore,
          ~logger=Logging.logger,
          ~loadLayer,
          ~isInReorgThreshold=false,
        )
      | None => Ok()
      }
    }

    for i in 0 to MockEvents.eventBatchItems->Array.length - 1 {
      let batchItem = MockEvents.eventBatchItems->Js.Array2.unsafe_get(i)
      let res = await batchItem->runEventHandler
      switch res {
      | Error(e) => e->ErrorHandling.logAndRaise
      | Ok(_) => ()
      }
    }
  })
})

// NOTE: skipping this test for now since there seems to be some invalid DB state. Need to investigate again.
// TODO: add a similar kind of test back again.
describe_skip("E2E Db check", () => {
  Async.before(async () => {
    await DbHelpers.runUpDownMigration()

    let config = RegisterHandlers.registerAllHandlers()
    let loadLayer = LoadLayer.makeWithDbConnection()

    let _ = await DbFunctionsEntities.batchSet(~entityMod=module(Entities.Gravatar))(
      Migrations.sql,
      [MockEntities.gravatarEntity1, MockEntities.gravatarEntity2],
    )

    let checkContractIsRegisteredStub = (~chain, ~contractAddress, ~contractName) => {
      (chain, contractAddress, contractName)->ignore
      false
    }

    let _ = await EventProcessing.processEventBatch(
      ~inMemoryStore,
      ~eventBatch=MockEvents.eventBatchItems,
      ~checkContractIsRegistered=checkContractIsRegisteredStub,
      ~latestProcessedBlocks=EventProcessing.EventsProcessed.makeEmpty(~config),
      ~loadLayer,
      ~config,
      ~isInReorgThreshold=false,
    )

    //// TODO: write code (maybe via dependency injection) to allow us to use the stub rather than the actual database here.
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    // await EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
  })

  it("Validate inmemory store state", () => {
    let gravatars = inMemoryStore.gravatar->InMemoryTable.Entity.values

    Assert.deepEqual(
      gravatars,
      [
        {
          id: "1001",
          owner_id: "0x1230000000000000000000000000000000000000",
          displayName: "update1",
          imageUrl: "https://gravatar1.com",
          updatesCount: BigInt.fromInt(2),
          size: MEDIUM,
        },
        {
          id: "1002",
          owner_id: "0x4560000000000000000000000000000000000000",
          displayName: "update2",
          imageUrl: "https://gravatar2.com",
          updatesCount: BigInt.fromInt(2),
          size: MEDIUM,
        },
        {
          id: "1003",
          owner_id: "0x7890000000000000000000000000000000000000",
          displayName: "update3",
          imageUrl: "https://gravatar3.com",
          updatesCount: BigInt.fromInt(2),
          size: MEDIUM,
        },
      ],
    )
  })
})
