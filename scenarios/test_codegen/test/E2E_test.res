open Vitest

describe("E2E tests", () => {
  let getChainAddresses = async (indexerMock: MockIndexer.Indexer.t, ~chainId) => {
    let addresses: array<InternalTable.EnvioAddresses.t> = await indexerMock.queryRaw(
      InternalTable.EnvioAddresses.entityConfig,
    )
    addresses
    ->Array.filter(a => a.chainId === chainId)
    ->Array.map(a => (
      a->Config.EnvioAddresses.getAddress->Address.toString,
      a.contractName,
      a.registrationBlock,
    ))
  }

  Async.it(
    "Populates config addresses on init and preserves them across restart",
    async t => {
      let sourceMock = MockIndexer.Source.make([], ~chain=#1337)
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
      )

      let expected = [
        ("0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3", "Gravatar", -1),
        ("0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC", "NftFactory", -1),
      ]

      t.expect(
        await getChainAddresses(indexerMock, ~chainId=1337),
        ~message="Config addresses should be inserted with registrationBlock=-1 on init",
      ).toEqual(expected)

      let restarted = await indexerMock.restart()

      t.expect(
        await getChainAddresses(restarted, ~chainId=1337),
        ~message="Config addresses should survive restart from DB",
      ).toEqual(expected)
    },
  )

  Async.it("Currectly starts indexing from a non-zero start block", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let _indexerMock = await MockIndexer.Indexer.make(
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
      sourceMock.getItemsOrThrowCalls->Array.map(call => call.payload),
      ~message="Should request items from start block to reorg threshold",
    ).toEqual([{"fromBlock": 100, "toBlock": Some(200), "retry": 0, "p": "0"}])
  })

  Async.it("Correctly sets Prom metrics", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sourceConfig: Config.CustomSources([sourceMock.source]),
        },
      ],
    )
    await Utils.delay(0)

    t.expect(await indexerMock.metric("envio_reorg_threshold")).toEqual([
      {value: "0", labels: Dict.make()},
    ])
    t.expect(await indexerMock.metric("hyperindex_synced_to_head")).toEqual([
      {value: "0", labels: Dict.make()},
    ])

    await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

    t.expect(await indexerMock.metric("envio_reorg_threshold")).toEqual([
      {value: "1", labels: Dict.make()},
    ])
    t.expect(await indexerMock.metric("hyperindex_synced_to_head")).toEqual([
      {value: "0", labels: Dict.make()},
    ])

    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
    await indexerMock.getBatchWritePromise()

    t.expect(
      await indexerMock.metric("hyperindex_synced_to_head"),
      ~message="should have set hyperindex_synced_to_head metric to 1",
    ).toEqual([{value: "1", labels: Dict.make()}])
  })

  Async.itWithOptions("Prom readiness metrics are gated on the whole indexer", {retry: 3}, async t => {
    let sourceMock1337 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let sourceMock100 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#100,
    )
    let indexerMock = await MockIndexer.Indexer.make(
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
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
    ))

    // Only the most-behind chain (100 — the progress tie breaks by ascending
    // chain id) gets the follow-up query; chain 1337 sits the round out until
    // the leader's reservation releases. Advance chain 100 to head first.
    sourceMock100.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
    await indexerMock.getBatchWritePromise()

    // No chain is marked ready until every chain catches up
    t.expect(
      await indexerMock.metric("envio_progress_ready"),
      ~message="No chain is ready while chain 1337 is still syncing",
    ).toEqual([
      {value: "0", labels: Dict.fromArray([("chainId", "100")])},
      {value: "0", labels: Dict.fromArray([("chainId", "1337")])},
    ])
    t.expect(
      await indexerMock.metric("hyperindex_synced_to_head"),
      ~message="All-ready metric should not be set since chain 1337 is not ready",
    ).toEqual([{value: "0", labels: Dict.make()}])

    // Now advance chain 1337 to head
    sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
    await indexerMock.getBatchWritePromise()

    // Both chains should now be ready
    t.expect(
      await indexerMock.metric("envio_progress_ready"),
      ~message="Both chains should be ready",
    ).toEqual([
      {value: "1", labels: Dict.fromArray([("chainId", "100")])},
      {value: "1", labels: Dict.fromArray([("chainId", "1337")])},
    ])
    t.expect(
      await indexerMock.metric("hyperindex_synced_to_head"),
      ~message="All-ready metric should be set when both chains are ready",
    ).toEqual([{value: "1", labels: Dict.make()}])
  })

  Async.it("Shouldn't allow context access after hander is resolved", async t => {
    let errors = []

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
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
          let _ = setTimeout(
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
          let _ = setTimeout(
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

  Async.it("Track effects in prom metrics", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
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
            t.expect(
              await Promise.all2((
                context.effect(testEffectWithCache, "test"),
                context.effect(testEffectWithCache, "test-2"),
              )),
            ).toEqual(("test-output", "test-2-output"))
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
        labels: Dict.fromArray([("effect", "testEffect")]),
      },
      {
        value: "2",
        labels: Dict.fromArray([("effect", "testEffectWithCache")]),
      },
    ])
    t.expect(
      await indexerMock.metric("envio_effect_cache"),
      ~message="should increment effect cache count",
    ).toEqual([
      {
        value: "2",
        labels: Dict.fromArray([("effect", "testEffectWithCache")]),
      },
    ])
    t.expect(
      await indexerMock.metric("envio_storage_load_total"),
      ~message="Shouldn't load anything from storage at this point",
    ).toEqual([])
    t.expect(
      await indexerMock.queryEffectCache("testEffectWithCache"),
      ~message="should have the cache entries in db",
    ).toEqual([
      {"id": `"test"`, "output": %raw(`"test-output"`)},
      {"id": `"test-2"`, "output": %raw(`"test-2-output"`)},
    ])

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
        value: "2",
        labels: Dict.fromArray([("effect", "testEffectWithCache")]),
      },
    ])

    // A changed effect output schema is a code change, so it only takes effect
    // after a restart. The restart clears the warm in-memory cache, so the db
    // entries are reloaded and re-validated against the new schema. "test-output"
    // fails the new schema and is recomputed; "test-2-output" passes and is kept.
    let testEffectWithCacheV2 = Envio.createEffect(
      {
        name: "testEffectWithCache",
        input: S.string,
        output: S.string->S.refine(
          s =>
            v =>
              if !(v->String.includes("2")) {
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
                context.effect(testEffectWithCacheV2, "test"),
                context.effect(testEffectWithCacheV2, "test-2"),
              )),
            ).toEqual(("test-output-v2", "test-2-output"))
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
          labels: Dict.fromArray([
            ("operation", "testEffectWithCache.effect"),
            ("storage", "postgres"),
          ]),
        },
      ],
      [
        {
          value: "2",
          labels: Dict.fromArray([
            ("operation", "testEffectWithCache.effect"),
            ("storage", "postgres"),
          ]),
        },
      ],
      [
        {
          value: "1",
          labels: Dict.fromArray([
            ("operation", "testEffectWithCache.effect"),
            ("storage", "postgres"),
          ]),
        },
      ],
    ))
    t.expect(
      await Promise.all2((
        indexerMock.metric("envio_effect_call_total"),
        indexerMock.metric("envio_effect_cache"),
      )),
      ~message="Should recompute the invalidated entry and keep the cache count",
    ).toEqual((
      [
        {
          value: "1",
          labels: Dict.fromArray([("effect", "testEffectWithCache")]),
        },
      ],
      [
        {
          value: "2",
          labels: Dict.fromArray([("effect", "testEffectWithCache")]),
        },
      ],
    ))

    t.expect(
      await indexerMock.queryEffectCache("testEffectWithCache"),
      ~message="Should invalidate loaded cache and store new one",
    ).toEqual([
      {"id": `"test-2"`, "output": %raw(`"test-2-output"`)},
      {"id": `"test"`, "output": %raw(`"test-output-v2"`)},
    ])
  })

  // Reproduction for https://github.com/enviodev/hyperindex/issues/1173
  // The effect context's `log` getter is compiled as an arrow function, so
  // `this` is captured from the surrounding ESM module scope (undefined under
  // strict mode) instead of the EffectContext instance. The lookup
  // `paramsByThis.get(undefined)` returns undefined, and accessing `.item`
  // throws `TypeError: Cannot read properties of undefined (reading 'item')`.
  Async.it("context.log should be accessible from inside an effect handler", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sourceConfig: Config.CustomSources([sourceMock.source]),
        },
      ],
    )
    await Utils.delay(0)

    let probeEffect = Envio.createEffect(
      {
        name: "logProbeEffect",
        input: S.string,
        output: S.string,
        rateLimit: Disable,
      },
      async ({input, context}) => {
        context.log.info("hello from effect")
        input ++ "-output"
      },
    )

    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    let effectResult = ref(None)
    let effectError = ref(None)
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 100,
          logIndex: 0,
          handler: async ({context}) => {
            switch await context.effect(probeEffect, "test") {
            | output => effectResult := Some(output)
            | exception exn => effectError := Some(exn)
            }
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      (effectError.contents, effectResult.contents),
      ~message="context.log access from inside an effect must not throw",
    ).toEqual((None, Some("test-output")))
  })

  Async.it(
    "Should attempt fallback source when primary source fails with missing params",
    async t => {
      let sourceMockPrimary = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMockFallback = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let indexerMock = await MockIndexer.Indexer.make(
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
      | _ => JsError.throwWithMessage("should have called getItemsOrThrow on primary source")
      }

      await Utils.delay(0)
      await Utils.delay(0)

      // The fallback source should now be called immediately
      switch sourceMockFallback.getItemsOrThrowCalls {
      | [call] =>
        // Resolve the fallback source successfully
        call.resolve([], ~latestFetchedBlockNumber=100)
      | _ =>
        JsError.throwWithMessage(
          "fallback source should be called after primary fails with invalid data",
        )
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
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
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
    ).toEqual([{value: "6", labels: Dict.fromArray([("effect", "testEffectMultiWindow")])}])

    // Check that we captured metrics during execution
    // With 2 calls per window and 6 total calls: 4 items queued, max 2 active
    t.expect(
      queueMetricDuringExecution.contents->Option.getOrThrow,
      ~message="queue should have 4 items during execution",
    ).toEqual([{value: "4", labels: Dict.fromArray([("effect", "testEffectMultiWindow")])}])
    t.expect(
      activeMetricDuringExecution.contents->Option.getOrThrow,
      ~message="active calls should be at rate limit (2)",
    ).toEqual([{value: "2", labels: Dict.fromArray([("effect", "testEffectMultiWindow")])}])

    // Final check - queue should be empty
    t.expect(
      await indexerMock.metric("envio_effect_queue"),
      ~message="queue should be empty after all windows complete",
    ).toEqual([{value: "0", labels: Dict.fromArray([("effect", "testEffectMultiWindow")])}])
  })

  Async.it("Effect rate limiting with single call per window", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
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
    ).toEqual([{value: "4", labels: Dict.fromArray([("effect", "testEffectNested")])}])

    // Check that we captured metrics during execution
    // With 1 call per window and 4 total calls: 3 items queued, max 1 active
    t.expect(
      queueMetricDuringExecution.contents->Option.getOrThrow,
      ~message="queue should have 3 items during execution",
    ).toEqual([{value: "3", labels: Dict.fromArray([("effect", "testEffectNested")])}])
    t.expect(
      activeMetricDuringExecution.contents->Option.getOrThrow,
      ~message="active calls should be at rate limit (1)",
    ).toEqual([{value: "1", labels: Dict.fromArray([("effect", "testEffectNested")])}])

    // Check metrics after first window
    let queueMetric2 = queueMetricAfterFirstWindow.contents->Option.getOrThrow
    let queueValue2 = queueMetric2->Array.get(0)->Option.map(m => m.value)->Option.getOr("0")
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
    ).toEqual([{value: "0", labels: Dict.fromArray([("effect", "testEffectNested")])}])
  })

  Async.it("Effect cache can be disabled per-call via context.cache", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
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
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
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
        if input->String.includes("should-fail") {
          Utils.Error.make("Effect intentionally failed")->throw
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
              JsError.throwWithMessage("p1 should have thrown an error")
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
      let syncSource = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
        ~sourceFor=Source.Sync,
      )
      let liveSource = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
        ~sourceFor=Source.Realtime,
      )

      let indexerMock = await MockIndexer.Indexer.make(
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

      // On catch-up the chain flips to realtime (Live=Primary). The backfill
      // waiter had already parked on the Sync source, so it polls Sync once more
      // before the realtime transition bumps the epoch and a fresh Live-source
      // waiter supersedes it. Wait for the Live source to be polled.
      let waitLiveHeightCalls = async n =>
        while liveSource.getHeightOrThrowCalls->Array.length < n {
          await Utils.delay(0)
        }
      await waitLiveHeightCalls(1)
      t.expect(
        liveSource.getHeightOrThrowCalls->Array.length,
        ~message="Live source should participate in the first waitForNewBlock (realtime)",
      ).toEqual(1)
      t.expect(
        syncSource.getHeightOrThrowCalls->Array.length,
        ~message="Sync polled once more at the realtime transition, then superseded by Live",
      ).toEqual(2)

      // Resolve the first waitForNewBlock via the Live (Primary) source
      liveSource.resolveGetHeightOrThrow(301)
      await Utils.delay(0)
      await Utils.delay(0)

      // Resolve the items query for the new block
      t.expect(
        syncSource.getItemsOrThrowCalls->Array.length,
        ~message="We are in live mode, so we query items from the live source.",
      ).toEqual(0)
      liveSource.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=301)
      await indexerMock.getBatchWritePromise()

      // Second waitForNewBlock: Live=Primary races again, Sync=Secondary (stays
      // at its post-transition count of 2, the superseded backfill poll).
      await waitLiveHeightCalls(2)
      t.expect(
        syncSource.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should not be polled again (Secondary, not racing)",
      ).toEqual(2)
      t.expect(
        liveSource.getHeightOrThrowCalls->Array.length,
        ~message="Live source should keep racing in realtime mode",
      ).toEqual(2)
    },
  )

  Async.it("Partition queries adjust ranges depending on responses", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sourceConfig: Config.CustomSources([sourceMock.source]),
        },
      ],
    )
    await Utils.delay(0)

    // Step 1: Resolve height (blockLag=200 by default, headBlock=19800)
    sourceMock.resolveGetHeightOrThrow(20_000)
    await Utils.delay(0)
    await Utils.delay(0)

    // Step 2: Query 1 — resolve at block 500 (range=501)
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
      ~message="Step 2 should have initial query",
    ).toEqual([{"fromBlock": 1, "toBlock": Some(19800), "retry": 0, "p": "0"}])
    sourceMock.resolveGetItemsOrThrow([{blockNumber: 100, logIndex: 0}], ~latestFetchedBlockNumber=500)
    await indexerMock.getBatchWritePromise()

    // Step 3: Query 2 — resolve at block 800 (range=300)
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
      ~message="Step 3 should have follow-up query",
    ).toEqual([{"fromBlock": 501, "toBlock": Some(19800), "retry": 0, "p": "0"}])
    sourceMock.resolveGetItemsOrThrow([{blockNumber: 600, logIndex: 0}], ~latestFetchedBlockNumber=800)
    await indexerMock.getBatchWritePromise()

    // Chunking activates: chunkRange=min(300,500)=300, chunkSize=ceil(300*1.8)=540.
    // Uniform chunks are tiled from the range start (no probes).
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)->Array.slice(~start=0, ~end=3),
      ~message="Should tile uniform 540-size chunks from the range start",
    ).toEqual([
      {"fromBlock": 801, "toBlock": Some(1340), "retry": 0, "p": "0"},
      {"fromBlock": 1341, "toBlock": Some(1880), "retry": 0, "p": "0"},
      {"fromBlock": 1881, "toBlock": Some(2420), "retry": 0, "p": "0"},
    ])

    // Phase A — chunks grow:
    // Resolve the first three chunks at their full 540 boundaries. Full-size
    // responses update the heuristic (540 >= chunkRange 300), climbing chunkRange
    // to 540 so the next tail chunks grow to ceil(540*1.8)=972.
    let calls = sourceMock.getItemsOrThrowCalls
    if calls->Array.length < 3 {
      JsError.throwWithMessage("Expected at least 3 chunks")
    }
    let chunk1 = calls->Array.getUnsafe(0)
    let chunk2 = calls->Array.getUnsafe(1)
    let chunk3 = calls->Array.getUnsafe(2)
    chunk1.resolve([{blockNumber: 900, logIndex: 0}], ~latestFetchedBlockNumber=1340)
    chunk2.resolve([{blockNumber: 1400, logIndex: 0}], ~latestFetchedBlockNumber=1880)
    chunk3.resolve([{blockNumber: 1900, logIndex: 0}], ~latestFetchedBlockNumber=2420)
    await indexerMock.getBatchWritePromise()
    // Drain the in-flight 540-chunk backlog so the partition regenerates its
    // tail at the grown chunkRange (540). New tail chunks reach ceil(540*1.8)=972.
    sourceMock.getItemsOrThrowCalls
    ->Array.copy
    ->Array.forEach(c =>
      c.resolve(
        [{blockNumber: c.payload["fromBlock"], logIndex: 0}],
        ~latestFetchedBlockNumber=c.payload["toBlock"]->Option.getOr(c.payload["fromBlock"]),
      )
    )
    await indexerMock.getBatchWritePromise()

    // Assert: full-size responses grew the chunk size beyond the initial 540.
    let maxChunkSize =
      sourceMock.getItemsOrThrowCalls->Array.reduce(0, (max, c) =>
        switch c.payload["toBlock"] {
        | Some(tb) => Pervasives.max(max, tb - c.payload["fromBlock"] + 1)
        | None => max
        }
      )
    t.expect(maxChunkSize > 540, ~message="Tail chunks should have grown beyond the initial 540").toBe(
      true,
    )

    // Phase B — chunks shrink on partial response:
    // Resolve the first pending chunk (at queue front) at a small partial range
    // (100 blocks) so the partition advances and the heuristic shrinks.
    let firstPending = sourceMock.getItemsOrThrowCalls->Array.get(0)->Option.getOrThrow
    firstPending.resolve(
      [{blockNumber: firstPending.payload["fromBlock"], logIndex: 0}],
      ~latestFetchedBlockNumber=firstPending.payload["fromBlock"] + 99,
    )
    await indexerMock.getBatchWritePromise()

    // After the partial response sourceRangeCapacity=100, so chunkRange drops to
    // min(100, 540)=100 and the regenerated chunks shrink to ceil(100*1.8)=180,
    // well below the grown 972-size tail.
    let shrunkChunks =
      sourceMock.getItemsOrThrowCalls->Array.filter(
        c => c.payload["toBlock"]->Option.map(tb => tb - c.payload["fromBlock"] + 1) == Some(180),
      )
    t.expect(
      shrunkChunks->Array.length >= 1,
      ~message="New chunks should have shrunk to the uniform size 180",
    ).toBeTruthy()
  })

  Async.it("Items from later chunk wait for earlier chunk to complete", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
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
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
      ~message="Should have initial query",
    ).toEqual([{"fromBlock": 1, "toBlock": Some(9800), "retry": 0, "p": "0"}])
    sourceMock.resolveGetItemsOrThrow([{blockNumber: 100, logIndex: 0}], ~latestFetchedBlockNumber=500)
    await indexerMock.getBatchWritePromise()
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
      ~message="Should have follow-up query",
    ).toEqual([{"fromBlock": 501, "toBlock": Some(9800), "retry": 0, "p": "0"}])
    sourceMock.resolveGetItemsOrThrow([{blockNumber: 600, logIndex: 0}], ~latestFetchedBlockNumber=800)
    await indexerMock.getBatchWritePromise()

    // Chunking activates: chunkRange=300, chunkSize=540. Uniform chunks tiled
    // from the range start.
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)->Array.slice(~start=0, ~end=3),
      ~message="Should tile uniform 540-size chunks from the range start",
    ).toEqual([
      {"fromBlock": 801, "toBlock": Some(1340), "retry": 0, "p": "0"},
      {"fromBlock": 1341, "toBlock": Some(1880), "retry": 0, "p": "0"},
      {"fromBlock": 1881, "toBlock": Some(2420), "retry": 0, "p": "0"},
    ])
    let calls = sourceMock.getItemsOrThrowCalls
    if calls->Array.length < 3 {
      JsError.throwWithMessage("Expected at least 3 chunks")
    }
    let chunk1 = calls->Array.getUnsafe(0)
    let chunk3 = calls->Array.getUnsafe(2)

    // Step 1: Resolve the later chunk3 (1881-2420) FIRST (out of order) with item
    // at block 2000
    chunk3.resolve([
      {
        blockNumber: 2000,
        logIndex: 0,
        handler: async ({context}) => {
          context.\"SimpleEntity".set({id: "item-2000", value: "from-chunk3"})
        },
      },
    ])
    // Wait for chunk3's response to be processed
    await Utils.delay(0)
    await Utils.delay(0)

    // Item at 2000 should NOT be in DB yet — earlier chunks haven't completed,
    // so bufferBlockNumber=800 and 2000 > 800 means it's not ready.
    t.expect(
      await indexerMock.query(SimpleEntity),
      ~message="Item at block 2000 should not be ready while earlier chunks are pending",
    ).toEqual([])

    // Step 2: Resolve chunk1 with item at block 850. Buffer advances to 1340,
    // but chunk2 is still pending so the item at 2000 stays blocked.
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)->Array.slice(~start=0, ~end=1),
      ~message="After chunk3 resolved, chunk1 should remain pending",
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
      ~latestFetchedBlockNumber=1340,
    )
    await indexerMock.getBatchWritePromise()

    // Only item-850 should be in DB — chunk2 hasn't completed,
    // so chunk3's item at 2000 is still beyond the buffer.
    t.expect(
      await indexerMock.query(SimpleEntity),
      ~message="Only item-850 should be in DB while chunk2 is pending",
    ).toEqual([{Indexer.Entities.SimpleEntity.id: "item-850", value: "from-chunk1"}])

    // Step 3: chunk2 (1341-1880) bridging chunk1 and chunk3 should still be pending.
    let bridgingQuery =
      sourceMock.getItemsOrThrowCalls->Array.find(c => c.payload["fromBlock"] === 1341)
    t.expect(
      bridgingQuery->Option.map(c => c.payload),
      ~message="Should still have the bridging chunk2 query",
    ).toEqual(Some({"fromBlock": 1341, "toBlock": Some(1880), "retry": 0, "p": "0"}))

    // Step 4: Resolve chunk2 — now the range is contiguous through chunk3,
    // bufferBlockNumber advances to 2420 and the item at 2000 becomes ready.
    (bridgingQuery->Option.getOrThrow).resolve([], ~latestFetchedBlockNumber=1880)
    await indexerMock.getBatchWritePromise()

    // Both items should now be in DB
    t.expect(
      await indexerMock.query(SimpleEntity),
      ~message="Both items should be in DB after chunk1 fully completes",
    ).toEqual([
      {Indexer.Entities.SimpleEntity.id: "item-850", value: "from-chunk1"},
      {Indexer.Entities.SimpleEntity.id: "item-2000", value: "from-chunk3"},
    ])
  })

  Async.it("Partition merging works for fetching partitions via mergeBlock", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
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
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
      ~message="Step 1: initial query for partition 0",
    ).toEqual([{"fromBlock": 1, "toBlock": Some(99800), "retry": 0, "p": "0"}])

    // Step 2: Register DC1 at block 5000, DC2 at block 25100
    // Gap = 25099 - 4999 = 20100 > tooFarBlockRange(20000) → separate partitions
    // The 100 plain events at blocks 3000-3099 give the chain a density signal
    // (ready-buffer density immediately, the processing EMA once the batch
    // commits). Without one the chain is cold and its target block is capped at
    // frontier + 20k, which would gate the far partitions this merge
    // choreography relies on fetching in parallel — and the density must be
    // high enough that the chain-level range-cost budget affords DC2's full
    // 12-chunk pipeline below.
    sourceMock.resolveGetItemsOrThrow(
      [
        ...Array.fromInitializer(~length=100, i => (
          {blockNumber: 3000 + i, logIndex: 0}: MockIndexer.Source.itemMock
        )),
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
    // Batch writes because P0 advances and the items at blocks 3000-3099 are processable
    await indexerMock.getBatchWritePromise()

    // DC1 = partition "2" at lfb=4999, DC2 = partition "3" at lfb=25099
    // (partition "1" is created from splitting existing partition for the new dynamic contract)
    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Array.map(c => (c.payload["p"], c.payload["fromBlock"]))
      ->Array.toSorted(((_, a), (_, b)) => Int.compare(a, b)),
      ~message="Step 2: queries for DC1(5000), DC2(25100), P0(25101)",
    ).toEqual([("2", 5000), ("3", 25100), ("0", 25101)])

    // Step 3: Resolve DC2 at lfb=25600 (range=501, first chunk history entry)
    // Buffer block stays 4999 (DC1 is earliest) → no batch write
    let dc2Call1 =
      sourceMock.getItemsOrThrowCalls->Array.find(c => c.payload["p"] === "3")->Option.getOrThrow
    dc2Call1.resolve([{blockNumber: 25200, logIndex: 0}], ~latestFetchedBlockNumber=25600)
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Array.map(c => (c.payload["p"], c.payload["fromBlock"]))
      ->Array.toSorted(((_, a), (_, b)) => Int.compare(a, b)),
      ~message="Step 3: DC2 new query from 25601",
    ).toEqual([("2", 5000), ("0", 25101), ("3", 25601)])

    // Step 4: Resolve DC2 at lfb=25900 (range=300) → chunking activates.
    // chunkRange=min(300,500)=300, chunkSize=ceil(300*1.8)=540. Uniform chunks
    // tiled from 25901 up to the per-partition cap of 12 chunks (→ 32380).
    // Buffer block stays 4999 → no batch write
    let dc2Call2 =
      sourceMock.getItemsOrThrowCalls->Array.find(c => c.payload["p"] === "3")->Option.getOrThrow
    dc2Call2.resolve([{blockNumber: 25700, logIndex: 0}], ~latestFetchedBlockNumber=25900)
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Array.map(c => (c.payload["p"], c.payload["fromBlock"], c.payload["toBlock"]))
      ->Array.toSorted(((_, a, _), (_, b, _)) => Int.compare(a, b)),
      ~message="Step 4: DC2 has 12 uniform 540-size chunks",
    ).toEqual([
      ("2", 5000, Some(99800)),
      ("0", 25101, Some(99800)),
      ("3", 25901, Some(26440)),
      ("3", 26441, Some(26980)),
      ("3", 26981, Some(27520)),
      ("3", 27521, Some(28060)),
      ("3", 28061, Some(28600)),
      ("3", 28601, Some(29140)),
      ("3", 29141, Some(29680)),
      ("3", 29681, Some(30220)),
      ("3", 30221, Some(30760)),
      ("3", 30761, Some(31300)),
      ("3", 31301, Some(31840)),
      ("3", 31841, Some(32380)),
    ])

    // Step 5: Resolve DC1 at lfb=12500 → merge triggers
    // DC1 mergeBlock=12500 (idle), DC2 mergeBlock=32380 (last chunk toBlock)
    // 12500 + 20000 = 32500 > 32380 → within range → MERGE
    // Both lfb < mergeBlock → (true,true): both get mergeBlock=32380, new partition "4"
    // Buffer empty → no batch write
    let dc1Call =
      sourceMock.getItemsOrThrowCalls->Array.find(c => c.payload["p"] === "2")->Option.getOrThrow
    dc1Call.resolve([], ~latestFetchedBlockNumber=12500)
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)

    // After merge:
    // DC1("2"): mergeBlock=32380, single query 12501→32380 (no chunk history)
    // DC2("3"): mergeBlock=32380, chunks still pending
    // P0("0"): still pending 25101→99800
    // New("4"): lfb=32380, both addresses, inherits minRange=300 from DC2 history.
    //   chunkSize=540, uniform chunks from 32381 up to the per-partition cap of 12.
    t.expect(
      sourceMock.getItemsOrThrowCalls
      ->Array.map(c => (c.payload["p"], c.payload["fromBlock"], c.payload["toBlock"]))
      ->Array.toSorted(((_, a, _), (_, b, _)) => Int.compare(a, b)),
      ~message="After merge: DC1 queries to mergeBlock, DC2 chunks pending, new partition '4'",
    ).toEqual([
      ("2", 12501, Some(32380)),
      ("0", 25101, Some(99800)),
      ("3", 25901, Some(26440)),
      ("3", 26441, Some(26980)),
      ("3", 26981, Some(27520)),
      ("3", 27521, Some(28060)),
      ("3", 28061, Some(28600)),
      ("3", 28601, Some(29140)),
      ("3", 29141, Some(29680)),
      ("3", 29681, Some(30220)),
      ("3", 30221, Some(30760)),
      ("3", 30761, Some(31300)),
      ("3", 31301, Some(31840)),
      ("3", 31841, Some(32380)),
      ("4", 32381, Some(32920)),
      ("4", 32921, Some(33460)),
      ("4", 33461, Some(34000)),
      ("4", 34001, Some(34540)),
      ("4", 34541, Some(35080)),
      ("4", 35081, Some(35620)),
      ("4", 35621, Some(36160)),
      ("4", 36161, Some(36700)),
      ("4", 36701, Some(37240)),
      ("4", 37241, Some(37780)),
      ("4", 37781, Some(38320)),
      ("4", 38321, Some(38860)),
    ])

    // Verify merged partition "4" has both DC addresses
    let partition4Call =
      sourceMock.getItemsOrThrowCalls->Array.find(c => c.payload["p"] === "4")->Option.getOrThrow
    let addresses = partition4Call.payload->MockIndexer.Source.CallPayload.addresses
    t.expect(
      addresses->Dict.getUnsafe("Gravatar")->Array.length,
      ~message="Merged partition should have addresses from both DCs",
    ).toEqual(2)
  })

  Async.itSkipInClaudeCloud(
    "_meta and chain_metadata return events processed as a number (float4 cast)",
    async t => {
      let sourceMock = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let indexerMock = await MockIndexer.Indexer.make(
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
      let _ = await sql->Postgres.unsafe(
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

  Async.it(
    "Multichain with reorg: staggered chain catch-up still enters reorg threshold",
    async t => {
      let sourceMock1337 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMock100 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      let indexerMock = await MockIndexer.Indexer.make(
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

      // Chain 1337 catches up first
      await MockIndexer.Helper.initialEnterReorgThreshold(
        ~t,
        ~indexerMock,
        ~sourceMock=sourceMock1337,
      )

      // System should NOT be in reorg threshold yet (chain 100 still backfilling)
      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
        ~message="Should not be in reorg threshold while chain 100 is still backfilling",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Now chain 100 catches up
      await MockIndexer.Helper.initialEnterReorgThreshold(
        ~t,
        ~indexerMock,
        ~sourceMock=sourceMock100,
      )

      // System should now be in reorg threshold
      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
        ~message="Should be in reorg threshold after both chains caught up",
      ).toEqual([{value: "1", labels: Dict.make()}])

      // Chains are at block 100, need to advance to 300 after threshold entry.
      // Only the most-behind chain (100 — the progress tie breaks by ascending
      // chain id) holds a query; 1337 queries once the leader's budget releases.
      sourceMock100.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexerMock.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexerMock.getBatchWritePromise()

      t.expect(
        await indexerMock.metric("hyperindex_synced_to_head"),
        ~message="All chains should be synced to head after advancing to block 300",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )

  Async.it(
    "Multichain without reorg: staggered chain catch-up reports readiness correctly",
    async t => {
      let sourceMock1337 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMock100 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      let indexerMock = await MockIndexer.Indexer.make(
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
        ~shouldRollbackOnReorg=false,
      )
      await Utils.delay(0)

      // Without reorg, chains don't use blockLag so they fetch from startBlock to knownHeight
      // Chain 1337 catches up first
      t.expect(sourceMock1337.getHeightOrThrowCalls->Array.length).toEqual(1)
      sourceMock1337.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexerMock.getBatchWritePromise()

      // No chain is marked ready until every chain catches up
      t.expect(
        await indexerMock.metric("envio_progress_ready"),
        ~message="No chain is ready while chain 100 is still syncing",
      ).toEqual([
        {value: "0", labels: Dict.fromArray([("chainId", "100")])},
        {value: "0", labels: Dict.fromArray([("chainId", "1337")])},
      ])
      t.expect(
        await indexerMock.metric("hyperindex_synced_to_head"),
        ~message="Not all chains synced yet",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Chain 100 catches up
      t.expect(sourceMock100.getHeightOrThrowCalls->Array.length).toEqual(1)
      sourceMock100.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      sourceMock100.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexerMock.getBatchWritePromise()

      // Both chains should now be ready
      t.expect(
        await indexerMock.metric("envio_progress_ready"),
        ~message="Both chains should be ready",
      ).toEqual([
        {value: "1", labels: Dict.fromArray([("chainId", "100")])},
        {value: "1", labels: Dict.fromArray([("chainId", "1337")])},
      ])
      t.expect(
        await indexerMock.metric("hyperindex_synced_to_head"),
        ~message="All chains should be synced to head",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )

  // Regression (production): at realtime, when one chain falls far behind (a
  // large new range that drains the shared fetch-buffer budget), a second chain
  // that is only slightly behind its own head must keep polling for new blocks.
  // The buggy scheduler drops such a chain as NothingToQuery (it is below its
  // head, so it won't wait, yet the drained budget leaves it no query), so it is
  // never dispatched — it stops fetching AND stops polling getHeightOrThrow, and
  // its head tracking goes silent.
  Async.it(
    "Multichain realtime: a near-head chain keeps polling while another chain backfills a large range",
    async t => {
      let leaderSource = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let followerSource = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {chain: #1337, sourceConfig: Config.CustomSources([leaderSource.source])},
          {chain: #100, sourceConfig: Config.CustomSources([followerSource.source])},
        ],
        ~shouldRollbackOnReorg=false,
        ~targetBufferSize=1000,
      )
      await Utils.delay(0)

      // Phase 1: both chains catch up to head (block 100) and become realtime.
      // A handful of events on each seeds a density signal.
      leaderSource.resolveGetHeightOrThrow(100)
      followerSource.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      await Utils.delay(0)

      leaderSource.resolveGetItemsOrThrow(
        [{blockNumber: 20, logIndex: 0}, {blockNumber: 60, logIndex: 0}],
        ~latestFetchedBlockNumber=100,
      )
      await indexerMock.getBatchWritePromise()
      followerSource.resolveGetItemsOrThrow(
        [{blockNumber: 20, logIndex: 0}, {blockNumber: 60, logIndex: 0}],
        ~latestFetchedBlockNumber=100,
      )
      await indexerMock.getBatchWritePromise()

      t.expect(
        await indexerMock.metric("hyperindex_synced_to_head"),
        ~message="both chains reach realtime",
      ).toEqual([{value: "1", labels: Dict.make()}])

      // Both chains are now at head, parked on a realtime getHeightOrThrow poll.
      let followerPollsBefore = followerSource.getHeightOrThrowCalls->Array.length

      // Phase 2: divergent new heights. The leader jumps far ahead (a large
      // backlog whose reservation drains the shared fetch-buffer budget); the
      // follower advances only a little past its own head.
      leaderSource.resolveGetHeightOrThrow(1_000_000)
      followerSource.resolveGetHeightOrThrow(105)
      await Utils.delay(0)
      await Utils.delay(0)

      // Drive the leader's backfill for several ticks, keeping it far behind (so
      // it stays the budget-draining leader). Each response re-runs the
      // cross-chain dispatch, so the follower is re-evaluated every tick.
      for _ in 0 to 4 {
        await MockIndexer.Helper.waitItemsQuery(leaderSource)
        let call = leaderSource.getItemsOrThrowCalls->Array.getUnsafe(0)
        let fromBlock = call.payload["fromBlock"]
        call.resolve(
          [{blockNumber: fromBlock + 20, logIndex: 0}, {blockNumber: fromBlock + 60, logIndex: 0}],
          ~latestFetchedBlockNumber=fromBlock + 99,
        )
        await indexerMock.getBatchWritePromise()
      }

      // The follower is below its own head (frontier 100 < head 105). The
      // indexer is realtime, so the cross-chain alignment clamp is dropped:
      // instead of being starved behind the backfilling leader, the follower
      // fetches its small range to head...
      await MockIndexer.Helper.waitItemsQuery(followerSource)
      let followerCall = followerSource.getItemsOrThrowCalls->Array.getUnsafe(0)
      t.expect(
        followerCall.payload["fromBlock"],
        ~message="follower fetches its own range to head instead of waiting behind the leader",
      ).toEqual(101)
      followerCall.resolve([], ~latestFetchedBlockNumber=105)
      await Utils.delay(0)
      await Utils.delay(0)

      // ...and once at head it goes back to polling for new blocks rather
      // than going silent.
      t.expect(
        followerSource.getHeightOrThrowCalls->Array.length > followerPollsBefore,
        ~message="follower keeps polling getHeightOrThrow while the leader backfills a large range",
      ).toBe(true)
    },
  )
})
