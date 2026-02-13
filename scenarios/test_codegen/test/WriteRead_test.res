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
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
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

    let entityWithAllTypes: Indexer.Entities.EntityWithAllTypes.t = {
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
      timestamp: mockDate(~day=1),
      optTimestamp: Some(mockDate(~day=2)),
      // arrayOfTimestamps: [Js.Date.fromFloat(3.3), Js.Date.fromFloat(4.4)],
      // arrayOfTimestamps: [],
      json: %raw(`{"foo": ["bar"]}`),
      enumField: ADMIN,
      optEnumField: Some(ADMIN),
    }
    let entityWithAllNonArrayTypes: Indexer.Entities.EntityWithAllNonArrayTypes.t = {
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
      timestamp: mockDate(~day=1),
      optTimestamp: Some(mockDate(~day=2)),
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
      await indexerMock.query(EntityWithAllTypes),
      [entityWithAllTypes],
    )
    Assert.deepEqual(
      await indexerMock.queryHistory(EntityWithAllTypes),
      [
        Set({
          checkpointId: 1.,
          entityId: "1",
          entity: entityWithAllTypes,
        }),
      ],
    )
    Assert.deepEqual(
      await indexerMock.query(EntityWithAllNonArrayTypes),
      [entityWithAllNonArrayTypes],
    )
    Assert.deepEqual(
      await indexerMock.queryHistory(EntityWithAllNonArrayTypes),
      [
        Set({
          checkpointId: 1.,
          entityId: "1",
          entity: entityWithAllNonArrayTypes,
        }),
      ],
    )

    Assert.deepEqual(
      await indexerMock.query(EntityWith63LenghtName______________________________________one),
      [
        {
          id: "1",
        },
      ],
    )
    Assert.deepEqual(
      await indexerMock.queryHistory(EntityWith63LenghtName______________________________________one),
      [
        Set({
          checkpointId: 1.,
          entityId: "1",
          entity: {
            id: "1",
          },
        }),
      ],
    )
    Assert.deepEqual(
      await indexerMock.query(EntityWith63LenghtName______________________________________two),
      [
        {
          id: "2",
        },
      ],
    )
    Assert.deepEqual(
      await indexerMock.queryHistory(EntityWith63LenghtName______________________________________two),
      [
        Set({
          checkpointId: 1.,
          entityId: "2",
          entity: {
            id: "2",
          },
        }),
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

  Async.it("Test getWhere queries with eq and gt operators", async () => {
    let sourceMock = Mock.Source.make(~chain=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let indexerMock = await Mock.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    // Local refs to capture getWhere query results
    let whereEqOwnerTest = ref([])
    let whereEqTokenIdTest = ref([])
    let whereTokenIdGt50Test = ref([])
    let whereTokenIdGt49Test = ref([])
    let whereTokenIdLt50Test = ref([])
    let whereTokenIdLt51Test = ref([])

    let testUserId = "test-user-1"
    let testCollectionId = "test-collection-1"

    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 50,
        logIndex: 1,
        handler: async ({context}) => {
          // Set up test entities
          context.user.set({
            id: testUserId,
            address: "0x1234567890123456789012345678901234567890"->Utils.magic,
            gravatar_id: None,
            updatesCountOnUserForTesting: 0,
            accountType: USER,
          })

          context.nftCollection.set({
            id: testCollectionId,
            contractAddress: "0xabcdef0123456789abcdef0123456789abcdef01"->Utils.magic,
            name: "Test Collection",
            symbol: "TEST",
            maxSupply: BigInt.fromInt(100),
            currentSupply: 1,
          })

          context.token.set({
            id: "token-1",
            tokenId: BigInt.fromInt(50),
            collection_id: testCollectionId,
            owner_id: testUserId,
          })

          // Execute getWhere queries
          whereEqOwnerTest := (await context.token.getWhere({owner: {_eq: testUserId}}))
          whereEqTokenIdTest := (await context.token.getWhere({tokenId: {_eq: BigInt.fromInt(50)}}))
          whereTokenIdGt50Test := (await context.token.getWhere({tokenId: {_gt: BigInt.fromInt(50)}}))
          whereTokenIdGt49Test := (await context.token.getWhere({tokenId: {_gt: BigInt.fromInt(49)}}))
          whereTokenIdLt50Test := (await context.token.getWhere({tokenId: {_lt: BigInt.fromInt(50)}}))
          whereTokenIdLt51Test := (await context.token.getWhere({tokenId: {_lt: BigInt.fromInt(51)}}))
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    // Assert getWhere results
    Assert.equal(
      whereEqOwnerTest.contents->Array.length,
      1,
      ~message="should have successfully loaded values on where eq owner_id query",
    )
    Assert.equal(
      whereEqTokenIdTest.contents->Array.length,
      1,
      ~message="should have successfully loaded values on where eq tokenId query",
    )
    Assert.equal(
      whereTokenIdGt50Test.contents->Array.length,
      0,
      ~message="Shouldn't have any value with tokenId > 50",
    )
    Assert.deepEqual(
      whereEqTokenIdTest.contents,
      whereTokenIdGt49Test.contents,
      ~message="Where gt 49 and eq 50 should return the same result",
    )
    Assert.equal(
      whereTokenIdLt50Test.contents->Array.length,
      0,
      ~message="Shouldn't have any value with tokenId < 50",
    )
    Assert.deepEqual(
      whereEqTokenIdTest.contents,
      whereTokenIdLt51Test.contents,
      ~message="Where lt 51 and eq 50 should return the same result",
    )

    // Test deletion and index cleanup
    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 51,
        logIndex: 1,
        handler: async ({context}) => {
          context.token.deleteUnsafe("token-1")

          // Execute getWhere query after deletion
          whereEqOwnerTest := (await context.token.getWhere({owner: {_eq: testUserId}}))
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    Assert.equal(
      whereEqOwnerTest.contents->Array.length,
      0,
      ~message="should have removed index on deleted token",
    )
  })
})
