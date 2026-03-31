open Vitest

describe("Load and save an entity with a BigDecimal from DB", () => {
  Async.it("be able to set and read entities with BigDecimal from DB", async t => {
    let sourceMock = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await Mock.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sourceConfig: Config.CustomSources([sourceMock.source]),
        },
      ],
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 100,
          logIndex: 0,
          handler: async ({context}) => {
            context.\"EntityWithBigDecimal".set({
              id: "testEntity",
              bigDecimal: BigDecimal.fromFloat(123.456),
            })
            context.\"EntityWithBigDecimal".set({
              id: "testEntity2",
              bigDecimal: BigDecimal.fromFloat(654.321),
            })
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )
    await indexerMock.getBatchWritePromise()

    let entities = await indexerMock.query(EntityWithBigDecimal)
    switch entities->Js.Array2.find(e => e.id === "testEntity") {
    | Some(entity) => t.expect(entity.bigDecimal.toString()).toBe("123.456")
    | None => Js.Exn.raiseError("testEntity1 should exist")
    }
    switch entities->Js.Array2.find(e => e.id === "testEntity2") {
    | Some(entity) => t.expect(entity.bigDecimal.toString()).toBe("654.321")
    | None => Js.Exn.raiseError("testEntity2 should exist")
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
