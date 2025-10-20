open RescriptMocha

@send external padStart: (string, ~padCount: int, ~padChar: string) => string = "padStart"

let mockDate = (~year=2024, ~month=1, ~day=1) => {
  let padInt = i => i->Belt.Int.toString->padStart(~padCount=2, ~padChar="0")
  Js.Date.fromString(`${year->padInt}-${month->padInt}-${day->padInt}T00:00:00Z`)
}

describe("Write/read tests", () => {
  Async.it("Test writing and reading entities with special cases", async () => {
    let sourceMock = Mock.Source.make(~chain=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let indexerMock = await Mock.Indexer.make(
      ~chains=[{chain: #1337, sources: [sourceMock.source]}],
      ~saveFullHistory=true,
      ~enableHasura=true,
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

          // Test that for entities of max length, we can correctly save history (envio_history_<entityName>) is truncated correctly.
          context.entityWith63LenghtName______________________________________one.set({
            id: "1",
          })
          context.entityWith63LenghtName______________________________________two.set({
            id: "2",
          })
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

    Assert.deepEqual(
      await indexerMock.query(
        module(Entities.EntityWith63LenghtName______________________________________one),
      ),
      [
        {
          id: "1",
        },
      ],
    )
    Assert.deepEqual(
      await indexerMock.queryHistory(
        module(Entities.EntityWith63LenghtName______________________________________one),
      ),
      [
        {
          checkpointId: 1,
          entityId: "1",
          entityUpdateAction: Set({
            id: "1",
          }),
        },
      ],
    )
    Assert.deepEqual(
      await indexerMock.query(
        module(Entities.EntityWith63LenghtName______________________________________two),
      ),
      [
        {
          id: "2",
        },
      ],
    )
    Assert.deepEqual(
      await indexerMock.queryHistory(
        module(Entities.EntityWith63LenghtName______________________________________two),
      ),
      [
        {
          checkpointId: 1,
          entityId: "2",
          entityUpdateAction: Set({
            id: "2",
          }),
        },
      ],
    )

    Assert.deepEqual(
      await indexerMock.graphql(`query {
  EntityWithAllTypes {
    arrayOfBigInts
    arrayOfBigDecimals
  }
}`),
      {
        data: {
          "EntityWithAllTypes": [
            {
              "arrayOfBigInts": ["3", "4"],
              "arrayOfBigDecimals": ["3.3", "4.4"],
            },
          ],
        },
      },
      ~message=`We internally turn NUMERIC[] to TEXT[] when Hasura is enabled,
to workaround a bug, when the values returned as number[] instead of string[],
breaking precicion on big values. https://github.com/enviodev/hyperindex/issues/788`,
    )
  })
})
