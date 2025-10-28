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

  Async.it("Shouldn't allow context access after hander is resolved", async () => {
    let errors = []

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
    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 10,
        logIndex: 0,
        contractRegister: async ({context}) => {
          let _ = Js.Global.setTimeout(
            () => {
              try {
                context.addGravatar(
                  "0x1234567890123456789012345678901234567890"->Address.Evm.fromStringOrThrow,
                )
              } catch {
              | exn => errors->Array.push(exn->Utils.prettifyExn)
              }
            },
            0,
          )
        },
        handler: async ({context}) => {
          let _ = Js.Global.setTimeout(
            () => {
              try {
                context.simpleEntity.set({
                  id: "1",
                  value: "value-1",
                })
              } catch {
              | exn => errors->Array.push(exn->Utils.prettifyExn)
              }
            },
            1,
          )
        },
      },
      {
        blockNumber: 11,
        logIndex: 0,
        handler: async ({context}) => {
          context.simpleEntity.set({
            id: "1",
            value: "value-2",
          })
          // Wait to see what will happen when timeout finishes during the batch
          await Utils.delay(1)
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await indexerMock.query(module(Entities.SimpleEntity)),
      [{Entities.SimpleEntity.id: "1", value: "value-2"}],
    )
    Assert.deepEqual(
      errors,
      [
        Utils.Error.make(`Impossible to access context.addGravatar after the contract register is resolved. Make sure you didn't miss an await in the handler.`)->Utils.prettifyExn,
        Utils.Error.make(`Impossible to access context.SimpleEntity after the handler is resolved. Make sure you didn't miss an await in the handler.`)->Utils.prettifyExn,
      ],
      ~message="should have an error thrown during set",
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

  Async.it("Track effects in prom metrics", async () => {
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
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 100,
          logIndex: 0,
          handler: async ({context}) => {
            Assert.deepEqual(await context.effect(testEffect, "test"), "test-output")
            Assert.deepEqual(await context.effect(testEffectWithCache, "test"), "test-output")
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )
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
      await indexerMock.metric("envio_storage_load_count"),
      [],
      ~message="Shouldn't load anything from storage at this point",
    )
    Assert.deepEqual(
      await indexerMock.queryEffectCache("testEffectWithCache"),
      [{"id": `"test"`, "output": %raw(`"test-output"`)}],
      ~message="should have the cache entry in db",
    )

    let indexerMock = await indexerMock.restart()
    await Utils.delay(0)

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

    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 101,
          logIndex: 0,
          handler: async ({context}) => {
            Assert.deepEqual(
              await Promise.all2((
                context.effect(testEffectWithCache, "test"),
                context.effect(testEffectWithCache, "test-2"),
              )),
              ("test-output", "test-2-output"),
            )
          },
        },
      ],
      ~latestFetchedBlockNumber=101,
    )
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await Promise.all3((
        indexerMock.metric("envio_storage_load_where_size"),
        indexerMock.metric("envio_storage_load_size"),
        indexerMock.metric("envio_storage_load_count"),
      )),
      (
        [
          {
            value: "2",
            labels: Js.Dict.fromArray([("operation", "testEffectWithCache.effect")]),
          },
        ],
        [
          {
            value: "1",
            labels: Js.Dict.fromArray([("operation", "testEffectWithCache.effect")]),
          },
        ],
        [
          {
            value: "1",
            labels: Js.Dict.fromArray([("operation", "testEffectWithCache.effect")]),
          },
        ],
      ),
      ~message="Time to load cache from storage now",
    )
    Assert.deepEqual(
      await Promise.all2((
        indexerMock.metric("envio_effect_calls_count"),
        indexerMock.metric("envio_effect_cache_count"),
      )),
      (
        [
          {
            // It resumes in-memory during test, but it'll reset on process restart
            // In the real-world it'll be 1
            value: "2",
            labels: Js.Dict.fromArray([("effect", "testEffectWithCache")]),
          },
        ],
        [
          {
            value: "2",
            labels: Js.Dict.fromArray([("effect", "testEffectWithCache")]),
          },
        ],
      ),
      ~message="Should increment effect calls count and cache count",
    )

    let testEffectWithCacheV2 = Envio.experimental_createEffect(
      {
        name: "testEffectWithCache",
        input: S.string,
        output: S.string->S.refine(
          s => v =>
            if !(v->Js.String2.includes("2")) {
              s.fail(`Expected to include '2', got ${v}`)
            },
        ),
        cache: true,
      },
      async ({input}) => {
        input ++ "-output-v2"
      },
    )

    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 102,
          logIndex: 0,
          handler: async ({context}) => {
            Assert.deepEqual(
              await Promise.all2((
                context.effect(testEffectWithCacheV2, "test"),
                context.effect(testEffectWithCacheV2, "test-2"),
              )),
              ("test-output-v2", "test-2-output"),
            )
          },
        },
      ],
      ~latestFetchedBlockNumber=102,
    )
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await indexerMock.queryEffectCache("testEffectWithCache"),
      [
        {"id": `"test-2"`, "output": %raw(`"test-2-output"`)},
        {"id": `"test"`, "output": %raw(`"test-output-v2"`)},
      ],
      ~message="Should invalidate loaded cache and store new one",
    )
    Assert.deepEqual(
      await indexerMock.metric("envio_effect_cache_count"),
      [
        {
          value: "2",
          labels: Js.Dict.fromArray([("effect", "testEffectWithCache")]),
        },
      ],
      ~message="Shouldn't increment on invalidation",
    )
  })

  Async.it(
    "Should attempt fallback source when primary source fails with missing params",
    async () => {
      let sourceMockPrimary = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMockFallback = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let indexerMock = await Mock.Indexer.make(
        ~chains=[
          {
            chain: #1337,
            sources: [sourceMockPrimary.source, sourceMockFallback.source],
          },
        ],
      )
      await Utils.delay(0)

      // Resolve initial height request from primary source
      Assert.deepEqual(
        sourceMockPrimary.getHeightOrThrowCalls->Array.length,
        1,
        ~message="should have called getHeightOrThrow on primary source",
      )
      sourceMockPrimary.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // Primary source should now attempt to fetch items
      Assert.deepEqual(
        sourceMockPrimary.getItemsOrThrowCalls->Array.length,
        1,
        ~message="should have called getItemsOrThrow on primary source",
      )

      // Simulate missing params error from HyperSync (converted to InvalidData by the source)
      sourceMockPrimary.rejectGetItemsOrThrow(
        Source.GetItemsError(
          FailedGettingItems({
            exn: %raw(`null`),
            attemptedToBlock: 100,
            retry: ImpossibleForTheQuery({
              message: "Source returned invalid data with missing required fields: log.address",
            }),
          }),
        ),
      )
      await Utils.delay(0)
      await Utils.delay(0)

      // The fallback source should now be called immediately
      Assert.deepEqual(
        sourceMockFallback.getItemsOrThrowCalls->Array.length,
        1,
        ~message="fallback source should be called after primary fails with invalid data",
      )

      // Resolve the fallback source successfully
      sourceMockFallback.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexerMock.getBatchWritePromise()

      Assert.deepEqual(
        (
          sourceMockPrimary.getItemsOrThrowCalls->Array.length,
          sourceMockFallback.getItemsOrThrowCalls->Array.length,
        ),
        (2, 1),
        ~message="Shouldn't switch to fallback source for the next query",
      )
    },
  )
})
