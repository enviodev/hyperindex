open RescriptMocha
module MochaPromise = RescriptMocha.Promise
open Mocha

/// NOTE: diagrams for these tests can be found here: https://www.figma.com/file/TrBPqQHYoJ8wg6e0kAynZo/Scenarios-to-test-Linked-Entities?type=whiteboard&node-id=0%3A1&t=CZAE4T4oY9PCbszw-1

describe_skip("Linked Entity Loader Integration Test", () => {
  // TODO check if this test is relevent after v2 loader api
  ()
  // MochaPromise.before(async () => {
  //   DbHelpers.runUpDownMigration()
  // })
  //
  // MochaPromise.after(async () => {
  //   // It is probably overkill that we are running these 'after' also
  //   DbHelpers.runUpDownMigration()
  // })
  //
  // MochaPromise.it_skip("Test Linked Entity Loader Scenario 1", ~timeout=5 * 1000, async () => {
  //   let sql = DbFunctions.sql
  //   /// Setup DB
  //   let a1: Types.a = {optionalStringToTestLinkedEntities: None, id: "a1", b_id: "b1"}
  //   let a2: Types.a = {optionalStringToTestLinkedEntities: None, id: "a2", b_id: "b2"}
  //   let aEntities: array<Types.aEntity> = [
  //     a1,
  //     a2,
  //     {optionalStringToTestLinkedEntities: None, id: "a3", b_id: "b3"},
  //     {optionalStringToTestLinkedEntities: None, id: "a4", b_id: "b4"},
  //     {optionalStringToTestLinkedEntities: None, id: "a5", b_id: "bWontLoad"},
  //     {optionalStringToTestLinkedEntities: None, id: "a6", b_id: "bWontLoad"},
  //     {optionalStringToTestLinkedEntities: None, id: "aWontLoad", b_id: "bWontLoad"},
  //   ]
  //   let bEntities: array<Types.bEntity> = [
  //     {id: "b1", c_id: Some("c1")},
  //     {id: "b2", c_id: Some("c2")},
  //     {id: "b3", c_id: None},
  //     {id: "b4", c_id: Some("c3")},
  //     {id: "bWontLoad", c_id: None},
  //   ]
  //   let cEntities: array<Types.cEntity> = [
  //     {id: "c1", a_id: "aWontLoad", stringThatIsMirroredToA: ""},
  //     {id: "c2", a_id: "a5", stringThatIsMirroredToA: ""},
  //     {id: "c3", a_id: "a6", stringThatIsMirroredToA: ""},
  //     {id: "TODO_TURN_THIS_INTO_NONE", a_id: "aWontLoad", stringThatIsMirroredToA: ""},
  //   ]
  //
  //   await Entities.batchSet(sql, aEntities, ~entityMod=module(Entities.A))
  //   await Entities.batchSet(sql, bEntities, ~entityMod=module(Entities.B))
  //   await Entities.batchSet(sql, cEntities, ~entityMod=module(Entities.C))
  //
  //   let inMemoryStore = IO.InMemoryStore.make()
  //
  //   let context = Context.make(
  //     ~inMemoryStore,
  //     ~chain=Chain_1,
  //     ~event={
  //       "devMsg": "This is a placeholder event",
  //       "blockNumber": 456,
  //       "chainId": 1,
  //       "logIndex": 0,
  //       "blockTimestamp": 123,
  //     }->X.magic,
  //     ~logger=Logging.logger,
  //     ~asyncGetters=EventProcessing.asyncGetters,
  //   )
  //
  //   let loaderContext = context->Context.getLoaderContext
  //   let idsToLoad = ["a1", "a2", "a7" /* a7 doesn't exist */]
  //   let _aLoader = loaderContext.a.allLoad(idsToLoad, ~loaders={loadB: {loadC: {}}})
  //
  //   let entitiesToLoad = context.getEntitiesToLoad()
  //
  //   await IO.loadEntitiesToInMemStore(~inMemoryStore, ~entityBatch=entitiesToLoad)
  //
  //   let handlerContext = context.getHandlerContextSync()
  //
  //   let testingA = handlerContext.a.all
  //
  //   Assert.deep_equal(
  //     testingA,
  //     [Some(a1), Some(a2), None],
  //     ~message="testingA should have correct items",
  //   )
  //
  //   let optA1 = testingA->Belt.Array.getUnsafe(0)
  //   Assert.deep_equal(optA1, Some(a1), ~message="Incorrect entity loaded")
  //
  //   // TODO/NOTE: I want to re-work these linked entity loader functions to just have the values, rather than needing to call a function. Unfortunately challenging due to dynamic naturue.
  //   let b1 = handlerContext.a.getB(a1)
  //
  //   Assert.deep_equal(b1.id, a1.b_id, ~message="b1.id should equal testingA.b_id")
  //
  //   let c1 = handlerContext.b.getC(b1)
  //   Assert.equal(c1->Belt.Option.map(c => c.id), b1.c_id, ~message="c1.id should equal b1.c_id")
  // })
  //
  // MochaPromise.it("Test Linked Entity Loader Scenario 2", ~timeout=5 * 1000, async () => {
  //   let sql = DbFunctions.sql
  //
  //   /// Setup DB
  //   let a1: Types.a = {id: "a1", b_id: "b1", optionalStringToTestLinkedEntities: None}
  //   let aEntities: array<Types.aEntity> = [
  //     a1,
  //     {id: "a2", b_id: "b1", optionalStringToTestLinkedEntities: None},
  //     {id: "a3", b_id: "b1", optionalStringToTestLinkedEntities: None},
  //     {id: "a4", b_id: "b1", optionalStringToTestLinkedEntities: None},
  //     {id: "aWontLoad", b_id: "bWontLoad", optionalStringToTestLinkedEntities: None},
  //   ]
  //   let bEntities: array<Types.bEntity> = [
  //     {id: "b1", c_id: Some("c1")},
  //     {id: "bWontLoad", c_id: None},
  //   ]
  //   let cEntities: array<Types.cEntity> = [
  //     {id: "c1", a_id: "aWontLoad", stringThatIsMirroredToA: ""},
  //   ]
  //
  //   await DbFunctions.A.batchSet(sql, aEntities)
  //   await DbFunctions.B.batchSet(sql, bEntities)
  //   await DbFunctions.C.batchSet(sql, cEntities)
  //
  //   let inMemoryStore = IO.InMemoryStore.make()
  //   let context = Context.Gravatar.TestEventEvent.contextCreator(
  //     ~inMemoryStore,
  //     ~chainId=123,
  //     ~event={"devMsg": "This is a placeholder event", "blockNumber": 456}->X.magic,
  //     ~logger=Logging.logger,
  //     ~asyncGetters=EventProcessing.asyncGetters,
  //   )
  //
  //   let loaderContext = context.getLoaderContext()
  //
  //   loaderContext.a.allLoad(["a1"], ~loaders={loadB: {loadC: {}}})
  //
  //   let entitiesToLoad = context.getEntitiesToLoad()
  //
  //   await IO.loadEntitiesToInMemStore(~inMemoryStore, ~entityBatch=entitiesToLoad)
  //
  //   let handlerContext = context.getHandlerContextSync()
  //
  //   let testingA = handlerContext.a.all
  //
  //   Assert.deep_equal([Some(a1)], testingA, ~message="testingA should have correct entities")
  //
  //   let optA1 = testingA->Belt.Array.getUnsafe(0)
  //   Assert.deep_equal(optA1, Some(a1), ~message="Incorrect entity loaded")
  //
  //   // TODO/NOTE: I want to re-work these linked entity loader functions to just have the values, rather than needing to call a function. Unfortunately challenging due to dynamic naturue.
  //   let b1 = handlerContext.a.getB(a1)
  //
  //   Assert.equal(b1.id, a1.b_id, ~message="b1.id should equal testingA.b_id")
  //
  //   let c1 = handlerContext.b.getC(b1)
  //
  //   Assert.equal(c1->Belt.Option.map(c => c.id), b1.c_id, ~message="c1.id should equal b1.c_id")
  //
  //   let resultAWontLoad = inMemoryStore.a->IO.InMemoryStore.A.get("aWontLoad")
  //   Assert.equal(resultAWontLoad, None, ~message="aWontLoad should not be in the store")
  //
  //   let resultBWontLoad = inMemoryStore.b->IO.InMemoryStore.B.get("bWontLoad")
  //   Assert.equal(resultBWontLoad, None, ~message="bWontLoad should not be in the store")
  // })
})

describe("Async linked entity loaders", () => {
  Promise.it("should update the big int to be the same ", async () => {
    // Initializing values for mock db
    let messageFromC = "Hi there I was in C originally"
    // mockDbInitial->Testhelpers.MockDb.
    let c: Types.c = {
      id: "hasStringToCopy",
      stringThatIsMirroredToA: messageFromC,
      a_id: "",
    }
    let b: Types.b = {
      id: "hasC",
      c_id: Some(c.id),
    }
    let a: Types.a = {
      id: EventHandlers.aIdWithGrandChildC,
      b_id: b.id,
      optionalStringToTestLinkedEntities: None,
    }
    let bNoC: Types.b = {
      id: "noC",
      c_id: None,
    }
    let aNoGrandchild: Types.a = {
      id: EventHandlers.aIdWithNoGrandChildC,
      b_id: bNoC.id,
      optionalStringToTestLinkedEntities: None,
    }
    // Initializing the mock database
    let mockDbInitial = TestHelpers.MockDb.createMockDb().entities.a.set(a).entities.a.set(
      aNoGrandchild,
    ).entities.b.set(b).entities.b.set(bNoC).entities.c.set(c)

    // Creating a mock event
    let mockNewGreetingEvent = TestHelpers.Gravatar.TestEventThatCopiesBigIntViaLinkedEntities.createMockEvent({
      param_that_should_be_removed_when_issue_1026_is_fixed: "",
    })

    // Processing the mock event on the mock database
    let updatedMockDb = await TestHelpers.Gravatar.TestEventThatCopiesBigIntViaLinkedEntities.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    })

    // Expected string copied from C
    let stringInAFromC =
      updatedMockDb.entities.a.get(EventHandlers.aIdWithGrandChildC)->Belt.Option.flatMap(
        a => a.optionalStringToTestLinkedEntities,
      )
    Assert.deep_equal(stringInAFromC, Some(messageFromC))

    // Expected string to be null still since no c grandchild.
    let optionalStringToTestLinkedEntitiesNoGrandchild =
      updatedMockDb.entities.a.get(EventHandlers.aIdWithNoGrandChildC)->Belt.Option.flatMap(
        a => a.optionalStringToTestLinkedEntities,
      )
    Js.log(optionalStringToTestLinkedEntitiesNoGrandchild)
    Assert.deep_equal(optionalStringToTestLinkedEntitiesNoGrandchild, None)
  })
})
