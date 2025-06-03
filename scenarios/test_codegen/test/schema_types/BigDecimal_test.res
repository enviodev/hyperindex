open RescriptMocha

describe("Load and save an entity with a BigDecimal from DB", () => {
  Async.before(() => {
    DbHelpers.runUpDownMigration()
  })

  Async.after(() => {
    // It is probably overkill that we are running these 'after' also
    DbHelpers.runUpDownMigration()
  })

  Async.it("be able to set and read entities with BigDecimal from DB", async () => {
    This.timeout(5 * 1000)

    let sql = Db.sql
    /// Setup DB
    let testEntity1: Entities.EntityWithBigDecimal.t = {
      id: "testEntity",
      bigDecimal: BigDecimal.fromFloat(123.456),
    }
    let testEntity2: Entities.EntityWithBigDecimal.t = {
      id: "testEntity2",
      bigDecimal: BigDecimal.fromFloat(654.321),
    }

    await DbFunctionsEntities.batchSet(
      ~entityConfig=module(Entities.EntityWithBigDecimal)->Entities.entityModToInternal,
    )(
      sql,
      [
        testEntity1->Entities.EntityWithBigDecimal.castToInternal,
        testEntity2->Entities.EntityWithBigDecimal.castToInternal,
      ],
    )

    let inMemoryStore = InMemoryStore.make()
    let loadLayer = LoadLayer.makeWithDbConnection()

    let eventItem = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

    let loaderContext = UserContext.getLoaderContext({
      eventItem,
      loadLayer,
      inMemoryStore,
      shouldGroup: true,
    })->(Utils.magic: Internal.loaderContext => Types.loaderContext)

    let _ = loaderContext.entityWithBigDecimal.get(testEntity1.id)
    let _ = loaderContext.entityWithBigDecimal.get(testEntity2.id)

    let handlerContext = UserContext.getHandlerContext({
      eventItem,
      inMemoryStore,
      loadLayer,
      shouldSaveHistory: false,
      shouldGroup: false,
    })->(Utils.magic: Internal.handlerContext => Types.handlerContext)

    switch await handlerContext.entityWithBigDecimal.get(testEntity1.id) {
    | Some(entity) => Assert.equal(entity.bigDecimal.toString(), "123.456")
    | None => Assert.fail("testEntity1 should exist")
    }
    switch await handlerContext.entityWithBigDecimal.get(testEntity2.id) {
    | Some(entity) => Assert.equal(entity.bigDecimal.toString(), "654.321")
    | None => Assert.fail("testEntity2 should exist")
    }
  })
})

describe("BigDecimal Operations", () => {
  it("BigDecimal add 123.456 + 654.123 = 777.579", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromStringUnsafe("654.123")

    let c = a.plus(b)

    Assert.equal(c.toString(), "777.579")
  })

  it("minus: 654.321 - 123.123 = 531.198", () => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromStringUnsafe("123.123")

    let result = a.minus(b)

    Assert.equal(result.toString(), "531.198")
  })

  it("times: 123.456 * 2 = 246.912", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromInt(2)

    let result = a.times(b)

    Assert.equal(result.toString(), "246.912")
  })

  it("div: 246.912 / 2 = 123.456", () => {
    let a = BigDecimal.fromFloat(246.912)
    let b = BigDecimal.fromInt(2)

    let result = a.div(b)

    Assert.equal(result.toString(), "123.456")
  })

  it("equals: 123.456 == 123.456", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(123.456)

    let result = a.isEqualTo(b)

    Assert.equal(result, true)
  })

  it("gt: 654.321 > 123.456", () => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromFloat(123.456)

    let result = a.gt(b)

    Assert.equal(result, true)
  })

  it("gte: 654.321 >= 654.321", () => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromFloat(654.321)

    let result = a.gte(b)

    Assert.equal(result, true)
  })

  it("lt: 123.456 < 654.321", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(654.321)

    let result = a.lt(b)

    Assert.equal(result, true)
  })

  it("lte: 123.456 <= 123.456", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(123.456)

    let result = a.lte(b)

    Assert.equal(result, true)
  })
})
