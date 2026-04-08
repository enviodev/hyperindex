open Vitest

@send external padStart: (string, ~padCount: int, ~padChar: string) => string = "padStart"

let mockDate = (~year=2024, ~month=1, ~day=1) => {
  let padInt = i => i->Belt.Int.toString->padStart(~padCount=2, ~padChar="0")
  Js.Date.fromString(`${year->padInt}-${month->padInt}-${day->padInt}T00:00:00Z`)
}

describe("Write/read tests", () => {
  Async.it("Test writing and reading entities with special cases", async t => {
    let sourceMock = MockIndexer.Source.make(~chain=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
      ~saveFullHistory=true,
      ~enableHasura=true,
    )
    await Utils.delay(0)

    t.expect(
      sourceMock.getHeightOrThrowCalls->Array.length,
      ~message="should have called getHeightOrThrow to get initial height",
    ).toEqual(
      1,
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
      bigInt: Utils.BigInt.fromInt(1),
      optBigInt: Some(Utils.BigInt.fromInt(2)),
      arrayOfBigInts: [Utils.BigInt.fromInt(3), Utils.BigInt.fromInt(4)],
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
      bigInt: Utils.BigInt.fromInt(1),
      optBigInt: Some(Utils.BigInt.fromInt(2)),
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
          context.\"EntityWithAllTypes".set(entityWithAllTypes)
          context.\"EntityWithAllNonArrayTypes".set(entityWithAllNonArrayTypes)

          // Test that for entities of max length, we can correctly save history (envio_history_<entityName>) is truncated correctly.
          context.\"EntityWith63LenghtName______________________________________one".set({
            id: "1",
          })
          context.\"EntityWith63LenghtName______________________________________two".set({
            id: "2",
          })
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    t.expect(
      await indexerMock.query(EntityWithAllTypes),
    ).toEqual(
      [entityWithAllTypes],
    )
    t.expect(
      await indexerMock.queryHistory(EntityWithAllTypes),
    ).toEqual(
      [
        Set({
          checkpointId: 1n,
          entityId: "1",
          entity: entityWithAllTypes,
        }),
      ],
    )
    t.expect(
      await indexerMock.query(EntityWithAllNonArrayTypes),
    ).toEqual(
      [entityWithAllNonArrayTypes],
    )
    t.expect(
      await indexerMock.queryHistory(EntityWithAllNonArrayTypes),
    ).toEqual(
      [
        Set({
          checkpointId: 1n,
          entityId: "1",
          entity: entityWithAllNonArrayTypes,
        }),
      ],
    )

    t.expect(
      await indexerMock.query(EntityWith63LenghtName______________________________________one),
    ).toEqual(
      [
        {
          id: "1",
        },
      ],
    )
    t.expect(
      await indexerMock.queryHistory(EntityWith63LenghtName______________________________________one),
    ).toEqual(
      [
        Set({
          checkpointId: 1n,
          entityId: "1",
          entity: {
            id: "1",
          },
        }),
      ],
    )
    t.expect(
      await indexerMock.query(EntityWith63LenghtName______________________________________two),
    ).toEqual(
      [
        {
          id: "2",
        },
      ],
    )
    t.expect(
      await indexerMock.queryHistory(EntityWith63LenghtName______________________________________two),
    ).toEqual(
      [
        Set({
          checkpointId: 1n,
          entityId: "2",
          entity: {
            id: "2",
          },
        }),
      ],
    )

    t.expect(
      await indexerMock.graphql(`query {
  EntityWithAllTypes {
    arrayOfBigInts
    arrayOfBigDecimals
  }
}`),
      ~message=`We internally turn NUMERIC[] to TEXT[] when Hasura is enabled,
to workaround a bug, when the values returned as number[] instead of string[],
breaking precicion on big values. https://github.com/enviodev/hyperindex/issues/788`,
    ).toEqual(
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
    )
  })

  Async.it("Test getWhere queries with eq and gt operators", async t => {
    let sourceMock = MockIndexer.Source.make(~chain=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let indexerMock = await MockIndexer.Indexer.make(
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
    let whereTokenIdGte50Test = ref([])
    let whereTokenIdGte51Test = ref([])
    let whereTokenIdLte50Test = ref([])
    let whereTokenIdLte49Test = ref([])
    let whereInOwnerTest = ref([])
    let whereInTokenIdTest = ref([])
    let whereInTokenIdNoMatchTest = ref([])
    let whereInTokenIdEmptyTest = ref([])

    let testUserId = "test-user-1"
    let testCollectionId = "test-collection-1"

    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 50,
        logIndex: 1,
        handler: async ({context}) => {
          // Set up test entities
          context.\"User".set({
            id: testUserId,
            address: "0x1234567890123456789012345678901234567890"->Utils.magic,
            gravatar_id: None,
            updatesCountOnUserForTesting: 0,
            accountType: USER,
          })

          context.\"NftCollection".set({
            id: testCollectionId,
            contractAddress: "0xabcdef0123456789abcdef0123456789abcdef01"->Utils.magic,
            name: "Test Collection",
            symbol: "TEST",
            maxSupply: Utils.BigInt.fromInt(100),
            currentSupply: 1,
          })

          context.\"Token".set({
            id: "token-1",
            tokenId: Utils.BigInt.fromInt(50),
            collection_id: testCollectionId,
            owner_id: testUserId,
          })

          context.\"Token".set({
            id: "token-2",
            tokenId: Utils.BigInt.fromInt(60),
            collection_id: testCollectionId,
            owner_id: testUserId,
          })

          // Execute getWhere queries
          whereEqOwnerTest := (await context.\"Token".getWhere({owner: {_eq: testUserId}}))
          whereEqTokenIdTest := (await context.\"Token".getWhere({tokenId: {_eq: Utils.BigInt.fromInt(50)}}))
          whereTokenIdGt50Test := (await context.\"Token".getWhere({tokenId: {_gt: Utils.BigInt.fromInt(50)}}))
          whereTokenIdGt49Test := (await context.\"Token".getWhere({tokenId: {_gt: Utils.BigInt.fromInt(49)}}))
          whereTokenIdLt50Test := (await context.\"Token".getWhere({tokenId: {_lt: Utils.BigInt.fromInt(50)}}))
          whereTokenIdLt51Test := (await context.\"Token".getWhere({tokenId: {_lt: Utils.BigInt.fromInt(51)}}))

          // Execute _gte and _lte queries
          whereTokenIdGte50Test := (await context.\"Token".getWhere({tokenId: {_gte: Utils.BigInt.fromInt(50)}}))
          whereTokenIdGte51Test := (await context.\"Token".getWhere({tokenId: {_gte: Utils.BigInt.fromInt(51)}}))
          whereTokenIdLte50Test := (await context.\"Token".getWhere({tokenId: {_lte: Utils.BigInt.fromInt(50)}}))
          whereTokenIdLte49Test := (await context.\"Token".getWhere({tokenId: {_lte: Utils.BigInt.fromInt(49)}}))

          // Execute _in queries
          whereInOwnerTest := (await context.\"Token".getWhere({owner: {_in: [testUserId, "non-existent-user"]}}))
          whereInTokenIdTest := (await context.\"Token".getWhere({tokenId: {_in: [Utils.BigInt.fromInt(50), Utils.BigInt.fromInt(60)]}}))
          whereInTokenIdNoMatchTest := (await context.\"Token".getWhere({tokenId: {_in: [Utils.BigInt.fromInt(999)]}}))
          whereInTokenIdEmptyTest := (await context.\"Token".getWhere({tokenId: {_in: []}}))
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    // Assert getWhere results
    t.expect(
      whereEqOwnerTest.contents->Array.length,
      ~message="should have successfully loaded values on where eq owner_id query",
    ).toBe(
      2,
    )
    t.expect(
      whereEqTokenIdTest.contents->Array.length,
      ~message="should have successfully loaded values on where eq tokenId query",
    ).toBe(
      1,
    )
    t.expect(
      whereTokenIdGt50Test.contents->Array.length,
      ~message="Should have one token with tokenId > 50",
    ).toBe(
      1,
    )
    t.expect(
      whereTokenIdGt49Test.contents->Array.length,
      ~message="Should have two tokens with tokenId > 49",
    ).toBe(
      2,
    )
    t.expect(
      whereTokenIdLt50Test.contents->Array.length,
      ~message="Shouldn't have any value with tokenId < 50",
    ).toBe(
      0,
    )
    t.expect(
      whereTokenIdLt51Test.contents->Array.length,
      ~message="Should have one token with tokenId < 51",
    ).toBe(
      1,
    )

    // Assert _gte results
    t.expect(
      whereTokenIdGte50Test.contents->Array.length,
      ~message="Should have two tokens with tokenId >= 50 (50 and 60)",
    ).toBe(
      2,
    )
    t.expect(
      whereTokenIdGte51Test.contents->Array.length,
      ~message="Should have one token with tokenId >= 51 (only 60)",
    ).toBe(
      1,
    )

    // Assert _lte results
    t.expect(
      whereTokenIdLte50Test.contents->Array.length,
      ~message="Should have one token with tokenId <= 50",
    ).toBe(
      1,
    )
    t.expect(
      whereTokenIdLte49Test.contents->Array.length,
      ~message="Shouldn't have any value with tokenId <= 49",
    ).toBe(
      0,
    )

    // Assert _in results
    t.expect(
      whereInOwnerTest.contents->Array.length,
      ~message="_in on owner should return both tokens owned by testUserId",
    ).toBe(
      2,
    )
    t.expect(
      whereInTokenIdTest.contents->Array.length,
      ~message="_in on tokenId with [50, 60] should return both tokens",
    ).toBe(
      2,
    )
    t.expect(
      whereInTokenIdNoMatchTest.contents->Array.length,
      ~message="_in on tokenId with [999] should return no tokens",
    ).toBe(
      0,
    )
    t.expect(
      whereInTokenIdEmptyTest.contents->Array.length,
      ~message="_in on tokenId with empty array should return no tokens",
    ).toBe(
      0,
    )

    // Test deletion and index cleanup
    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 51,
        logIndex: 1,
        handler: async ({context}) => {
          context.\"Token".deleteUnsafe("token-1")

          // Execute getWhere query after deletion
          whereEqOwnerTest := (await context.\"Token".getWhere({owner: {_eq: testUserId}}))
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    t.expect(
      whereEqOwnerTest.contents->Array.length,
      ~message="should have removed index on deleted token, leaving one token",
    ).toBe(
      1,
    )
  })
})
