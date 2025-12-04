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
    let handler = async (
      {context}: Internal.genericHandlerArgs<Types.eventLog<unknown>, Types.handlerContext>,
    ) => {
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
            id: 2.,
            chainId: 100,
            blockNumber: 150,
            blockHash: Js.Null.Null,
            eventsProcessed: 1,
          },
          {
            id: 3.,
            chainId: 1337,
            blockNumber: 100,
            blockHash: Js.Null.Value("0x100"),
            eventsProcessed: 0,
          },
          {
            id: 4.,
            chainId: 1337,
            blockNumber: 150,
            blockHash: Js.Null.Null,
            eventsProcessed: 1,
          },
          {
            id: 5.,
            chainId: 100,
            blockNumber: 151,
            blockHash: Js.Null.Null,
            eventsProcessed: 1,
          },
          {
            id: 6.,
            chainId: 100,
            blockNumber: 160,
            blockHash: Js.Null.Value("0x160"),
            eventsProcessed: 0,
          },
        ],
        [
          Set({
            checkpointId: 2.,
            entityId: "1",
            entity: {
              Entities.SimpleEntity.id: "1",
              value: "call-0",
            },
          }),
          Set({
            checkpointId: 4.,
            entityId: "1",
            entity: {
              Entities.SimpleEntity.id: "1",
              value: "call-1",
            },
          }),
          Set({
            checkpointId: 5.,
            entityId: "1",
            entity: {
              Entities.SimpleEntity.id: "1",
              value: "call-2",
            },
          }),
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

    let testEffectWithCache = Envio.createEffect(
      {
        name: "testEffectWithCache",
        input: S.string,
        output: S.string,
        rateLimit: Disable,
        cache: true,
      },
      async ({input}) => {
        input ++ "-output"
      },
    )
    let testEffect = Envio.createEffect(
      {
        name: "testEffect",
        input: S.string,
        output: S.string,
        rateLimit: Disable,
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
      await indexerMock.metric("envio_effect_calls_count"),
      [],
      ~message="Should reset the calls metric on restart",
    )
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
            value: "1",
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

    let testEffectWithCacheV2 = Envio.createEffect(
      {
        name: "testEffectWithCache",
        input: S.string,
        output: S.string->S.refine(
          s => v =>
            if !(v->Js.String2.includes("2")) {
              s.fail(`Expected to include '2', got ${v}`)
            },
        ),
        rateLimit: Disable,
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

  Async.it("Effect rate limiting across multiple windows", async () => {
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

    let queueMetricDuringExecution = ref(None)
    let activeMetricDuringExecution = ref(None)

    let testEffectMultiWindow = Envio.createEffect(
      {
        name: "testEffectMultiWindow",
        input: S.string,
        output: S.string,
        rateLimit: Enable({calls: 2, per: Milliseconds(15)}),
      },
      async ({input}) => {
        // Add delay to ensure effects take time (longer than metric check delay)
        await Utils.delay(10)
        input ++ "-output"
      },
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
            // Call effect 6 times - should span 3 windows (2+2+2)
            let resultsPromise = Promise.all([
              context.effect(testEffectMultiWindow, "1"),
              context.effect(testEffectMultiWindow, "2"),
              context.effect(testEffectMultiWindow, "3"),
              context.effect(testEffectMultiWindow, "4"),
              context.effect(testEffectMultiWindow, "5"),
              context.effect(testEffectMultiWindow, "6"),
            ])

            // Check metrics while effects are executing
            await Utils.delay(3)
            let (queueMetric, activeMetric) = await Promise.all2((
              indexerMock.metric("envio_effect_queue_count"),
              indexerMock.metric("envio_effect_active_calls_count"),
            ))
            queueMetricDuringExecution := Some(queueMetric)
            activeMetricDuringExecution := Some(activeMetric)

            let results = await resultsPromise
            Assert.deepEqual(
              results,
              ["1-output", "2-output", "3-output", "4-output", "5-output", "6-output"],
            )
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )

    await indexerMock.getBatchWritePromise()

    // All effects should complete successfully - verify via calls count metric
    Assert.deepEqual(
      await indexerMock.metric("envio_effect_calls_count"),
      [{value: "6", labels: Js.Dict.fromArray([("effect", "testEffectMultiWindow")])}],
      ~message="should have called effect 6 times total",
    )

    // Check that we captured metrics during execution
    // With 2 calls per window and 6 total calls: 4 items queued, max 2 active
    Assert.deepEqual(
      queueMetricDuringExecution.contents->Option.getExn,
      [{value: "4", labels: Js.Dict.fromArray([("effect", "testEffectMultiWindow")])}],
      ~message="queue should have 4 items during execution",
    )
    Assert.deepEqual(
      activeMetricDuringExecution.contents->Option.getExn,
      [{value: "2", labels: Js.Dict.fromArray([("effect", "testEffectMultiWindow")])}],
      ~message="active calls should be at rate limit (2)",
    )

    // Final check - queue should be empty
    Assert.deepEqual(
      await indexerMock.metric("envio_effect_queue_count"),
      [{value: "0", labels: Js.Dict.fromArray([("effect", "testEffectMultiWindow")])}],
      ~message="queue should be empty after all windows complete",
    )
  })

  Async.it("Effect rate limiting with single call per window", async () => {
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

    let executionOrder = []
    let queueMetricDuringExecution = ref(None)
    let activeMetricDuringExecution = ref(None)
    let queueMetricAfterFirstWindow = ref(None)

    let testEffectNested = Envio.createEffect(
      {
        name: "testEffectNested",
        input: S.string,
        output: S.string,
        rateLimit: Enable({calls: 1, per: Milliseconds(15)}),
      },
      async ({input}) => {
        executionOrder->Array.push(input)->ignore
        // Add delay to ensure effects take time (longer than metric check delay)
        await Utils.delay(10)
        input ++ "-output"
      },
    )

    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    // Single batch with 4 calls that will be rate limited
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 100,
          logIndex: 0,
          handler: async ({context}) => {
            let resultsPromise = Promise.all([
              context.effect(testEffectNested, "call-1"),
              context.effect(testEffectNested, "call-2"),
              context.effect(testEffectNested, "call-3"),
              context.effect(testEffectNested, "call-4"),
            ])

            // Check metrics while effects are executing (shortly after trigger)
            await Utils.delay(3)
            let (queueMetric1, activeMetric1) = await Promise.all2((
              indexerMock.metric("envio_effect_queue_count"),
              indexerMock.metric("envio_effect_active_calls_count"),
            ))
            queueMetricDuringExecution := Some(queueMetric1)
            activeMetricDuringExecution := Some(activeMetric1)

            // Check again after first window should complete
            await Utils.delay(14)
            queueMetricAfterFirstWindow :=
              Some(await indexerMock.metric("envio_effect_queue_count"))

            let _ = await resultsPromise
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )

    await indexerMock.getBatchWritePromise()

    // All 4 effects should complete successfully despite rate limiting
    Assert.deepEqual(executionOrder->Array.length, 4, ~message="should have executed all 4 calls")

    // Verify via calls count metric
    Assert.deepEqual(
      await indexerMock.metric("envio_effect_calls_count"),
      [{value: "4", labels: Js.Dict.fromArray([("effect", "testEffectNested")])}],
      ~message="should have called effect 4 times total",
    )

    // Check that we captured metrics during execution
    // With 1 call per window and 4 total calls: 3 items queued, max 1 active
    Assert.deepEqual(
      queueMetricDuringExecution.contents->Option.getExn,
      [{value: "3", labels: Js.Dict.fromArray([("effect", "testEffectNested")])}],
      ~message="queue should have 3 items during execution",
    )
    Assert.deepEqual(
      activeMetricDuringExecution.contents->Option.getExn,
      [{value: "1", labels: Js.Dict.fromArray([("effect", "testEffectNested")])}],
      ~message="active calls should be at rate limit (1)",
    )

    // Check metrics after first window
    let queueMetric2 = queueMetricAfterFirstWindow.contents->Option.getExn
    let queueValue2 =
      queueMetric2->Array.get(0)->Option.map(m => m.value)->Option.getWithDefault("0")
    Assert.ok(
      queueValue2 != "0" || executionOrder->Array.length == 4,
      ~message=`queue should have items or all should be done, queue: ${queueValue2}, executed: ${executionOrder
        ->Array.length
        ->Int.toString}`,
    )

    // Final check - queue should be empty
    Assert.deepEqual(
      await indexerMock.metric("envio_effect_queue_count"),
      [{value: "0", labels: Js.Dict.fromArray([("effect", "testEffectNested")])}],
      ~message="queue should be empty after all batches complete",
    )
  })

  Async.it("Effect cache can be disabled per-call via context.cache", async () => {
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

    let callCount = ref(0)
    let testEffectWithCacheControl = Envio.createEffect(
      {
        name: "testEffectWithCacheControl",
        input: S.string,
        output: S.string,
        rateLimit: Disable,
        cache: true,
      },
      async ({input, context}) => {
        callCount := callCount.contents + 1
        if input === "test1" {
          context.cache = false
        }
        input ++ "-output"
      },
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
            // Call 1: Disable cache persistence for this specific call
            Assert.deepEqual(
              await context.effect(testEffectWithCacheControl, "test1"),
              "test1-output",
            )

            // Call 2: Same input as call 1, uses in-memory cache from call 1
            // Shouldn't do anything, since memoization
            Assert.deepEqual(
              await context.effect(testEffectWithCacheControl, "test1"),
              "test1-output",
            )

            // Call 3: Different input with default cache behavior (should cache in memory and DB)
            Assert.deepEqual(
              await context.effect(testEffectWithCacheControl, "test2"),
              "test2-output",
            )
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      callCount.contents,
      2,
      ~message="Effect should be called 2 times (test1 once with cache=false, test2 once)",
    )

    Assert.deepEqual(
      await indexerMock.queryEffectCache("testEffectWithCacheControl"),
      [{"id": `"test2"`, "output": %raw(`"test2-output"`)}],
      ~message="Should only have test2 in DB (test1 was called with cache=false and subsequent calls used in-memory cache)",
    )
  })

  Async.it("Effect error in one call shouldn't cause other calls to fail", async () => {
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

    let throwingEffect = Envio.createEffect(
      {
        name: "throwingEffect",
        input: S.string,
        output: S.string,
        rateLimit: Disable,
        cache: true,
      },
      async ({input}) => {
        if input->Js.String2.includes("should-fail") {
          Utils.Error.make("Effect intentionally failed")->raise
        }
        input ++ "-output"
      },
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
            let p1 = context.effect(throwingEffect, "should-fail")
            let p2 = context.effect(throwingEffect, "shouldn't-fail")

            // Verify p1 throws with correct error message
            try {
              let _ = await p1
              Assert.fail("p1 should have thrown an error")
            } catch {
            | exn =>
              Assert.deepEqual(
                (exn->Utils.prettifyExn->Utils.magic)["message"],
                "Effect intentionally failed",
                ~message="p1 should throw with correct error message",
              )
            }

            // p2 should succeed (bug: currently fails when p1 throws)
            Assert.deepEqual(await p2, "shouldn't-fail-output", ~message="p2 should succeed")
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )
    await indexerMock.getBatchWritePromise()

    // Verify that only p2's successful result was cached
    Assert.deepEqual(
      await indexerMock.queryEffectCache("throwingEffect"),
      [{"id": `"shouldn't-fail"`, "output": %raw(`"shouldn't-fail-output"`)}],
      ~message="Should only cache p2's successful result, not p1's failed call",
    )
  })

  Async.it(
    "Live source should not participate in initial height fetch but should after sync",
    async () => {
      // Create a Sync source (simulating HyperSync) and a Live source (simulating RPC for live)
      let syncSource = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
        ~sourceFor=Source.Sync,
      )
      let liveSource = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
        ~sourceFor=Source.Live,
      )

      let indexerMock = await Mock.Indexer.make(
        ~chains=[
          {
            chain: #1337,
            sources: [syncSource.source, liveSource.source],
          },
        ],
      )
      await Utils.delay(0)

      // During initial height fetch (currentBlockHeight === 0),
      // only the Sync source should be queried, not the Live source.
      // This is important to allow HyperSync's smart block detection to work.
      Assert.deepEqual(
        syncSource.getHeightOrThrowCalls->Array.length,
        1,
        ~message="Sync source should be called for initial height",
      )
      Assert.deepEqual(
        liveSource.getHeightOrThrowCalls->Array.length,
        0,
        ~message="Live source should NOT be called during initial height fetch",
      )

      // Resolve the initial height and let the indexer start syncing
      syncSource.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // Sync source fetches items (enters reorg threshold at block 100)
      Assert.deepEqual(
        syncSource.getItemsOrThrowCalls->Array.length,
        1,
        ~message="Sync source should fetch items",
      )

      // Resolve first batch (0-100) and continue until we reach the head
      syncSource.resolveGetItemsOrThrow([])
      await indexerMock.getBatchWritePromise()

      // After entering reorg threshold, continue fetching until we reach head (300)
      // The indexer will fetch in batches, we need to resolve each one
      syncSource.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=200)
      await indexerMock.getBatchWritePromise()

      syncSource.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexerMock.getBatchWritePromise()

      // Now the indexer should be at the head and will wait for new blocks.
      // At this point, currentBlockHeight > 0, so Live source should participate in racing.
      // Both sources should race for the next height.
      Assert.deepEqual(
        syncSource.getHeightOrThrowCalls->Array.length,
        2,
        ~message="Sync source should be called again for next height",
      )
      Assert.deepEqual(
        liveSource.getHeightOrThrowCalls->Array.length,
        1,
        ~message="Live source should now participate in height racing after initial sync",
      )
    },
  )
})
