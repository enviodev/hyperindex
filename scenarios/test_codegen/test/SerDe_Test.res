open RescriptMocha

@send external padStart: (string, ~padCount: int, ~padChar: string) => string = "padStart"

let mockDate = (~year=2024, ~month=1, ~day=1) => {
  let padInt = i => i->Belt.Int.toString->padStart(~padCount=2, ~padChar="0")
  Js.Date.fromString(`${year->padInt}-${month->padInt}-${day->padInt}T00:00:00Z`)
}

describe("SerDe Test", () => {
  Async.it("All type entity", async () => {
    let sourceMock = Mock.Source.make(~chain=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let indexerMock = await Mock.Indexer.make(
      ~chains=[{chain: #1337, sources: [sourceMock.source]}],
      ~saveFullHistory=true,
    )
    await Utils.delay(0)

    Assert.deepEqual(
      sourceMock.getHeightOrThrowCalls->Array.length,
      1,
      ~message="should have called getHeightOrThrow to get initial height",
    )
    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    let entityWithAllTypes: Entities.EntityWithAllTypes.t = {
      id: "1",
      string: "string",
      optString: Some("optString"),
      arrayOfStrings: ["arrayOfStrings1", "arrayOfStrings2"],
      int_: 1,
      optInt: Some(2),
      arrayOfInts: [3, 4],
      float_: 1.1,
      optFloat: Some(2.2),
      arrayOfFloats: [3.3, 4.4],
      bool: true,
      optBool: Some(false),
      //TODO: get array of bools working
      // arrayOfBool: [true, false],
      bigInt: BigInt.fromInt(1),
      optBigInt: Some(BigInt.fromInt(2)),
      arrayOfBigInts: [BigInt.fromInt(3), BigInt.fromInt(4)],
      bigDecimal: BigDecimal.fromStringUnsafe("1.1"),
      bigDecimalWithConfig: BigDecimal.fromStringUnsafe("1.1"),
      optBigDecimal: Some(BigDecimal.fromStringUnsafe("2.2")),
      arrayOfBigDecimals: [BigDecimal.fromStringUnsafe("3.3"), BigDecimal.fromStringUnsafe("4.4")],
      //TODO: get timestamp working
      // timestamp: mockDate(~day=1),
      // optTimestamp: Some(mockDate(~day=2)),
      // arrayOfTimestamps: [Js.Date.fromFloat(3.3), Js.Date.fromFloat(4.4)],
      // arrayOfTimestamps: [],
      json: %raw(`{"foo": ["bar"]}`),
      enumField: ADMIN,
      optEnumField: Some(ADMIN),
    }
    let entityWithAllNonArrayTypes: Entities.EntityWithAllNonArrayTypes.t = {
      id: "1",
      string: "string",
      optString: Some("optString"),
      int_: 1,
      optInt: Some(2),
      float_: 1.1,
      optFloat: Some(2.2),
      bool: true,
      optBool: Some(false),
      bigInt: BigInt.fromInt(1),
      optBigInt: Some(BigInt.fromInt(2)),
      bigDecimal: BigDecimal.fromStringUnsafe("1.1"),
      optBigDecimal: Some(BigDecimal.fromStringUnsafe("2.2")),
      bigDecimalWithConfig: BigDecimal.fromStringUnsafe("1.1"),
      enumField: ADMIN,
      optEnumField: Some(ADMIN),
    }

    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 50,
        logIndex: 1,
        handler: async ({context}) => {
          context.entityWithAllTypes.set(entityWithAllTypes)
          context.entityWithAllNonArrayTypes.set(entityWithAllNonArrayTypes)
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await indexerMock.query(module(Entities.EntityWithAllTypes)),
      [entityWithAllTypes],
    )
    Assert.deepEqual(
      await indexerMock.queryHistory(module(Entities.EntityWithAllTypes)),
      [
        {
          checkpointId: 1,
          entityId: "1",
          entityUpdateAction: Set(entityWithAllTypes),
        },
      ],
    )
    Assert.deepEqual(
      await indexerMock.query(module(Entities.EntityWithAllNonArrayTypes)),
      [entityWithAllNonArrayTypes],
    )
    Assert.deepEqual(
      await indexerMock.queryHistory(module(Entities.EntityWithAllNonArrayTypes)),
      [
        {
          checkpointId: 1,
          entityId: "1",
          entityUpdateAction: Set(entityWithAllNonArrayTypes),
        },
      ],
    )
  })
})
