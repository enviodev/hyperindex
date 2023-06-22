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
    await Migrations.runDownMigrations(false)
    await Migrations.runUpMigrations(false)
  })

  MochaPromise.after(async () => {
    await Migrations.runDownMigrations(false)
    await Migrations.runUpMigrations(false)
  })

  MochaPromise.it("Test Linked Entity Loader Scenario 1", ~timeout=5 * 1000, async () => {
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
    let aEntities: array<Types.aEntity> = [
      {id: "a1", b: "b1"},
      {id: "a2", b: "b2"},
      {id: "a3", b: "b3"},
      {id: "a4", b: "b4"},
      {id: "a5", b: "bWontLoad"},
      {id: "a6", b: "bWontLoad"},
      {id: "aWontLoad", b: "bWontLoad"},
    ]
    let bEntities: array<Types.bEntity> = [
      {id: "b1", a: ["a2", "a3", "a4"], c: "c1"},
      {id: "b2", a: [], c: "c2"},
      {id: "b3", a: []},
      {id: "b4", a: [], c: "c3"},
      {id: "bWontLoad", a: []},
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
    )

    let loaderContext = context.getLoaderContext()

    let _aLoader = loaderContext.a.testingALoad(
      "a1",
      ~loaders={loadB: {loadC: {}, loadA: {loadB: {loadC: {loadA: {}}}}}},
    )

    let entitiesToLoad = context.getEntitiesToLoad()

    await DbFunctions.sql->IO.loadEntities(entitiesToLoad)

    let handlerContext = context.getContext(~eventData=testEventData)
    let optTestingA = handlerContext.a.testingA()

    Assert.not_equal(optTestingA, None, ~message="testingA should not be None")

    let testingA = optTestingA->Belt.Option.getExn

    let b1 = handlerContext.a.getB(testingA)

    Assert.equal(b1.id, testingA.b, ~message="b1.id should equal testingA.b")

    let c1 = handlerContext.b.getC(b1)
    Assert.equal(c1->Belt.Option.map(c => c.id), b1.c, ~message="c1.id should equal b1.c")

    let aArray = handlerContext.b.getA(b1)

    aArray->Belt.Array.forEach(
      a => {
        let b = handlerContext.a.getB(a)

        Assert.equal(b.id, a.b, ~message="b.id should equal a.b")

        let optC = handlerContext.b.getC(b)
        Assert.equal(optC->Belt.Option.map(c => c.id), b.c, ~message="c.id should equal b.c")

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
    let aEntities: array<Types.aEntity> = [
      {id: "a1", b: "b1"},
      {id: "a2", b: "b1"},
      {id: "a3", b: "b1"},
      {id: "a4", b: "b1"},
      {id: "aWontLoad", b: "bWontLoad"},
    ]
    let bEntities: array<Types.bEntity> = [
      {id: "b1", a: ["a2", "a3", "a4"], c: "c1"},
      {id: "bWontLoad", a: []},
    ]
    let cEntities: array<Types.cEntity> = [{id: "c1", a: "aWontLoad"}]

    await DbFunctions.A.batchSetA(sql, aEntities->Belt.Array.map(createEventA))
    await DbFunctions.B.batchSetB(sql, bEntities->Belt.Array.map(createEventB))
    await DbFunctions.C.batchSetC(sql, cEntities->Belt.Array.map(createEventC))

    let context = Context.GravatarContract.TestEventEvent.contextCreator(
      ~chainId=123,
      ~event=Obj.magic(),
    )

    let loaderContext = context.getLoaderContext()

    loaderContext.a.testingALoad(
      "a1",
      ~loaders={loadB: {loadC: {}, loadA: {loadB: {loadC: {}, loadA: {loadB: {loadC: {}}}}}}},
    )

    let entitiesToLoad = context.getEntitiesToLoad()

    await DbFunctions.sql->IO.loadEntities(entitiesToLoad)

    let handlerContext = context.getContext(~eventData=testEventData)
    let optTestingA = handlerContext.a.testingA()

    Assert.not_equal(optTestingA, None, ~message="testingA should not be None")

    let testingA = optTestingA->Belt.Option.getExn

    let b1 = handlerContext.a.getB(testingA)

    Assert.equal(b1.id, testingA.b, ~message="b1.id should equal testingA.b")

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
