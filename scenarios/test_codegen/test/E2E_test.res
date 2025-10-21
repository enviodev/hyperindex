open Belt
open RescriptMocha

// A workaround for ReScript v11 issue, where it makes the field optional
// instead of setting a value to undefined. It's fixed in v12.
let undefined = (%raw(`undefined`): option<'a>)

describe("E2E tests", () => {
  Async.it("Currectly starts indexing from a non-zero start block", async () => {
    let sourceMock = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let _indexerMock = await Mock.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sources: [sourceMock.source],
          startBlock: 100,
        },
      ],
    )
    await Utils.delay(0)

    Assert.deepEqual(
      sourceMock.getHeightOrThrowCalls->Array.length,
      1,
      ~message="should have called getHeightOrThrow to get initial height",
    )
    sourceMock.resolveGetHeightOrThrow(400)
    await Utils.delay(0)
    await Utils.delay(0)

    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls,
      [{"fromBlock": 100, "toBlock": Some(200), "retry": 0}],
      ~message="Should request items from start block to reorg threshold",
    )
  })

  Async.it("Correctly sets Prom metrics", async () => {
    let sourceMock = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await Mock.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sources: [sourceMock.source],
        },
      ],
    )
    await Utils.delay(0)

    Assert.deepEqual(
      await indexerMock.metric("envio_reorg_threshold"),
      [{value: "0", labels: Js.Dict.empty()}],
    )
    Assert.deepEqual(
      await indexerMock.metric("hyperindex_synced_to_head"),
      [{value: "0", labels: Js.Dict.empty()}],
    )

    await Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock)

    Assert.deepEqual(
      await indexerMock.metric("envio_reorg_threshold"),
      [{value: "1", labels: Js.Dict.empty()}],
    )
    Assert.deepEqual(
      await indexerMock.metric("hyperindex_synced_to_head"),
      [{value: "0", labels: Js.Dict.empty()}],
    )

    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await indexerMock.metric("hyperindex_synced_to_head"),
      [{value: "1", labels: Js.Dict.empty()}],
      ~message="should have set hyperindex_synced_to_head metric to 1",
    )
  })

  // A regression test for a bug introduced in 2.30.0
  Async.it("Correct event ordering for ordered multichain indexer", async () => {
    let sourceMock1337 = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let sourceMock100 = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#100,
    )
    let indexerMock = await Mock.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sources: [sourceMock1337.source],
        },
        {
          chain: #100,
          sources: [sourceMock100.source],
        },
      ],
      ~multichain=Ordered,
    )
    await Utils.delay(0)

    // Test inside of reorg threshold, so we can check the history order
    let _ = await Promise.all2((
      Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock=sourceMock1337),
      Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock=sourceMock100),
    ))

    let callCount = ref(0)
    let getCallCount = () => {
      let count = callCount.contents
      callCount := count + 1
      count
    }

    // For this test only work with a single changing entity
    // with the same id. Use call counter to see how it's different to entity history order
    let handler: Types.HandlerTypes.loader<unit, unit> = async ({context}) => {
      context.simpleEntity.set({
        id: "1",
        value: `call-${getCallCount()->Int.toString}`,
      })
    }

    sourceMock1337.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 150,
          logIndex: 2,
          handler,
        },
      ],
      ~latestFetchedBlockNumber=160,
    )
    sourceMock100.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 150,
          logIndex: 0,
          handler,
        },
        {
          blockNumber: 151,
          logIndex: 0,
          handler,
        },
      ],
      ~latestFetchedBlockNumber=160,
    )
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await Promise.all2((
        indexerMock.queryCheckpoints(),
        indexerMock.queryHistory(module(Entities.SimpleEntity)),
      )),
      (
        [
          {
            id: 2,
            chainId: 100,
            blockNumber: 150,
            blockHash: Js.Null.Null,
            eventsProcessed: 1,
          },
          {
            id: 3,
            chainId: 1337,
            blockNumber: 100,
            blockHash: Js.Null.Value("0x100"),
            eventsProcessed: 0,
          },
          {
            id: 4,
            chainId: 1337,
            blockNumber: 150,
            blockHash: Js.Null.Null,
            eventsProcessed: 1,
          },
          {
            id: 5,
            chainId: 100,
            blockNumber: 151,
            blockHash: Js.Null.Null,
            eventsProcessed: 1,
          },
          {
            id: 6,
            chainId: 100,
            blockNumber: 160,
            blockHash: Js.Null.Value("0x160"),
            eventsProcessed: 0,
          },
        ],
        [
          {
            checkpointId: 2,
            entityId: "1",
            entityUpdateAction: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-0",
            }),
          },
          {
            checkpointId: 4,
            entityId: "1",
            entityUpdateAction: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-1",
            }),
          },
          {
            checkpointId: 5,
            entityId: "1",
            entityUpdateAction: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-2",
            }),
          },
        ],
      ),
    )
  })

  Async.it("Tracks effect calls and can resume cache count on restart", async () => {
    let sourceMock = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await Mock.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sources: [sourceMock.source],
        },
      ],
    )
    await Utils.delay(0)

    let testEffectWithCache = Envio.experimental_createEffect(
      {
        name: "testEffectWithCache",
        input: S.string,
        output: S.string,
        cache: true,
      },
      async ({input}) => {
        input ++ "-output"
      },
    )
    let testEffect = Envio.experimental_createEffect(
      {
        name: "testEffect",
        input: S.string,
        output: S.string,
      },
      async ({input}) => {
        input ++ "-output"
      },
    )

    Assert.deepEqual(
      await indexerMock.metric("envio_effect_calls_count"),
      [],
      ~message="should have no effect calls in the beginning",
    )
    Assert.deepEqual(
      await indexerMock.metric("envio_effect_cache_count"),
      [],
      ~message="should have no effect cache in the beginning",
    )

    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 100,
        logIndex: 0,
        handler: async ({context}) => {
          Assert.deepEqual(await context.effect(testEffect, "test"), "test-output")
          Assert.deepEqual(await context.effect(testEffectWithCache, "test"), "test-output")
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await indexerMock.metric("envio_effect_calls_count"),
      [
        {
          value: "1",
          labels: Js.Dict.fromArray([("effect", "testEffect")]),
        },
        {
          value: "1",
          labels: Js.Dict.fromArray([("effect", "testEffectWithCache")]),
        },
      ],
      ~message="should increment effect calls count",
    )
    Assert.deepEqual(
      await indexerMock.metric("envio_effect_cache_count"),
      [
        {
          value: "1",
          labels: Js.Dict.fromArray([("effect", "testEffectWithCache")]),
        },
      ],
      ~message="should increment effect cache count",
    )
    Assert.deepEqual(
      await indexerMock.queryEffectCache("testEffectWithCache"),
      [{"id": `"test"`, "output": %raw(`"test-output"`)}],
      ~message="should have the cache entry in db",
    )

    let indexerMock = await indexerMock.restart()
    Assert.deepEqual(
      await indexerMock.metric("envio_effect_cache_count"),
      [
        {
          value: "1",
          labels: Js.Dict.fromArray([("effect", "testEffectWithCache")]),
        },
      ],
      ~message="should resume effect cache count on restart",
    )
  })
})
