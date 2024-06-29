open Belt
open RescriptMocha

let inMemoryStore = InMemoryStore.make()

describe("E2E Mock Event Batch", () => {
  Async.before(async () => {
    RegisterHandlers.registerAllHandlers()
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    // EventProcessing.processEventBatch(MockEvents.eventBatch)

    let runEventHandler = async (
      type eventArgs,
      event,
      eventMod: module(Types.Event with type eventArgs = eventArgs),
    ) => {
      let module(Event) = eventMod
      switch RegisteredEvents.global
      ->RegisteredEvents.get(Event.eventName)
      ->Option.flatMap(registeredEvent => registeredEvent.loaderHandler) {
      | Some(handler) =>
        await event->EventProcessing.runEventHandler(
          ~handler,
          ~latestProcessedBlocks=EventProcessing.EventsProcessed.makeEmpty(),
          ~inMemoryStore,
          ~logger=Logging.logger,
          ~chain=Chain_1,
          ~eventMod,
        )
      | None => Ok(EventProcessing.EventsProcessed.makeEmpty())
      }
    }

    for i in 0 to MockEvents.eventBatch->Array.length - 1 {
      let event = MockEvents.eventBatch[i]->Option.getUnsafe

      let res = switch event {
      | Gravatar_NewGravatar(event) =>
        await event->runEventHandler(module(Types.Gravatar.NewGravatar))
      | Gravatar_UpdatedGravatar(event) =>
        await event->runEventHandler(module(Types.Gravatar.UpdatedGravatar))
      | _ => Js.Exn.raiseError("Unhandled mock event")
      }
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

    RegisterHandlers.registerAllHandlers()

    let _ = await Entities.batchSet(~entityMod=module(Entities.Gravatar))(
      Migrations.sql,
      [MockEntities.gravatarEntity1, MockEntities.gravatarEntity2],
    )

    let checkContractIsRegisteredStub = (~chain, ~contractAddress, ~contractName) => {
      (chain, contractAddress, contractName)->ignore
      false
    }

    let _ = await EventProcessing.processEventBatch(
      ~inMemoryStore,
      ~eventBatch=MockEvents.eventBatchItems->List.fromArray,
      ~checkContractIsRegistered=checkContractIsRegisteredStub,
      ~latestProcessedBlocks=EventProcessing.EventsProcessed.makeEmpty(),
      ~registeredEvents=RegisteredEvents.global,
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
