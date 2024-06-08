open RescriptMocha
open Mocha
module MochaPromise = RescriptMocha.Promise
open Mocha

describe("Load and save an entity with a BigDecimal from DB", () => {
  MochaPromise.before(async () => {
    DbHelpers.runUpDownMigration()
  })

  MochaPromise.after(async () => {
    // It is probably overkill that we are running these 'after' also
    DbHelpers.runUpDownMigration()
  })

  MochaPromise.it(
    "be able to set and read entities with BigDecimal from DB",
    ~timeout=5 * 1000,
    async () => {
      let sql = DbFunctions.sql
      /// Setup DB
      let testEntity1: Types.entityWithFieldsEntity = {
        id: "testEntity",
        bigDecimal: BigDecimal.fromFloat(123.456),
      }
      let testEntity2: Types.entityWithFieldsEntity = {
        id: "testEntity2",
        bigDecimal: BigDecimal.fromFloat(654.321),
      }

      await DbFunctions.EntityWithFields.batchSet(sql, [testEntity1, testEntity2])

      let inMemoryStore = IO.InMemoryStore.make()

      let context = Context.GravatarContract.EmptyEventEvent.contextCreator(
        ~inMemoryStore,
        ~chainId=123,
        ~event={"devMsg": "This is a placeholder event", "blockNumber": 456}->Obj.magic,
        ~logger=Logging.logger,
        ~asyncGetters=EventProcessing.asyncGetters,
      )

      let loaderContext = context.getLoaderContext()

      let _ = loaderContext.entityWithFields.load(testEntity1.id)
      let _ = loaderContext.entityWithFields.load(testEntity2.id)

      let entitiesToLoad = context.getEntitiesToLoad()

      await IO.loadEntitiesToInMemStore(~inMemoryStore, ~entityBatch=entitiesToLoad)

      let handlerContext = context.getHandlerContextSync()

      switch handlerContext.entityWithFields.get(testEntity1.id) {
      | Some(entity) => Assert.equal(entity.bigDecimal.toString(), "123.456")
      | None => Assert.fail("Entity should exist")
      }
      switch handlerContext.entityWithFields.get(testEntity2.id) {
      | Some(entity) => Assert.equal(entity.bigDecimal.toString(), "654.321")
      | None => Assert.fail("Entity should exist")
      }
    },
  )
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
