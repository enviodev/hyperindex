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
    (await Migrations.runDownMigrations(~shouldExit=false,~shouldDropRawEvents=true))->ignore
    (await Migrations.runUpMigrations(~shouldExit=false))->ignore
  })

  MochaPromise.after(async () => {
    (await Migrations.runDownMigrations(~shouldExit=false,~shouldDropRawEvents=true))->ignore
    (await Migrations.runUpMigrations(~shouldExit=false))->ignore
  })

  MochaPromise.it_only("Test Linked Entity Loader Scenario 1", ~timeout=5 * 1000, async () => {
    let sql = DbFunctions.sql

    let testEventData: Types.eventData = {chainId: 123, eventId: "123456"}

    // NOTE: createEventA, createEventB, createEventC are all identical. Type system being really difficult!
    let createEventA: createEntityFunction<Types.aEntity> = entity => {
      {
        dbOp: Types.Set,
        entity: entity->Types.aEntity_encode,
        eventData: testEventData,
      }
    }
    let createEventB: createEntityFunction<Types.bEntity> = entity => {
      {
        dbOp: Types.Set,
        entity: entity->Types.bEntity_encode,
        eventData: testEventData,
      }
    }
    let createEventC: createEntityFunction<Types.cEntity> = entity => {
      {
        dbOp: Types.Set,
        entity: entity->Types.cEntity_encode,
        eventData: testEventData,
      }
    }

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
      {id: "b1", a: ["a2", "a3", "a4"], c: Some("c1")},
      {id: "b2", a: [], c: Some("c2")},
      {id: "b3", a: [], c: None},
      {id: "b4", a: [], c: Some("c3")},
      {id: "bWontLoad", a: [], c: None},
    ]
    let cEntities: array<Types.cEntity> = [
      {id: "c1", a: "aWontLoad"},
      {id: "c2", a: "a5"},
      {id: "c3", a: "a6"},
      {id: "TODO_TURN_THIS_INTO_NONE", a: "aWontLoad"},
    ]

    await DbFunctions.A.batchSetA(sql, aEntities->Belt.Array.map(createEventA))
    await DbFunctions.B.batchSetB(sql, bEntities->Belt.Array.map(createEventB))
    await DbFunctions.C.batchSetC(sql, cEntities->Belt.Array.map(createEventC))

    let context = Context.GravatarContract.TestEventEvent.contextCreator(
      ~chainId=123,
      ~event=Obj.magic(),
      ~logger=Logging.logger,
    )

    let loaderContext = context.getLoaderContext()
    let idsToLoad = ["a1", "a2", "a7" /* a7 doesn't exist */]
    let _aLoader = loaderContext.a.allLoad(
      idsToLoad,
      ~loaders={loadB: {loadC: {}, loadA: {loadB: {loadC: {loadA: {}}}}}},
    )

    let entitiesToLoad = context.getEntitiesToLoad()

    await DbFunctions.sql->IO.loadEntities(entitiesToLoad)

    let handlerContext = context.getContext(~eventData=testEventData, ())
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

    Assert.equal(b1.id, a1.b, ~message="b1.id should equal testingA.b")

    let c1 = handlerContext.b.getC(b1)
    Assert.equal(c1->Belt.Option.map(c => c.id), b1.c, ~message="c1.id should equal b1.c")

    let aArray = handlerContext.b.getA(b1)

    aArray->Belt.Array.forEach(
      a => {
        let b = handlerContext.a.getB(a)

        Assert.equal(b.id, a.b, ~message="b.id should equal a.b")

        let optC = handlerContext.b.getC(b)
        Js.log("Here this test fails because 'optC' should be undefined, but since we use spice here it comes back as a field even though it isn't loaded.")
        Js.log(optC)

        Assert.equal(optC->Belt.Option.map(c => c.id), b.c, ~message="c.id should equal b.c!!")

        let _ = optC->Belt.Option.map(
          c => {
            let a = handlerContext.c.getA(c)

            Assert.equal(a.id, c.a, ~message="a.id should equal c.a")
          },
        )
      },
    )
  })

  MochaPromise.it("Test Linked Entity Loader Scenario 2", ~timeout=5 * 1000, async () => {
    let sql = DbFunctions.sql

    let testEventData: Types.eventData = {chainId: 123, eventId: "123456"}

    /// NOTE: createEventA, createEventB, createEventC are all identical. Type system being really difficult!
    let createEventA: createEntityFunction<Types.aEntity> = entity => {
      {
        dbOp: Types.Set,
        entity: entity->Types.aEntity_encode,
        eventData: testEventData,
      }
    }
    let createEventB: createEntityFunction<Types.bEntity> = entity => {
      {
        dbOp: Types.Set,
        entity: entity->Types.bEntity_encode,
        eventData: testEventData,
      }
    }
    let createEventC: createEntityFunction<Types.cEntity> = entity => {
      {
        dbOp: Types.Set,
        entity: entity->Types.cEntity_encode,
        eventData: testEventData,
      }
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
    let bEntities: array<Types.bEntity> = [
      {id: "b1", a: ["a2", "a3", "a4"], c: Some("c1")},
      {id: "bWontLoad", a: [], c: None},
    ]
    let cEntities: array<Types.cEntity> = [{id: "c1", a: "aWontLoad"}]

    await DbFunctions.A.batchSetA(sql, aEntities->Belt.Array.map(createEventA))
    await DbFunctions.B.batchSetB(sql, bEntities->Belt.Array.map(createEventB))
    await DbFunctions.C.batchSetC(sql, cEntities->Belt.Array.map(createEventC))

    let context = Context.GravatarContract.TestEventEvent.contextCreator(
      ~chainId=123,
      ~event=Obj.magic(),
      ~logger=Logging.logger,
    )

    let loaderContext = context.getLoaderContext()

    loaderContext.a.allLoad(
      ["a1"],
      ~loaders={loadB: {loadC: {}, loadA: {loadB: {loadC: {}, loadA: {loadB: {loadC: {}}}}}}},
    )

    let entitiesToLoad = context.getEntitiesToLoad()

    await DbFunctions.sql->IO.loadEntities(entitiesToLoad)

    let handlerContext = context.getContext(~eventData=testEventData, ())
    let testingA = handlerContext.a.all

    Assert.deep_equal(testingA, [Some(a1)], ~message="testingA should have correct entities")

    let optA1 = testingA->Belt.Array.getUnsafe(0)
    Assert.deep_equal(optA1, Some(a1), ~message="Incorrect entity loaded")

    // TODO/NOTE: I want to re-work these linked entity loader functions to just have the values, rather than needing to call a function. Unfortunately challenging due to dynamic naturue.
    let b1 = handlerContext.a.getB(a1)

    Assert.equal(b1.id, a1.b, ~message="b1.id should equal testingA.b")

    let c1 = handlerContext.b.getC(b1)

    Assert.equal(c1->Belt.Option.map(c => c.id), b1.c, ~message="c1.id should equal b1.c")

    let aArray = handlerContext.b.getA(b1)

    aArray->Belt.Array.forEach(
      a => {
        let b = handlerContext.a.getB(a)

        Assert.equal(b.id, a.b, ~message="b.id should equal a.b")

        aArray->Belt.Array.forEach(
          a => {
            let b = handlerContext.a.getB(a)

            Assert.equal(b.id, a.b, ~message="b.id should equal a.b")
          },
        )
      },
    )

    let resultAWontLoad = IO.InMemoryStore.A.getA(~id="aWontLoad")
    Assert.equal(resultAWontLoad, None, ~message="aWontLoad should not be in the store")

    let resultBWontLoad = IO.InMemoryStore.B.getB(~id="bWontLoad")
    Assert.equal(resultBWontLoad, None, ~message="bWontLoad should not be in the store")
  })
})
