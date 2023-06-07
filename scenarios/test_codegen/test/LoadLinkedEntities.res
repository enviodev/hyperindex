open RescriptMocha
module MochaPromise = RescriptMocha.Promise
open Mocha

type createEntityFunction<'a> = 'a => Types.inMemoryStoreRow<'a>

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
    await Migrations.runDownMigrations()
    await Migrations.runUpMigrations()
  })

  MochaPromise.after(async () => {
    await Migrations.runDownMigrations()
    await Migrations.runUpMigrations()
  })

  MochaPromise.it_only("Test Linked Entity Loader Scenario 1", ~timeout=5 * 1000, async () => {
    let sql = DbFunctions.sql

    let testEventData: Types.eventData = {chainId: 123, eventId: "123456"}

    /// NOTE: createEventA, createEventB, createEventC are all identical. Type system being really difficult!
    let createEventA: createEntityFunction<Types.aEntitySerialized> = entity => {
      {
        crud: Types.Create,
        entity,
        eventData: testEventData,
      }
    }
    let createEventB: createEntityFunction<Types.bEntitySerialized> = entity => {
      {
        crud: Types.Create,
        entity,
        eventData: testEventData,
      }
    }
    let createEventC: createEntityFunction<Types.cEntitySerialized> = entity => {
      {
        crud: Types.Create,
        entity,
        eventData: testEventData,
      }
    }

    /// Setup DB
    let aEntities: array<Types.aEntitySerialized> = [
      {id: "a1", b: "b1"},
      {id: "a2", b: "b2"},
      {id: "a3", b: "b3"},
      {id: "a4", b: "b4"},
      {id: "a5", b: "bWontLoad"},
      {id: "a6", b: "bWontLoad"},
      {id: "aWontLoad", b: "bWontLoad"},
    ]
    let bEntities: array<Types.bEntitySerialized> = [
      {id: "b1", a: ["a2", "a3", "a4"], c: "c1"},
      {id: "b2", a: [], c: "c2"},
      {id: "b3", a: [], c: "TODO_TURN_THIS_INTO_NONE"},
      {id: "b4", a: [], c: "c3"},
      {id: "bWontLoad", a: [], c: "TODO_TURN_THIS_INTO_NONE"},
    ]
    // let bEntities: array<Types.bEntitySerialized> = [
    //   {id: "b1", a: ["a2", "a3", "a4"], c: Some("c1")},
    //   {id: "b2", a: [], c: Some("c2")},
    //   {id: "b3", a: [], c: Some("TODO_TURN_THIS_INTO_NONE")},
    //   {id: "b4", a: [], c: Some("c3")},
    //   {id: "bWontLoad", a: [], c: Some("TODO_TURN_THIS_INTO_NONE")},
    // ]
    let cEntities: array<Types.cEntitySerialized> = [
      {id: "c1", a: "aWontLoad"},
      {id: "c2", a: "a5"},
      {id: "c3", a: "a6"},
      {id: "TODO_TURN_THIS_INTO_NONE", a: "aWontLoad"},
    ]

    await DbFunctions.A.batchSetA(sql, aEntities->Belt.Array.map(createEventA))
    await DbFunctions.B.batchSetB(sql, bEntities->Belt.Array.map(createEventB))
    await DbFunctions.C.batchSetC(sql, cEntities->Belt.Array.map(createEventC))

    let context = Context.GravatarContract.TestEventEvent.contextCreator()

    let loaderContext = context.getLoaderContext()

    let aLoader = loaderContext.a.testingALoad(
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

    Assert.equal(c1.id, b1.c, ~message="c1.id should equal b1.c")
    // Assert.equal(c1->Belt.Option.map(c => c.id), b1.c, ~message="c1.id should equal b1.c")

    let aArray = handlerContext.b.getA(b1)

    aArray->Belt.Array.forEach(
      a => {
        let b = handlerContext.a.getB(a)

        Assert.equal(b.id, a.b, ~message="b.id should equal a.b")

        let optC = handlerContext.b.getC(b)
        Js.log(optC)

        // Assert.equal(optC->Belt.Option.map(c => c.id), b.c, ~message="c.id should equal b.c")

        // let _ = optC->Belt.Option.map(
        //   c => {
        //     let a = handlerContext.c.getA(c)

        //     Assert.equal(a.id, c.a, ~message="a.id should equal c.a")
        //   },
        // )
      },
    )
  })
})
