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

describe("BigDecimal Edge Cases", () => {
  describe("Negative number arithmetic", () => {
    it("add: -10 + 3 = -7", () => {
      let a = BigDecimal.fromInt(-10)
      let b = BigDecimal.fromInt(3)
      Assert.equal(a.plus(b).toString(), "-7")
    })

    it("minus: 3 - 10 = -7", () => {
      let a = BigDecimal.fromInt(3)
      let b = BigDecimal.fromInt(10)
      Assert.equal(a.minus(b).toString(), "-7")
    })

    it("times: -3 * -4 = 12", () => {
      let a = BigDecimal.fromInt(-3)
      let b = BigDecimal.fromInt(-4)
      Assert.equal(a.times(b).toString(), "12")
    })

    it("times: -3 * 4 = -12", () => {
      let a = BigDecimal.fromInt(-3)
      let b = BigDecimal.fromInt(4)
      Assert.equal(a.times(b).toString(), "-12")
    })

    it("div: -10 / 2 = -5", () => {
      let a = BigDecimal.fromInt(-10)
      let b = BigDecimal.fromInt(2)
      Assert.equal(a.div(b).toString(), "-5")
    })
  })

  describe("Zero arithmetic", () => {
    it("add: 0 + 0 = 0", () => {
      let zero = BigDecimal.zero
      Assert.equal(zero.plus(zero).toString(), "0")
    })

    it("add: 0 + 5 = 5", () => {
      let zero = BigDecimal.zero
      let five = BigDecimal.fromInt(5)
      Assert.equal(zero.plus(five).toString(), "5")
    })

    it("times: 0 * 999 = 0", () => {
      let zero = BigDecimal.zero
      let big = BigDecimal.fromInt(999)
      Assert.equal(zero.times(big).toString(), "0")
    })

    it("div: 0 / 5 = 0", () => {
      let zero = BigDecimal.zero
      let five = BigDecimal.fromInt(5)
      Assert.equal(zero.div(five).toString(), "0")
    })

    it("div by zero returns Infinity", () => {
      let ten = BigDecimal.fromInt(10)
      let zero = BigDecimal.zero
      Assert.equal(ten.div(zero).toString(), "Infinity")
    })
  })

  describe("Comparison false cases", () => {
    it("gt returns false when less", () => {
      let a = BigDecimal.fromInt(1)
      let b = BigDecimal.fromInt(2)
      Assert.equal(a.gt(b), false)
    })

    it("gt returns false when equal", () => {
      let a = BigDecimal.fromInt(5)
      let b = BigDecimal.fromInt(5)
      Assert.equal(a.gt(b), false)
    })

    it("lt returns false when greater", () => {
      let a = BigDecimal.fromInt(2)
      let b = BigDecimal.fromInt(1)
      Assert.equal(a.lt(b), false)
    })

    it("lt returns false when equal", () => {
      let a = BigDecimal.fromInt(5)
      let b = BigDecimal.fromInt(5)
      Assert.equal(a.lt(b), false)
    })

    it("equals returns false for different values", () => {
      let a = BigDecimal.fromInt(1)
      let b = BigDecimal.fromInt(2)
      Assert.equal(a.isEqualTo(b), false)
    })

    it("gte returns false when less", () => {
      let a = BigDecimal.fromInt(1)
      let b = BigDecimal.fromInt(2)
      Assert.equal(a.gte(b), false)
    })

    it("lte returns false when greater", () => {
      let a = BigDecimal.fromInt(2)
      let b = BigDecimal.fromInt(1)
      Assert.equal(a.lte(b), false)
    })
  })

  describe("Negative number comparisons", () => {
    it("negative lt zero", () => {
      let neg = BigDecimal.fromInt(-5)
      Assert.equal(neg.lt(BigDecimal.zero), true)
    })

    it("negative lt positive", () => {
      let neg = BigDecimal.fromInt(-5)
      let pos = BigDecimal.fromInt(5)
      Assert.equal(neg.lt(pos), true)
    })

    it("larger negative gt smaller negative", () => {
      let a = BigDecimal.fromInt(-1)
      let b = BigDecimal.fromInt(-10)
      Assert.equal(a.gt(b), true)
    })
  })

  describe("Large number precision", () => {
    it("preserves precision for large decimal strings", () => {
      let a = BigDecimal.fromStringUnsafe("123456789012345678.987654321")
      let b = BigDecimal.fromStringUnsafe("0.000000001")
      let result = a.plus(b)
      Assert.equal(result.toString(), "123456789012345678.987654322")
    })

    it("large number multiplication preserves all digits", () => {
      let a = BigDecimal.fromStringUnsafe("123456789012345678")
      let b = BigDecimal.fromInt(2)
      Assert.equal(a.times(b).toString(), "246913578024691356")
    })
  })

  describe("Constructors and conversions", () => {
    it("fromInt creates correct value", () => {
      Assert.equal(BigDecimal.fromInt(42).toString(), "42")
    })

    it("fromFloat creates correct value", () => {
      Assert.equal(BigDecimal.fromFloat(3.14).toString(), "3.14")
    })

    it("fromStringUnsafe creates correct value", () => {
      Assert.equal(BigDecimal.fromStringUnsafe("123.456").toString(), "123.456")
    })

    it("zero and one constants", () => {
      Assert.equal(BigDecimal.zero.toString(), "0")
      Assert.equal(BigDecimal.one.toString(), "1")
    })

    it("toFixed rounds to specified decimal places", () => {
      let a = BigDecimal.fromStringUnsafe("123.456789")
      Assert.equal(a->BigDecimal.toFixed, "123.456789")
    })

    it("decimalPlaces truncates to specified precision", () => {
      let a = BigDecimal.fromStringUnsafe("123.456789")
      Assert.equal(a->BigDecimal.decimalPlaces(2)->BigDecimal.toString, "123.46")
    })
  })

  describe("Equality across constructors", () => {
    it("fromInt and fromFloat produce equal values for integers", () => {
      let a = BigDecimal.fromInt(42)
      let b = BigDecimal.fromFloat(42.0)
      Assert.equal(a.isEqualTo(b), true)
    })

    it("fromInt and fromStringUnsafe produce equal values", () => {
      let a = BigDecimal.fromInt(42)
      let b = BigDecimal.fromStringUnsafe("42")
      Assert.equal(a.isEqualTo(b), true)
    })

    it("values with trailing zeros are equal", () => {
      let a = BigDecimal.fromStringUnsafe("1.0")
      let b = BigDecimal.fromStringUnsafe("1.00")
      Assert.equal(a.isEqualTo(b), true)
    })
  })
})
