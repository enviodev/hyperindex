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
    MockEvents.eventBatch->Belt.Array.forEach(
      event =>
        event->EventProcessing.eventRouter(
          ~inMemoryStore,
          ~cb=_ => (),
          ~latestProcessedBlocks=EventProcessing.EventsProcessed.makeEmpty(),
        ),
    )
  })
})

// NOTE: skipping this test for now since there seems to be some invalid DB state. Need to investigate again.
// TODO: add a similar kind of test back again.
describe_skip("E2E Db check", () => {
  before_promise(async () => {
    await DbHelpers.runUpDownMigration()

    RegisterHandlers.registerAllHandlers()

    let _ = await Entities.batchSet(
      ~entityMod=module(Entities.Gravatar),
      Migrations.sql,
      [MockEntities.gravatarEntity1, MockEntities.gravatarEntity2],
    )

    let checkContractIsRegisteredStub = (~chain, ~contractAddress, ~contractName) => {
      (chain, contractAddress, contractName)->ignore
      false
    }

    await EventProcessing.processEventBatch(
      ~inMemoryStore,
      ~eventBatch=MockEvents.eventBatchItems->List.fromArray,
      ~checkContractIsRegistered=checkContractIsRegisteredStub,
      ~latestProcessedBlocks=EventProcessing.EventsProcessed.makeEmpty(),
    )
    //// TODO: write code (maybe via dependency injection) to allow us to use the stub rather than the actual database here.
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    // DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    // await EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
  })

  it("Validate inmemory store state", () => {
    let inMemoryStoreRows = inMemoryStore.gravatar->IO.InMemoryStore.Gravatar.values
    let gravatars = inMemoryStoreRows->Belt.Array.map(
      row =>
        switch row {
        | Updated({latest: {entityUpdateAction: Set(_)}}) => None
        | Updated({latest: {entityUpdateAction: Delete(id)}}) => Some(id)
        | InitialReadFromDb(_) => None
        },
    )
    Js.log2("gravatars", gravatars)

    Assert.deep_equal(
      inMemoryStoreRows->Belt.Array.map(
        row =>
          switch row {
          | Updated({latest: {entityUpdateAction: Set(latestEntity)}}) => Some(latestEntity)
          | Updated({latest: {entityUpdateAction: Delete(_)}}) => None
          | InitialReadFromDb(_) => None
          },
      ),
      [
        Some({
          id: "1001",
          owner_id: "0x1230000000000000000000000000000000000000",
          displayName: "update1",
          imageUrl: "https://gravatar1.com",
          updatesCount: Ethers.BigInt.fromInt(2),
          size: MEDIUM,
        }),
        Some({
          id: "1002",
          owner_id: "0x4560000000000000000000000000000000000000",
          displayName: "update2",
          imageUrl: "https://gravatar2.com",
          updatesCount: Ethers.BigInt.fromInt(2),
          size: MEDIUM,
        }),
        Some({
          id: "1003",
          owner_id: "0x7890000000000000000000000000000000000000",
          displayName: "update3",
          imageUrl: "https://gravatar3.com",
          updatesCount: Ethers.BigInt.fromInt(2),
          size: MEDIUM,
        }),
      ],
    )
  })
})
