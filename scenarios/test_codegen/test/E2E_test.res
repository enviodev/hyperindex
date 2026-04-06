open Belt
open Vitest

// A workaround for ReScript v11 issue, where it makes the field optional
// instead of setting a value to undefined. It's fixed in v12.
let undefined = (%raw(`undefined`): option<'a>)

describe("E2E tests", () => {
  Async.it("Currectly starts indexing from a non-zero start block", async t => {
    let sourceMock = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let _indexerMock = await Mock.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sourceConfig: Config.CustomSources([sourceMock.source]),
          startBlock: 100,
        },
      ],
    )
    await Utils.delay(0)

    t.expect(
      sourceMock.getHeightOrThrowCalls->Array.length,
      ~message="should have called getHeightOrThrow to get initial height",
    ).toEqual(1)
    sourceMock.resolveGetHeightOrThrow(400)
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(call => call.payload),
      ~message="Should request items from start block to reorg threshold",
    ).toEqual([{"fromBlock": 100, "toBlock": Some(200), "retry": 0, "p": "0"}])
  })

  Async.it("Correctly sets Prom metrics", async t => {
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

    t.expect(await indexerMock.metric("envio_reorg_threshold")).toEqual([
      {value: "0", labels: Js.Dict.empty()},
    ])
    t.expect(await indexerMock.metric("hyperindex_synced_to_head")).toEqual([
      {value: "0", labels: Js.Dict.empty()},
    ])

    await Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

    t.expect(await indexerMock.metric("envio_reorg_threshold")).toEqual([
      {value: "1", labels: Js.Dict.empty()},
    ])
    t.expect(await indexerMock.metric("hyperindex_synced_to_head")).toEqual([
      {value: "0", labels: Js.Dict.empty()},
    ])

    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
    await indexerMock.getBatchWritePromise()

    t.expect(
      await indexerMock.metric("hyperindex_synced_to_head"),
      ~message="should have set hyperindex_synced_to_head metric to 1",
    ).toEqual([{value: "1", labels: Js.Dict.empty()}])
  })

  Async.it("Prom metrics are set independently per chain", async t => {
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
          sourceConfig: Config.CustomSources([sourceMock1337.source]),
        },
        {
          chain: #100,
          sourceConfig: Config.CustomSources([sourceMock100.source]),
        },
      ],
    )
    await Utils.delay(0)

    // Enter reorg threshold for both chains
    let _ = await Promise.all2((
      Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
      Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
    ))

    // Advance only chain 1337 to head
    sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
    await indexerMock.getBatchWritePromise()

    // Chain 1337 should be ready, chain 100 should not
    t.expect(
      await indexerMock.metric("envio_progress_ready"),
      ~message="Only chain 1337 should be ready",
    ).toEqual([
      {value: "0", labels: Js.Dict.fromArray([("chainId", "100")])},
      {value: "1", labels: Js.Dict.fromArray([("chainId", "1337")])},
    ])
    t.expect(
      await indexerMock.metric("hyperindex_synced_to_head"),
      ~message="All-ready metric should not be set since chain 100 is not ready",
    ).toEqual([{value: "0", labels: Js.Dict.empty()}])

    // Now advance chain 100 to head
    sourceMock100.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
    await indexerMock.getBatchWritePromise()

    // Both chains should now be ready
    t.expect(
      await indexerMock.metric("envio_progress_ready"),
      ~message="Both chains should be ready",
    ).toEqual([
      {value: "1", labels: Js.Dict.fromArray([("chainId", "100")])},
      {value: "1", labels: Js.Dict.fromArray([("chainId", "1337")])},
    ])
    t.expect(
      await indexerMock.metric("hyperindex_synced_to_head"),
      ~message="All-ready metric should be set when both chains are ready",
    ).toEqual([{value: "1", labels: Js.Dict.empty()}])
  })

  Async.it("Shouldn't allow context access after hander is resolved", async t => {
    let errors = []

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
    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 10,
        logIndex: 0,
        contractRegister: async ({context}) => {
          let _ = Js.Global.setTimeout(
            () => {
              try {
                context.chain.\"Gravatar".add(
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
                context.\"SimpleEntity".set({
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
          context.\"SimpleEntity".set({
            id: "1",
            value: "value-2",
          })
          // Wait to see what will happen when timeout finishes during the batch
          await Utils.delay(1)
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    t.expect(await indexerMock.query(SimpleEntity)).toEqual([
      {Indexer.Entities.SimpleEntity.id: "1", value: "value-2"},
    ])
    t.expect(errors, ~message="should have an error thrown during set").toEqual([
      Utils.Error.make(`Impossible to access context.chain after the contract register is resolved. Make sure you didn't miss an await in the handler.`)->Utils.prettifyExn,
      Utils.Error.make(`Impossible to access context.SimpleEntity after the handler is resolved. Make sure you didn't miss an await in the handler.`)->Utils.prettifyExn,
    ])
  })

  // A regression test for a bug introduced in 2.30.0
  Async.it("Correct event ordering for ordered multichain indexer", async t => {
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
          sourceConfig: Config.CustomSources([sourceMock1337.source]),
        },
        {
          chain: #100,
          sourceConfig: Config.CustomSources([sourceMock100.source]),
        },
      ],
      ~multichain=Ordered,
    )
    await Utils.delay(0)

    // Test inside of reorg threshold, so we can check the history order
    let _ = await Promise.all2((
      Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
      Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
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
      {context}: Internal.genericHandlerArgs<Internal.genericEvent<unknown, Indexer.Block.t, Indexer.Transaction.t>, Indexer.handlerContext>,
    ) => {
      context.\"SimpleEntity".set({
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

    t.expect(
      await Promise.all2((indexerMock.queryCheckpoints(), indexerMock.queryHistory(SimpleEntity))),
    ).toEqual((
      [
        {
          id: 2n,
          chainId: 100,
          blockNumber: 150,
          blockHash: Js.Null.Null,
          eventsProcessed: 1,
        },
        {
          id: 3n,
          chainId: 1337,
          blockNumber: 100,
          blockHash: Js.Null.Value("0x100"),
          eventsProcessed: 0,
        },
        {
          id: 4n,
          chainId: 1337,
          blockNumber: 150,
          blockHash: Js.Null.Null,
          eventsProcessed: 1,
        },
        {
          id: 5n,
          chainId: 100,
          blockNumber: 151,
          blockHash: Js.Null.Null,
          eventsProcessed: 1,
        },
        {
          id: 6n,
          chainId: 100,
          blockNumber: 160,
          blockHash: Js.Null.Value("0x160"),
          eventsProcessed: 0,
        },
      ],
      [
        Set({
          checkpointId: 2n,
          entityId: "1",
          entity: {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "call-0",
          },
        }),
        Set({
          checkpointId: 4n,
          entityId: "1",
          entity: {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "call-1",
          },
        }),
        Set({
          checkpointId: 5n,
          entityId: "1",
          entity: {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "call-2",
          },
        }),
      ],
    ))
  })

  Async.it("Track effects in prom metrics", async t => {
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

    t.expect(
      await indexerMock.metric("envio_effect_call_total"),
      ~message="should have no effect calls in the beginning",
    ).toEqual([])
    t.expect(
      await indexerMock.metric("envio_effect_cache"),
      ~message="should have no effect cache in the beginning",
    ).toEqual([])

    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 100,
          logIndex: 0,
          handler: async ({context}) => {
            t.expect(await context.effect(testEffect, "test")).toEqual("test-output")
            t.expect(await context.effect(testEffectWithCache, "test")).toEqual("test-output")
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      await indexerMock.metric("envio_effect_call_total"),
      ~message="should increment effect calls count",
    ).toEqual([
      {
        value: "1",
        labels: Js.Dict.fromArray([("effect", "testEffect")]),
      },
      {
        value: "1",
        labels: Js.Dict.fromArray([("effect", "testEffectWithCache")]),
      },
    ])
    t.expect(
      await indexerMock.metric("envio_effect_cache"),
      ~message="should increment effect cache count",
    ).toEqual([
      {
        value: "1",
        labels: Js.Dict.fromArray([("effect", "testEffectWithCache")]),
      },
    ])
    t.expect(
      await indexerMock.metric("envio_storage_load_total"),
      ~message="Shouldn't load anything from storage at this point",
    ).toEqual([])
    t.expect(
      await indexerMock.queryEffectCache("testEffectWithCache"),
      ~message="should have the cache entry in db",
    ).toEqual([{"id": `"test"`, "output": %raw(`"test-output"`)}])

    let indexerMock = await indexerMock.restart()
    await Utils.delay(0)

    t.expect(
      await indexerMock.metric("envio_effect_call_total"),
      ~message="Should reset the calls metric on restart",
    ).toEqual([])
    t.expect(
      await indexerMock.metric("envio_effect_cache"),
      ~message="should resume effect cache count on restart",
    ).toEqual([
      {
        value: "1",
        labels: Js.Dict.fromArray([("effect", "testEffectWithCache")]),
      },
    ])

    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 101,
          logIndex: 0,
          handler: async ({context}) => {
            t.expect(
              await Promise.all2((
                context.effect(testEffectWithCache, "test"),
                context.effect(testEffectWithCache, "test-2"),
              )),
            ).toEqual(("test-output", "test-2-output"))
          },
        },
      ],
      ~latestFetchedBlockNumber=101,
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      await Promise.all3((
        indexerMock.metric("envio_storage_load_where_size"),
        indexerMock.metric("envio_storage_load_size"),
        indexerMock.metric("envio_storage_load_total"),
      )),
      ~message="Time to load cache from storage now",
    ).toEqual((
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
    ))
    t.expect(
      await Promise.all2((
        indexerMock.metric("envio_effect_call_total"),
        indexerMock.metric("envio_effect_cache"),
      )),
      ~message="Should increment effect calls count and cache count",
    ).toEqual((
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
    ))

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
            t.expect(
              await Promise.all2((
                context.effect(testEffectWithCacheV2, "test"),
                context.effect(testEffectWithCacheV2, "test-2"),
              )),
            ).toEqual(("test-output-v2", "test-2-output"))
          },
        },
      ],
      ~latestFetchedBlockNumber=102,
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      await indexerMock.queryEffectCache("testEffectWithCache"),
      ~message="Should invalidate loaded cache and store new one",
    ).toEqual([
      {"id": `"test-2"`, "output": %raw(`"test-2-output"`)},
      {"id": `"test"`, "output": %raw(`"test-output-v2"`)},
    ])
    t.expect(
      await indexerMock.metric("envio_effect_cache"),
      ~message="Shouldn't increment on invalidation",
    ).toEqual([
      {
        value: "2",
        labels: Js.Dict.fromArray([("effect", "testEffectWithCache")]),
      },
    ])
  })

  Async.it(
    "Should attempt fallback source when primary source fails with missing params",
    async t => {
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
            sourceConfig: Config.CustomSources([
              sourceMockPrimary.source,
              sourceMockFallback.source,
            ]),
          },
        ],
      )
      await Utils.delay(0)

      // Resolve initial height request from primary source
      t.expect(
        sourceMockPrimary.getHeightOrThrowCalls->Array.length,
        ~message="should have called getHeightOrThrow on primary source",
      ).toEqual(1)
      sourceMockPrimary.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // Primary source should now attempt to fetch items
      switch sourceMockPrimary.getItemsOrThrowCalls {
      | [call] =>
        // Simulate missing params error from HyperSync (converted to InvalidData by the source)
        call.reject(
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
      | _ => Js.Exn.raiseError("should have called getItemsOrThrow on primary source")
      }

      await Utils.delay(0)
      await Utils.delay(0)

      // The fallback source should now be called immediately
      switch sourceMockFallback.getItemsOrThrowCalls {
      | [call] =>
        // Resolve the fallback source successfully
        call.resolve([], ~latestFetchedBlockNumber=100)
      | _ =>
        Js.Exn.raiseError("fallback source should be called after primary fails with invalid data")
      }

      await indexerMock.getBatchWritePromise()

      t.expect(
        (
          sourceMockPrimary.getItemsOrThrowCalls->Array.length,
          sourceMockFallback.getItemsOrThrowCalls->Array.length,
        ),
        ~message="Should keep using fallback source for the next query after ImpossibleForTheQuery",
      ).toEqual((0, 1))
    },
  )

  Async.it("Effect rate limiting across multiple windows", async t => {
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
              indexerMock.metric("envio_effect_queue"),
              indexerMock.metric("envio_effect_active_calls"),
            ))
            queueMetricDuringExecution := Some(queueMetric)
            activeMetricDuringExecution := Some(activeMetric)

            let results = await resultsPromise
            t.expect(results).toEqual([
              "1-output",
              "2-output",
              "3-output",
              "4-output",
              "5-output",
              "6-output",
            ])
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )

    await indexerMock.getBatchWritePromise()

    // All effects should complete successfully - verify via calls count metric
    t.expect(
      await indexerMock.metric("envio_effect_call_total"),
      ~message="should have called effect 6 times total",
    ).toEqual([{value: "6", labels: Js.Dict.fromArray([("effect", "testEffectMultiWindow")])}])

    // Check that we captured metrics during execution
    // With 2 calls per window and 6 total calls: 4 items queued, max 2 active
    t.expect(
      queueMetricDuringExecution.contents->Option.getExn,
      ~message="queue should have 4 items during execution",
    ).toEqual([{value: "4", labels: Js.Dict.fromArray([("effect", "testEffectMultiWindow")])}])
    t.expect(
      activeMetricDuringExecution.contents->Option.getExn,
      ~message="active calls should be at rate limit (2)",
    ).toEqual([{value: "2", labels: Js.Dict.fromArray([("effect", "testEffectMultiWindow")])}])

    // Final check - queue should be empty
    t.expect(
      await indexerMock.metric("envio_effect_queue"),
      ~message="queue should be empty after all windows complete",
    ).toEqual([{value: "0", labels: Js.Dict.fromArray([("effect", "testEffectMultiWindow")])}])
  })

  Async.it("Effect rate limiting with single call per window", async t => {
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
              indexerMock.metric("envio_effect_queue"),
              indexerMock.metric("envio_effect_active_calls"),
            ))
            queueMetricDuringExecution := Some(queueMetric1)
            activeMetricDuringExecution := Some(activeMetric1)

            // Check again after first window should complete
            await Utils.delay(14)
            queueMetricAfterFirstWindow := Some(await indexerMock.metric("envio_effect_queue"))

            let _ = await resultsPromise
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )

    await indexerMock.getBatchWritePromise()

    // All 4 effects should complete successfully despite rate limiting
    t.expect(executionOrder->Array.length, ~message="should have executed all 4 calls").toEqual(4)

    // Verify via calls count metric
    t.expect(
      await indexerMock.metric("envio_effect_call_total"),
      ~message="should have called effect 4 times total",
    ).toEqual([{value: "4", labels: Js.Dict.fromArray([("effect", "testEffectNested")])}])

    // Check that we captured metrics during execution
    // With 1 call per window and 4 total calls: 3 items queued, max 1 active
    t.expect(
      queueMetricDuringExecution.contents->Option.getExn,
      ~message="queue should have 3 items during execution",
    ).toEqual([{value: "3", labels: Js.Dict.fromArray([("effect", "testEffectNested")])}])
    t.expect(
      activeMetricDuringExecution.contents->Option.getExn,
      ~message="active calls should be at rate limit (1)",
    ).toEqual([{value: "1", labels: Js.Dict.fromArray([("effect", "testEffectNested")])}])

    // Check metrics after first window
    let queueMetric2 = queueMetricAfterFirstWindow.contents->Option.getExn
    let queueValue2 =
      queueMetric2->Array.get(0)->Option.map(m => m.value)->Option.getWithDefault("0")
    t.expect(
      queueValue2 != "0" || executionOrder->Array.length == 4,
      ~message=`queue should have items or all should be done, queue: ${queueValue2}, executed: ${executionOrder
        ->Array.length
        ->Int.toString}`,
    ).toBeTruthy()

    // Final check - queue should be empty
    t.expect(
      await indexerMock.metric("envio_effect_queue"),
      ~message="queue should be empty after all batches complete",
    ).toEqual([{value: "0", labels: Js.Dict.fromArray([("effect", "testEffectNested")])}])
  })

  Async.it("Effect cache can be disabled per-call via context.cache", async t => {
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
            t.expect(await context.effect(testEffectWithCacheControl, "test1")).toEqual(
              "test1-output",
            )

            // Call 2: Same input as call 1, uses in-memory cache from call 1
            // Shouldn't do anything, since memoization
            t.expect(await context.effect(testEffectWithCacheControl, "test1")).toEqual(
              "test1-output",
            )

            // Call 3: Different input with default cache behavior (should cache in memory and DB)
            t.expect(await context.effect(testEffectWithCacheControl, "test2")).toEqual(
              "test2-output",
            )
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      callCount.contents,
      ~message="Effect should be called 2 times (test1 once with cache=false, test2 once)",
    ).toEqual(2)

    t.expect(
      await indexerMock.queryEffectCache("testEffectWithCacheControl"),
      ~message="Should only have test2 in DB (test1 was called with cache=false and subsequent calls used in-memory cache)",
    ).toEqual([{"id": `"test2"`, "output": %raw(`"test2-output"`)}])
  })

  Async.it("Effect error in one call shouldn't cause other calls to fail", async t => {
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
              Js.Exn.raiseError("p1 should have thrown an error")
            } catch {
            | exn =>
              t.expect(
                (exn->Utils.prettifyExn->Utils.magic)["message"],
                ~message="p1 should throw with correct error message",
              ).toEqual("Effect intentionally failed")
            }

            // p2 should succeed (bug: currently fails when p1 throws)
            t.expect(await p2, ~message="p2 should succeed").toEqual("shouldn't-fail-output")
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )
    await indexerMock.getBatchWritePromise()

    // Verify that only p2's successful result was cached
    t.expect(
      await indexerMock.queryEffectCache("throwingEffect"),
      ~message="Should only cache p2's successful result, not p1's failed call",
    ).toEqual([{"id": `"shouldn't-fail"`, "output": %raw(`"shouldn't-fail-output"`)}])
  })

  Async.it(
    "Live source should not participate in initial height fetch but should after sync",
    async t => {
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
            sourceConfig: Config.CustomSources([syncSource.source, liveSource.source]),
          },
        ],
      )
      await Utils.delay(0)

      // During initial height fetch (knownHeight === 0),
      // only the Sync source should be queried, not the Live source.
      // This is important to allow HyperSync's smart block detection to work.
      t.expect(
        syncSource.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should be called for initial height",
      ).toEqual(1)
      t.expect(
        liveSource.getHeightOrThrowCalls->Array.length,
        ~message="Live source should NOT be called during initial height fetch",
      ).toEqual(0)

      // Resolve the initial height and let the indexer start syncing
      syncSource.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // Sync source fetches items (enters reorg threshold at block 100)
      t.expect(
        syncSource.getItemsOrThrowCalls->Array.length,
        ~message="Sync source should fetch items",
      ).toEqual(1)

      // Resolve first batch (0-100) and continue until we reach the head
      syncSource.resolveGetItemsOrThrow([])
      await indexerMock.getBatchWritePromise()

      // After entering reorg threshold, continue fetching until we reach head (300)
      // The indexer will fetch in batches, we need to resolve each one
      syncSource.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=200)
      await indexerMock.getBatchWritePromise()

      syncSource.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexerMock.getBatchWritePromise()

      // First waitForNewBlock runs with isLive=false (NextQuery fires before
      // EventBatchProcessed sets timestampCaughtUpToHeadOrEndblock).
      // Only Sync participates in height racing initially.
      t.expect(
        syncSource.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should be called for first waitForNewBlock",
      ).toEqual(2)
      t.expect(
        liveSource.getHeightOrThrowCalls->Array.length,
        ~message="Live source should NOT participate yet (isLive still false)",
      ).toEqual(0)

      // Resolve the first waitForNewBlock to advance to the next cycle
      syncSource.resolveGetHeightOrThrow(301)
      await Utils.delay(0)
      await Utils.delay(0)

      // Resolve the items query for the new block
      t.expect(
        syncSource.getItemsOrThrowCalls->Array.length,
        ~message="Even though the sync source resolves the rate, we are now in the live mode, so we attempt to query items from the live source now.",
      ).toEqual(0)
      liveSource.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=301)
      await indexerMock.getBatchWritePromise()

      // Now isLive=true (EventBatchProcessed has set timestampCaughtUpToHeadOrEndblock).
      // Second waitForNewBlock: Live=Primary races, Sync=Secondary (not in main group).
      t.expect(
        syncSource.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should stay at 2 (now Secondary, not racing)",
      ).toEqual(2)
      t.expect(
        liveSource.getHeightOrThrowCalls->Array.length,
        ~message="Live source should now participate in height racing after isLive=true",
      ).toEqual(1)
    },
  )

  Async.it("Partition queries adjust ranges depending on responses", async t => {
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

    // Step 1: Resolve height (blockLag=200 by default, headBlock=9800)
    sourceMock.resolveGetHeightOrThrow(10_000)
    await Utils.delay(0)
    await Utils.delay(0)

    // Step 2: Query 1 — resolve at block 500 (range=501)
    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      ~message="Step 2 should have initial query",
    ).toEqual([{"fromBlock": 1, "toBlock": Some(9800), "retry": 0, "p": "0"}])
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=500)
    await indexerMock.getBatchWritePromise()

    // Step 3: Query 2 — resolve at block 800 (range=300)
    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      ~message="Step 3 should have follow-up query",
    ).toEqual([{"fromBlock": 501, "toBlock": Some(9800), "retry": 0, "p": "0"}])
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=800)
    await indexerMock.getBatchWritePromise()

    // Chunking activates: chunkRange=min(300,501)=300, chunkSize=ceil(300*1.8)=540
    // At least 2 chunks of size 540; extra chunks may appear later
    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.map(c => c.payload)
      ->Js.Array2.slice(~start=0, ~end_=2),
      ~message="Should have at least 2 chunks of size 540",
    ).toEqual([
      {"fromBlock": 801, "toBlock": Some(1340), "retry": 0, "p": "0"},
      {"fromBlock": 1341, "toBlock": Some(1880), "retry": 0, "p": "0"},
    ])

    // Phase A — chunks grow:
    // Resolve chunk1 and chunk2 at full range.
    // With the fix, full-range split chunks update block range (540 >= chunkRange 300).
    let calls = sourceMock.getItemsOrThrowCalls
    if calls->Array.length < 2 {
      Js.Exn.raiseError("Expected at least 2 chunks")
    }
    let chunk1 = calls->Js.Array2.unsafe_get(0)
    let chunk2 = calls->Js.Array2.unsafe_get(1)
    chunk1.resolve([], ~latestFetchedBlockNumber=1340)
    chunk2.resolve([], ~latestFetchedBlockNumber=1880)
    await indexerMock.getBatchWritePromise()

    // After: prevQueryRange=540, prevPrevQueryRange=540
    // chunkRange=min(540,540)=540, chunkSize=ceil(540*1.8)=972
    // Assert: new tail chunks have size 972
    let grownChunks =
      sourceMock.getItemsOrThrowCalls->Js.Array2.filter(
        c => c.payload["toBlock"]->Option.map(tb => tb - c.payload["fromBlock"] + 1) == Some(972),
      )
    t.expect(
      grownChunks->Array.length >= 2,
      ~message=`Chunks should have grown to size 972, found ${grownChunks
        ->Array.length
        ->Int.toString} such chunks`,
    ).toBeTruthy()

    // Phase B — chunks shrink on partial response:
    // Resolve the first pending chunk (at queue front) at partial range so the
    // partition actually advances and a batch is written.
    let firstPending = sourceMock.getItemsOrThrowCalls->Array.get(0)->Option.getExn
    firstPending.resolve([], ~latestFetchedBlockNumber=firstPending.payload["fromBlock"] + 99)
    await indexerMock.getBatchWritePromise()

    // After: prevQueryRange=100, prevPrevQueryRange=540
    // chunkRange=min(100,540)=100, chunkSize=ceil(100*1.8)=180
    // Assert: new tail chunks have size 180
    let shrunkChunks =
      sourceMock.getItemsOrThrowCalls->Js.Array2.filter(
        c => c.payload["toBlock"]->Option.map(tb => tb - c.payload["fromBlock"] + 1) == Some(180),
      )
    t.expect(
      shrunkChunks->Array.length >= 2,
      ~message=`Chunks should have shrunk to size 180, found ${shrunkChunks
        ->Array.length
        ->Int.toString} such chunks`,
    ).toBeTruthy()
  })

  Async.it("Items from later chunk wait for earlier chunk to complete", async t => {
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

    // Setup: same preamble — get to 4 chunked queries
    sourceMock.resolveGetHeightOrThrow(10_000)
    await Utils.delay(0)
    await Utils.delay(0)
    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      ~message="Should have initial query",
    ).toEqual([{"fromBlock": 1, "toBlock": Some(9800), "retry": 0, "p": "0"}])
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=500)
    await indexerMock.getBatchWritePromise()
    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      ~message="Should have follow-up query",
    ).toEqual([{"fromBlock": 501, "toBlock": Some(9800), "retry": 0, "p": "0"}])
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=800)
    await indexerMock.getBatchWritePromise()

    // At least 2 chunks starting at (801,1340), (1341,1880); extra chunks may appear later
    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.map(c => c.payload)
      ->Js.Array2.slice(~start=0, ~end_=2),
      ~message="Should have at least 2 chunks of size 540",
    ).toEqual([
      {"fromBlock": 801, "toBlock": Some(1340), "retry": 0, "p": "0"},
      {"fromBlock": 1341, "toBlock": Some(1880), "retry": 0, "p": "0"},
    ])
    let calls = sourceMock.getItemsOrThrowCalls
    if calls->Array.length < 2 {
      Js.Exn.raiseError("Expected at least 2 chunks")
    }
    let chunk1 = calls->Js.Array2.unsafe_get(0)
    let chunk2 = calls->Js.Array2.unsafe_get(1)

    // Step 1: Resolve chunk2 FIRST (out of order) with item at block 1500
    chunk2.resolve([
      {
        blockNumber: 1500,
        logIndex: 0,
        handler: async ({context}) => {
          context.\"SimpleEntity".set({id: "item-1500", value: "from-chunk2"})
        },
      },
    ])
    // Wait for chunk2's response to be processed
    await Utils.delay(0)
    await Utils.delay(0)

    // Item at 1500 should NOT be in DB yet — chunk1 hasn't completed,
    // so bufferBlockNumber=800 and 1500 > 800 means it's not ready.
    t.expect(
      await indexerMock.query(SimpleEntity),
      ~message="Item at block 1500 should not be ready while chunk1 is pending",
    ).toEqual([])

    // Step 2: Resolve chunk1 at HALF range (801-1070) with item at block 850.
    // Only chunk1's first half is consumed; chunk2 still blocked.
    // After chunk2 resolved, chunk1 should remain pending
    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.map(c => c.payload)
      ->Js.Array2.slice(~start=0, ~end_=1),
      ~message="After chunk2 resolved, chunk1 should remain pending",
    ).toEqual([{"fromBlock": 801, "toBlock": Some(1340), "retry": 0, "p": "0"}])
    chunk1.resolve(
      [
        {
          blockNumber: 850,
          logIndex: 0,
          handler: async ({context}) => {
            context.\"SimpleEntity".set({id: "item-850", value: "from-chunk1"})
          },
        },
      ],
      ~latestFetchedBlockNumber=1070,
    )
    await indexerMock.getBatchWritePromise()

    // Only item-850 should be in DB — chunk1 didn't finish its full range,
    // so chunk2's item at 1500 is still beyond the buffer.
    t.expect(
      await indexerMock.query(SimpleEntity),
      ~message="Only item-850 should be in DB after partial chunk1 resolve",
    ).toEqual([{Indexer.Entities.SimpleEntity.id: "item-850", value: "from-chunk1"}])

    // Step 3: A finishing query for the remainder of chunk1 (1071-1340) should exist.
    let finishingQuery =
      sourceMock.getItemsOrThrowCalls->Js.Array2.find(c => c.payload["fromBlock"] === 1071)
    t.expect(
      finishingQuery->Option.map(c => c.payload),
      ~message="Should have a finishing query for the rest of chunk1",
    ).toEqual(Some({"fromBlock": 1071, "toBlock": Some(1340), "retry": 0, "p": "0"}))

    // Step 4: Resolve the finishing query — now chunk1's full range is consumed,
    // then chunk2 is consumed too. bufferBlockNumber advances to 1880.
    (finishingQuery->Option.getExn).resolve([], ~latestFetchedBlockNumber=1340)
    await indexerMock.getBatchWritePromise()

    // Both items should now be in DB
    t.expect(
      await indexerMock.query(SimpleEntity),
      ~message="Both items should be in DB after chunk1 fully completes",
    ).toEqual([
      {Indexer.Entities.SimpleEntity.id: "item-850", value: "from-chunk1"},
      {Indexer.Entities.SimpleEntity.id: "item-1500", value: "from-chunk2"},
    ])
  })

  Async.it("Partition merging works for fetching partitions via mergeBlock", async t => {
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

    // Step 1: Resolve height
    sourceMock.resolveGetHeightOrThrow(100_000)
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      ~message="Step 1: initial query for partition 0",
    ).toEqual([{"fromBlock": 1, "toBlock": Some(99800), "retry": 0, "p": "0"}])

    // Step 2: Register DC1 at block 5000, DC2 at block 25100
    // Gap = 25099 - 4999 = 20100 > tooFarBlockRange(20000) → separate partitions
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 5000,
          logIndex: 0,
          contractRegister: async ({context}) => {
            context.chain.\"Gravatar".add(
              "0x1111111111111111111111111111111111111111"->Address.Evm.fromStringOrThrow,
            )
          },
        },
        {
          blockNumber: 25100,
          logIndex: 0,
          contractRegister: async ({context}) => {
            context.chain.\"Gravatar".add(
              "0x2222222222222222222222222222222222222222"->Address.Evm.fromStringOrThrow,
            )
          },
        },
      ],
      ~latestFetchedBlockNumber=25100,
    )
    // Batch writes because P0 advances and items at blocks 5000,25100 are processable
    await indexerMock.getBatchWritePromise()

    // DC1 = partition "2" at lfb=4999, DC2 = partition "3" at lfb=25099
    // (partition "1" is created from splitting existing partition for the new dynamic contract)
    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.map(c => (c.payload["p"], c.payload["fromBlock"]))
      ->Js.Array2.sortInPlaceWith(((_, a), (_, b)) => a - b),
      ~message="Step 2: queries for DC1(5000), DC2(25100), P0(25101)",
    ).toEqual([("2", 5000), ("3", 25100), ("0", 25101)])

    // Step 3: Resolve DC2 at lfb=25600 (range=501, first chunk history entry)
    // Buffer block stays 4999 (DC1 is earliest) → no batch write
    let dc2Call1 =
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.find(c => c.payload["p"] === "3")
      ->Option.getExn
    dc2Call1.resolve([], ~latestFetchedBlockNumber=25600)
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.map(c => (c.payload["p"], c.payload["fromBlock"]))
      ->Js.Array2.sortInPlaceWith(((_, a), (_, b)) => a - b),
      ~message="Step 3: DC2 new query from 25601",
    ).toEqual([("2", 5000), ("0", 25101), ("3", 25601)])

    // Step 4: Resolve DC2 at lfb=25900 (range=300) → chunking activates
    // chunkRange=min(300,501)=300, chunkSize=ceil(300*1.8)=540
    // Chunks: (25901,26440),(26441,26980) — concurrency limited → chunk1 only
    // Buffer block stays 4999 → no batch write
    let dc2Call2 =
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.find(c => c.payload["p"] === "3")
      ->Option.getExn
    dc2Call2.resolve([], ~latestFetchedBlockNumber=25900)
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.map(c => (c.payload["p"], c.payload["fromBlock"], c.payload["toBlock"]))
      ->Js.Array2.sortInPlaceWith(((_, a, _), (_, b, _)) => a - b),
      ~message="Step 4: DC2 has 2 chunks (25901-26440, 26441-26980)",
    ).toEqual([
      ("2", 5000, Some(99800)),
      ("0", 25101, Some(99800)),
      ("3", 25901, Some(26440)),
      ("3", 26441, Some(26980)),
    ])

    // Step 5: Resolve DC1 at lfb=7000 → merge triggers
    // DC1 mergeBlock=7000 (idle), DC2 mergeBlock=26980 (last chunk toBlock)
    // 7000 + 20000 = 27000 > 26980 → within range → MERGE
    // Both lfb < mergeBlock → (true,true): both get mergeBlock=26980, new partition "4"
    // Buffer empty → no batch write
    let dc1Call =
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.find(c => c.payload["p"] === "2")
      ->Option.getExn
    dc1Call.resolve([], ~latestFetchedBlockNumber=7000)
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)

    // After merge:
    // DC1("2"): mergeBlock=26980, query 7001→26980
    // DC2("3"): mergeBlock=26980, chunks still pending
    // P0("0"): still pending 25101→99800
    // New("4"): lfb=26980, both addresses, inherits minRange=300 from DC2 history
    //   → chunkSize=ceil(300*1.8)=540, chunks: 26981→27520, 27521→28060
    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.map(c => (c.payload["p"], c.payload["fromBlock"], c.payload["toBlock"]))
      ->Js.Array2.sortInPlaceWith(((_, a, _), (_, b, _)) => a - b),
      ~message="After merge: DC1 queries to mergeBlock, DC2 chunks pending, new partition '4'",
    ).toEqual([
      ("2", 7001, Some(26980)),
      ("0", 25101, Some(99800)),
      ("3", 25901, Some(26440)),
      ("3", 26441, Some(26980)),
      ("4", 26981, Some(27520)),
      ("4", 27521, Some(28060)),
    ])

    // Verify merged partition "4" has both DC addresses
    let partition4Call =
      sourceMock.getItemsOrThrowCalls
      ->Js.Array2.find(c => c.payload["p"] === "4")
      ->Option.getExn
    let addresses = partition4Call.payload->Mock.Source.CallPayload.addresses
    t.expect(
      addresses->Js.Dict.unsafeGet("Gravatar")->Array.length,
      ~message="Merged partition should have addresses from both DCs",
    ).toEqual(2)
  })

  Async.it(
    "_meta and chain_metadata return events processed as a number (float4 cast)",
    async t => {
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
        ~enableHasura=true,
      )
      await Utils.delay(0)

      sourceMock.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      sourceMock.resolveGetItemsOrThrow([
        {
          blockNumber: 50,
          logIndex: 1,
        },
      ])
      await indexerMock.getBatchWritePromise()

      // Update events_processed to a value > int32 max to verify uint52 column works
      let sql = PgStorage.makeClient()
      let _ =
        await sql->Postgres.unsafe(
          `UPDATE "${Env.Db.publicSchema}"."envio_chains" SET "events_processed" = 2147487821 WHERE "id" = 1337`,
        )

      // float4 cast in the views makes Hasura return numbers instead of strings
      // float4 has ~7 digits of precision, so large values lose precision
      t.expect(
        await indexerMock.graphql(`query { _meta { chainId eventsProcessed } }`),
        ~message="_meta should return eventsProcessed as a number (float4 not stringified by Hasura)",
      ).toEqual({
        data: {
          "_meta": [
            {
              "chainId": 1337,
              "eventsProcessed": 2147487700., // float4 precision loss from 2147487821
            },
          ],
        },
      })

      t.expect(
        await indexerMock.graphql(`query { chain_metadata { chain_id num_events_processed } }`),
        ~message="chain_metadata should return num_events_processed as a number (float4 not stringified)",
      ).toEqual({
        data: {
          "chain_metadata": [
            {
              "chain_id": 1337,
              "num_events_processed": 2147487700., // float4 precision loss from 2147487821
            },
          ],
        },
      })
    },
  )
})
