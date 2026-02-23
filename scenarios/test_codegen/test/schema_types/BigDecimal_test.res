open Vitest

describe("Load and save an entity with a BigDecimal from DB", () => {
  Async.beforeAll(() => {
    DbHelpers.runUpDownMigration()
  })

  Async.afterAll(() => {
    // It is probably overkill that we are running these 'after' also
    DbHelpers.runUpDownMigration()
  })

  Async.it("be able to set and read entities with BigDecimal from DB", async t => {

    let sql = PgStorage.makeClient()
    /// Setup DB
    let testEntity1: Indexer.Entities.EntityWithBigDecimal.t = {
      id: "testEntity",
      bigDecimal: BigDecimal.fromFloat(123.456),
    }
    let testEntity2: Indexer.Entities.EntityWithBigDecimal.t = {
      id: "testEntity2",
      bigDecimal: BigDecimal.fromFloat(654.321),
    }

    let entityConfig = Mock.entityConfig(EntityWithBigDecimal)
    await sql->PgStorage.setOrThrow(
      ~items=[
        testEntity1->(Utils.magic: Indexer.Entities.EntityWithBigDecimal.t => Internal.entity),
        testEntity2->(Utils.magic: Indexer.Entities.EntityWithBigDecimal.t => Internal.entity),
      ],
      ~table=entityConfig.table,
      ~itemSchema=entityConfig.schema,
      ~pgSchema=Indexer.Generated.storagePgSchema,
    )

    let inMemoryStore = InMemoryStore.make(~entities=Indexer.Generated.allEntities)
    let loadManager = LoadManager.make()

    let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

    let chains = Js.Dict.empty()
    chains->Js.Dict.set("1", {id: 1, Internal.isLive: false})

    let handlerContext = UserContext.getHandlerContext({
      item,
      loadManager,
      persistence: Indexer.Generated.codegenPersistence,
      inMemoryStore,
      shouldSaveHistory: false,
      isPreload: false,
      checkpointId: 0.,
      chains,
      isResolved: false,
      config: Indexer.Generated.configWithoutRegistrations,
    })->(Utils.magic: Internal.handlerContext => Indexer.handlerContext)

    let _ = handlerContext.entityWithBigDecimal.get(testEntity1.id)
    let _ = handlerContext.entityWithBigDecimal.get(testEntity2.id)

    switch await handlerContext.entityWithBigDecimal.get(testEntity1.id) {
    | Some(entity) => t.expect(entity.bigDecimal.toString()).toBe("123.456")
    | None => panic("testEntity1 should exist")
    }
    switch await handlerContext.entityWithBigDecimal.get(testEntity2.id) {
    | Some(entity) => t.expect(entity.bigDecimal.toString()).toBe("654.321")
    | None => panic("testEntity2 should exist")
    }
  })
})

describe("BigDecimal Operations", () => {
  it("BigDecimal add 123.456 + 654.123 = 777.579", t => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromStringUnsafe("654.123")

    let c = a.plus(b)

    t.expect(c.toString()).toBe("777.579")
  })

  it("minus: 654.321 - 123.123 = 531.198", t => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromStringUnsafe("123.123")

    let result = a.minus(b)

    t.expect(result.toString()).toBe("531.198")
  })

  it("times: 123.456 * 2 = 246.912", t => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromInt(2)

    let result = a.times(b)

    t.expect(result.toString()).toBe("246.912")
  })

  it("div: 246.912 / 2 = 123.456", t => {
    let a = BigDecimal.fromFloat(246.912)
    let b = BigDecimal.fromInt(2)

    let result = a.div(b)

    t.expect(result.toString()).toBe("123.456")
  })

  it("equals: 123.456 == 123.456", t => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(123.456)

    let result = a.isEqualTo(b)

    t.expect(result).toBe(true)
  })

  it("gt: 654.321 > 123.456", t => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromFloat(123.456)

    let result = a.gt(b)

    t.expect(result).toBe(true)
  })

  it("gte: 654.321 >= 654.321", t => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromFloat(654.321)

    let result = a.gte(b)

    t.expect(result).toBe(true)
  })

  it("lt: 123.456 < 654.321", t => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(654.321)

    let result = a.lt(b)

    t.expect(result).toBe(true)
  })

  it("lte: 123.456 <= 123.456", t => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(123.456)

    let result = a.lte(b)

    t.expect(result).toBe(true)
  })
})
