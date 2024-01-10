open RescriptMocha
module MochaPromise = RescriptMocha.Promise
open Mocha

type createEntityFunction<'a> = 'a => Types.inMemoryStoreRow<Js.Json.t>

@@warning("-21")
let resetPostgresClient: unit => unit = () => {
  // This is a hack to reset the postgres client between tests. postgres.js seems to cache some types, and if tests clear the DB you need to also reset sql.

  %raw(
    "require('../generated/src/DbFunctions.bs.js').sql = require('postgres')(require('../generated/src/Config.bs.js').db)"
  )
}

/// NOTE: diagrams for these tests can be found here: https://www.figma.com/file/TrBPqQHYoJ8wg6e0kAynZo/Scenarios-to-test-Linked-Entities?type=whiteboard&node-id=0%3A1&t=CZAE4T4oY9PCbszw-1
describe("Linked Entity Loader Integration Test", () => {
  MochaPromise.before(async () => {
    resetPostgresClient()
    (await Migrations.runDownMigrations(~shouldExit=false, ~shouldDropRawEvents=true))->ignore
    (await Migrations.runUpMigrations(~shouldExit=false))->ignore
  })

  MochaPromise.after(async () => {
    (await Migrations.runDownMigrations(~shouldExit=false, ~shouldDropRawEvents=true))->ignore
    (await Migrations.runUpMigrations(~shouldExit=false))->ignore
  })

  MochaPromise.it("Test Linked Entity Loader Scenario 1", ~timeout=5 * 1000, async () => {
    let sql = DbFunctions.sql
    /// Setup DB
    let a1: Types.aEntity = {optionalBigInt: None, id: "a1", b: "b1"}
    let a2: Types.aEntity = {optionalBigInt: None, id: "a2", b: "b2"}
    let aEntities: array<Types.aEntity> = [
      a1,
      a2,
      {optionalBigInt: None, id: "a3", b: "b3"},
      {optionalBigInt: None, id: "a4", b: "b4"},
      {optionalBigInt: None, id: "a5", b: "bWontLoad"},
      {optionalBigInt: None, id: "a6", b: "bWontLoad"},
      {optionalBigInt: None, id: "aWontLoad", b: "bWontLoad"},
    ]
    let bEntities: array<Types.bEntity> = [
      {id: "b1", c: Some("c1")},
      {id: "b2", c: Some("c2")},
      {id: "b3", c: None},
      {id: "b4", c: Some("c3")},
      {id: "bWontLoad", c: None},
    ]
    let cEntities: array<Types.cEntity> = [
      {id: "c1", a: "aWontLoad"},
      {id: "c2", a: "a5"},
      {id: "c3", a: "a6"},
      {id: "TODO_TURN_THIS_INTO_NONE", a: "aWontLoad"},
    ]

    await DbFunctions.A.batchSet(sql, aEntities->Belt.Array.map(Types.aEntity_encode))
    await DbFunctions.B.batchSet(sql, bEntities->Belt.Array.map(Types.bEntity_encode))
    await DbFunctions.C.batchSet(sql, cEntities->Belt.Array.map(Types.cEntity_encode))

    let inMemoryStore = IO.InMemoryStore.make()

    let context = Context.GravatarContract.TestEventEvent.contextCreator(
      ~inMemoryStore,
      ~chainId=123,
      ~event={"devMsg": "This is a placeholder event", "blockNumber": 456}->Obj.magic,
      ~logger=Logging.logger,
      ~asyncGetters=EventProcessing.asyncGetters,
    )

    let loaderContext = context.getLoaderContext()
    let idsToLoad = ["a1", "a2", "a7" /* a7 doesn't exist */]
    let _aLoader = loaderContext.a.allLoad(idsToLoad, ~loaders={loadB: {loadC: {}}})

    let entitiesToLoad = context.getEntitiesToLoad()

    await IO.loadEntitiesToInMemStore(~inMemoryStore, ~entityBatch=entitiesToLoad)

    let handlerContext = context.getHandlerContextSync()

    let testingA = handlerContext.a.all

    Assert.deep_equal(
      testingA,
      [Some(a1), Some(a2), None],
      ~message="testingA should have correct items",
    )

    let optA1 = testingA->Belt.Array.getUnsafe(0)
    Assert.deep_equal(optA1, Some(a1), ~message="Incorrect entity loaded")

    // TODO/NOTE: I want to re-work these linked entity loader functions to just have the values, rather than needing to call a function. Unfortunately challenging due to dynamic naturue.
    let b1 = handlerContext.a.getB(a1)

    Assert.deep_equal(b1.id, a1.b, ~message="b1.id should equal testingA.b")

    let c1 = handlerContext.b.getC(b1)
    Assert.equal(c1->Belt.Option.map(c => c.id), b1.c, ~message="c1.id should equal b1.c")
  })

  MochaPromise.it("Test Linked Entity Loader Scenario 2", ~timeout=5 * 1000, async () => {
    let sql = DbFunctions.sql

    /// NOTE: createEventA, createEventB, createEventC are all identical. Type system being really difficult!
    let createEventA = entity => {
      entity->Types.aEntity_encode
    }
    let createEventB = entity => {
      entity->Types.bEntity_encode
    }
    let createEventC = entity => {
      entity->Types.cEntity_encode
    }

    /// Setup DB
    let a1: Types.aEntity = {id: "a1", b: "b1", optionalBigInt: None}
    let aEntities: array<Types.aEntity> = [
      a1,
      {id: "a2", b: "b1", optionalBigInt: None},
      {id: "a3", b: "b1", optionalBigInt: None},
      {id: "a4", b: "b1", optionalBigInt: None},
      {id: "aWontLoad", b: "bWontLoad", optionalBigInt: None},
    ]
    let bEntities: array<Types.bEntity> = [{id: "b1", c: Some("c1")}, {id: "bWontLoad", c: None}]
    let cEntities: array<Types.cEntity> = [{id: "c1", a: "aWontLoad"}]

    await DbFunctions.A.batchSet(sql, aEntities->Belt.Array.map(createEventA))
    await DbFunctions.B.batchSet(sql, bEntities->Belt.Array.map(createEventB))
    await DbFunctions.C.batchSet(sql, cEntities->Belt.Array.map(createEventC))

    let inMemoryStore = IO.InMemoryStore.make()
    let context = Context.GravatarContract.TestEventEvent.contextCreator(
      ~inMemoryStore,
      ~chainId=123,
      ~event={"devMsg": "This is a placeholder event", "blockNumber": 456}->Obj.magic,
      ~logger=Logging.logger,
      ~asyncGetters=EventProcessing.asyncGetters,
    )

    let loaderContext = context.getLoaderContext()

    loaderContext.a.allLoad(["a1"], ~loaders={loadB: {loadC: {}}})

    let entitiesToLoad = context.getEntitiesToLoad()

    await IO.loadEntitiesToInMemStore(~inMemoryStore, ~entityBatch=entitiesToLoad)

    let handlerContext = context.getHandlerContextSync()

    let testingA = handlerContext.a.all

    Assert.deep_equal([Some(a1)], testingA, ~message="testingA should have correct entities")

    let optA1 = testingA->Belt.Array.getUnsafe(0)
    Assert.deep_equal(optA1, Some(a1), ~message="Incorrect entity loaded")

    // TODO/NOTE: I want to re-work these linked entity loader functions to just have the values, rather than needing to call a function. Unfortunately challenging due to dynamic naturue.
    let b1 = handlerContext.a.getB(a1)

    Assert.equal(b1.id, a1.b, ~message="b1.id should equal testingA.b")

    let c1 = handlerContext.b.getC(b1)

    Assert.equal(c1->Belt.Option.map(c => c.id), b1.c, ~message="c1.id should equal b1.c")

    let resultAWontLoad = inMemoryStore.a->IO.InMemoryStore.A.get("aWontLoad")
    Assert.equal(resultAWontLoad, None, ~message="aWontLoad should not be in the store")

    let resultBWontLoad = inMemoryStore.b->IO.InMemoryStore.B.get("bWontLoad")
    Assert.equal(resultBWontLoad, None, ~message="bWontLoad should not be in the store")
  })
})
