open Vitest

let contractsYaml = `
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
  - name: NftFactory
    events:
      - event: "SimpleNftCreated(string name, address contractAddress)"
`

let gravatar = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
let nftFactory = "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"

let chainYaml = (chainId, ~startBlock=1) =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: ${startBlock->Int.toString}
    contracts:
      - name: Gravatar
        address: "${gravatar}"
      - name: NftFactory
        address: "${nftFactory}"
`

let makeScenario = (~name, ~rollback=true, ~chains) =>
  Scenario.make(
    ~configYaml=`
name: ${name}
rollback_on_reorg: ${rollback ? "true" : "false"}${contractsYaml}chains:${chains}`,
    ~schema=`
type SimpleEntity {
  id: ID!
  value: String!
}
`,
  )

let scenario = makeScenario(~name="e2e", ~chains=chainYaml(1337))

// Partition ids and the chain's range-cost budget follow the contract set, so
// this scenario keeps the address-less contracts alongside the addressed ones.
let partitionScenario = Scenario.make(
  ~configYaml=`
name: e2e-partitions
rollback_on_reorg: true${contractsYaml}  - name: SimpleNft
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 tokenId)"
  - name: TestEvents
    events:
      - event: "IndexedUint(uint256 indexed num)"
chains:${chainYaml(1337)}      - name: SimpleNft
      - name: TestEvents
`,
  ~schema=`
type SimpleEntity {
  id: ID!
  value: String!
}
`,
)
let startBlock100Scenario = makeScenario(
  ~name="e2e-start-block",
  ~chains=chainYaml(1337, ~startBlock=100),
)
let multichainScenario = makeScenario(
  ~name="e2e-multichain",
  ~chains=chainYaml(100) ++ chainYaml(1337),
)
let noRollbackMultichainScenario = makeScenario(
  ~name="e2e-multichain-no-rollback",
  ~rollback=false,
  ~chains=chainYaml(100) ++ chainYaml(1337),
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

type simpleEntity = {id: string, value: string}
type simpleEntityOps = {set: simpleEntity => unit}
type handlerContext = {
  @as("SimpleEntity") simpleEntity: simpleEntityOps,
  effect: 'input 'output. (Envio.effect<'input, 'output>, 'input) => promise<'output>,
}

type contractOps = {add: Address.t => unit}
type registerChain = {@as("Gravatar") gravatar: contractOps}
type registerContext = {chain: registerChain}

let asContext = (context: Internal.handlerContext) =>
  context->(Utils.magic: Internal.handlerContext => handlerContext)

let asRegisterContext = (context: Internal.contractRegisterContext) =>
  context->(Utils.magic: Internal.contractRegisterContext => registerContext)

describe("E2E tests", () => {
  let getChainAddresses = async (indexer: IndexerRunner.t, ~chainId) => {
    let addresses = await indexer.queryAddresses()
    addresses
    ->Array.filter(a => a.chainId === chainId)
    ->Array.map(a => (a.address->Address.toString, a.contractName, a.registrationBlock))
  }

  scenario->Scenario.it(
    "Populates config addresses on init and preserves them across restart",
    ~sources=[{chain: 1337, methods: []}],
    async (~t, ~indexer, ~source) => {
      let _sourceMock = source(1337)
      let expected = [
        ("0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3", "Gravatar", -1),
        ("0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC", "NftFactory", -1),
      ]

      t.expect(
        await getChainAddresses(indexer, ~chainId=1337->ChainId.fromInt),
        ~message="Config addresses should be inserted with registrationBlock=-1 on init",
      ).toEqual(expected)

      let restarted = await indexer.restart()

      t.expect(
        await getChainAddresses(restarted, ~chainId=1337->ChainId.fromInt),
        ~message="Config addresses should survive restart from DB",
      ).toEqual(expected)
    },
  )

  startBlock100Scenario->Scenario.it(
    "Currectly starts indexing from a non-zero start block",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
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
    },
  )

  scenario->Scenario.it("Correctly sets Prom metrics", ~sources=[{chain: 1337, methods}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let sourceMock = source(1337)
    await Utils.delay(0)

    t.expect(await indexer.metric("envio_reorg_threshold")).toEqual([
      {value: "0", labels: Dict.make()},
    ])
    t.expect(await indexer.metric("hyperindex_synced_to_head")).toEqual([
      {value: "0", labels: Dict.make()},
    ])

    await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

    t.expect(await indexer.metric("envio_reorg_threshold")).toEqual([
      {value: "1", labels: Dict.make()},
    ])
    t.expect(await indexer.metric("hyperindex_synced_to_head")).toEqual([
      {value: "0", labels: Dict.make()},
    ])

    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
    await indexer.getBatchWritePromise()

    t.expect(
      await indexer.metric("hyperindex_synced_to_head"),
      ~message="should have set hyperindex_synced_to_head metric to 1",
    ).toEqual([{value: "1", labels: Dict.make()}])
  })

  multichainScenario->Scenario.it(
    "Prom readiness metrics are gated on the whole indexer",
    ~sources=[{chain: 1337, methods}, {chain: 100, methods}],
    ~retry=3,
    async (~t, ~indexer, ~source) => {
      let sourceMock1337 = source(1337)
      let sourceMock100 = source(100)
      await Utils.delay(0)

      // Enter reorg threshold for both chains
      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock1337),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock100),
      ))

      // Only the most-behind chain (100 — the progress tie breaks by ascending
      // chain id) gets the follow-up query; chain 1337 sits the round out until
      // the leader's reservation releases. Advance chain 100 to head first.
      sourceMock100.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()

      // No chain is marked ready until every chain catches up
      t.expect(
        await indexer.metric("envio_progress_ready"),
        ~message="No chain is ready while chain 1337 is still syncing",
      ).toEqual([
        {value: "0", labels: Dict.fromArray([("chainId", "100")])},
        {value: "0", labels: Dict.fromArray([("chainId", "1337")])},
      ])
      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
        ~message="All-ready metric should not be set since chain 1337 is not ready",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Now advance chain 1337 to head
      sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()

      // Both chains should now be ready
      t.expect(
        await indexer.metric("envio_progress_ready"),
        ~message="Both chains should be ready",
      ).toEqual([
        {value: "1", labels: Dict.fromArray([("chainId", "100")])},
        {value: "1", labels: Dict.fromArray([("chainId", "1337")])},
      ])
      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
        ~message="All-ready metric should be set when both chains are ready",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )

  let contextAfterResolveErrors = []
  scenario->Scenario.it(
    "Shouldn't allow context access after hander is resolved",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(300)
      sourceMock.resolveGetItemsOrThrow([
        {
          blockNumber: 10,
          logIndex: 0,
          contractRegister: async args => {
            let context = args.context->asRegisterContext
            let _ = setTimeout(
              () => {
                try {
                  context.chain.gravatar.add(
                    "0x1234567890123456789012345678901234567890"->Address.Evm.fromStringOrThrow,
                  )
                } catch {
                | exn => contextAfterResolveErrors->Array.push(exn->Utils.prettifyExn)
                }
              },
              0,
            )
          },
          handler: async args => {
            let context = args.context->asContext
            let _ = setTimeout(
              () => {
                try {
                  context.simpleEntity.set({
                    id: "1",
                    value: "value-1",
                  })
                } catch {
                | exn => contextAfterResolveErrors->Array.push(exn->Utils.prettifyExn)
                }
              },
              1,
            )
          },
        },
        {
          blockNumber: 11,
          logIndex: 0,
          handler: async args => {
            let context = args.context->asContext
            context.simpleEntity.set({
              id: "1",
              value: "value-2",
            })
            // Wait to see what will happen when timeout finishes during the batch
            await Utils.delay(1)
          },
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(await (indexer.query("SimpleEntity"): promise<array<simpleEntity>>)).toEqual([
        {id: "1", value: "value-2"},
      ])
      t.expect(
        contextAfterResolveErrors,
        ~message="should have an error thrown during set",
      ).toEqual([
        Utils.Error.make(`Impossible to access context.chain after the contract register is resolved. Make sure you didn't miss an await in the handler.`)->Utils.prettifyExn,
        Utils.Error.make(`Impossible to access context.SimpleEntity after the handler is resolved. Make sure you didn't miss an await in the handler.`)->Utils.prettifyExn,
      ])
    },
  )

  scenario->Scenario.it("Track effects in prom metrics", ~sources=[{chain: 1337, methods}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let sourceMock = source(1337)
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
      await indexer.metric("envio_effect_call_total"),
      ~message="should have no effect calls in the beginning",
    ).toEqual([])
    t.expect(
      await indexer.metric("envio_effect_cache"),
      ~message="should have no effect cache in the beginning",
    ).toEqual([])

    sourceMock.resolveGetHeightOrThrow(300)
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 100,
          logIndex: 0,
          handler: async args => {
            let context = args.context->asContext
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
    await indexer.getBatchWritePromise()

    t.expect(
      await indexer.metric("envio_effect_call_total"),
      ~message="should increment effect calls count",
    ).toEqual([
      {
        value: "1",
        labels: Dict.fromArray([("effect", "testEffect"), ("scope", "crossChain")]),
      },
      {
        value: "2",
        labels: Dict.fromArray([("effect", "testEffectWithCache"), ("scope", "crossChain")]),
      },
    ])
    t.expect(
      await indexer.metric("envio_effect_cache"),
      ~message="should increment effect cache count",
    ).toEqual([
      {
        value: "2",
        labels: Dict.fromArray([("effect", "testEffectWithCache"), ("scope", "crossChain")]),
      },
    ])
    t.expect(
      await indexer.metric("envio_storage_load_total"),
      ~message="Shouldn't load anything from storage at this point",
    ).toEqual([])
    t.expect(
      await indexer.queryEffectCache(testEffectWithCache, ~scope=CrossChain),
      ~message="should have the cache entries in db",
    ).toEqual([
      {"id": `"test"`, "output": %raw(`"test-output"`)},
      {"id": `"test-2"`, "output": %raw(`"test-2-output"`)},
    ])

    let restarted = await indexer.restart()
    await Utils.delay(0)

    t.expect(
      await restarted.metric("envio_effect_call_total"),
      ~message="Should reset the calls metric on restart",
    ).toEqual([])
    t.expect(
      await restarted.metric("envio_effect_cache"),
      ~message="should resume effect cache count on restart",
    ).toEqual([
      {
        value: "2",
        labels: Dict.fromArray([("effect", "testEffectWithCache"), ("scope", "crossChain")]),
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
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 101,
          logIndex: 0,
          handler: async args => {
            let context = args.context->asContext
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
    await restarted.getBatchWritePromise()

    t.expect(
      await Promise.all3((
        restarted.metric("envio_storage_load_where_size"),
        restarted.metric("envio_storage_load_size"),
        restarted.metric("envio_storage_load_total"),
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
        restarted.metric("envio_effect_call_total"),
        restarted.metric("envio_effect_cache"),
      )),
      ~message="Should recompute the invalidated entry and keep the cache count",
    ).toEqual((
      [
        {
          value: "1",
          labels: Dict.fromArray([("effect", "testEffectWithCache"), ("scope", "crossChain")]),
        },
      ],
      [
        {
          value: "2",
          labels: Dict.fromArray([("effect", "testEffectWithCache"), ("scope", "crossChain")]),
        },
      ],
    ))

    // Sorted: rows come back in whatever order the storage holds them, which
    // differs once one of the two has been rewritten.
    t.expect(
      (await restarted.queryEffectCache(testEffectWithCache, ~scope=CrossChain))->Array.toSorted(
        (a, b) => String.compare(a["id"], b["id"]),
      ),
      ~message="Should invalidate loaded cache and store new one",
    ).toEqual([
      {"id": `"test"`, "output": %raw(`"test-output-v2"`)},
      {"id": `"test-2"`, "output": %raw(`"test-2-output"`)},
    ])
  })

  // Reproduction for https://github.com/enviodev/hyperindex/issues/1173
  // The effect context's `log` getter is compiled as an arrow function, so
  // `this` is captured from the surrounding ESM module scope (undefined under
  // strict mode) instead of the EffectContext instance. The lookup
  // `paramsByThis.get(undefined)` returns undefined, and accessing `.item`
  // throws `TypeError: Cannot read properties of undefined (reading 'item')`.
  scenario->Scenario.it(
    "context.log should be accessible from inside an effect handler",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
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
            handler: async args => {
              let context = args.context->asContext
              switch await context.effect(probeEffect, "test") {
              | output => effectResult := Some(output)
              | exception exn => effectError := Some(exn)
              }
            },
          },
        ],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        (effectError.contents, effectResult.contents),
        ~message="context.log access from inside an effect must not throw",
      ).toEqual((None, Some("test-output")))
    },
  )

  scenario->Scenario.it(
    "Chain-scoped effects expose context.chain.id, persist per chain, and reject cross-chain nesting",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)

      let chainScopedEffect = Envio.createEffect(
        {
          name: "chainScopedE2E",
          input: S.string,
          output: S.int,
          rateLimit: Disable,
          cache: true,
          crossChain: false,
        },
        async ({context}) => context.chain.id,
      )
      let crossChainEffect = Envio.createEffect(
        {
          name: "crossChainE2E",
          input: S.string,
          output: S.string,
          rateLimit: Disable,
        },
        // Reading context.chain on a cross-chain effect must throw before this
        // ever returns.
        async ({context}) => "chain-" ++ context.chain.id->Int.toString,
      )
      let crossChainParent = Envio.createEffect(
        {
          name: "crossChainParentE2E",
          input: S.string,
          output: S.int,
          rateLimit: Disable,
        },
        async ({context}) => await context.effect(chainScopedEffect, "nested"),
      )

      sourceMock.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      let msgOf = exn =>
        switch exn {
        | JsExn(e) => e->JsExn.message->Option.getOr("")
        | _ => ""
        }

      let chainId = ref(None)
      let crossChainAccessError = ref("")
      let nestedError = ref("")
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 100,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              chainId := Some(await context.effect(chainScopedEffect, "a"))
              crossChainAccessError :=
                switch await context.effect(crossChainEffect, "b") {
                | _ => ""
                | exception exn => msgOf(exn)
                }

              nestedError :=
                switch await context.effect(crossChainParent, "c") {
                | _ => ""
                | exception exn => msgOf(exn)
                }
            },
          },
        ],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()

      t.expect((chainId.contents, crossChainAccessError.contents, nestedError.contents)).toEqual((
        Some(1337),
        "context.chain is not available on the cross-chain effect \"crossChainE2E\". Set `crossChain: false` in its options to scope the effect to a single chain, then read context.chain.id.",
        "The cross-chain effect \"crossChainParentE2E\" cannot call the chain-scoped effect \"chainScopedE2E\", because a cross-chain effect isn't tied to a single chain. Make \"chainScopedE2E\" cross-chain (`crossChain: true`), or make \"crossChainParentE2E\" chain-scoped (`crossChain: false`).",
      ))

      // The chain-scoped output landed in the per-chain cache table, not the
      // flat cross-chain one.
      t.expect((
        await indexer.queryEffectCache(chainScopedEffect, ~scope=Chain(1337->ChainId.fromInt)),
        await indexer.metric("envio_effect_cache"),
      )).toEqual((
        [{"id": `"a"`, "output": %raw(`1337`)}],
        [
          {
            value: "1",
            labels: Dict.fromArray([("effect", "chainScopedE2E"), ("scope", "1337")]),
          },
        ],
      ))
    },
  )

  scenario->Scenario.it(
    "Should attempt fallback source when primary source fails with missing params",
    ~sources=[{chain: 1337, methods}, {chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMockPrimary = source(1337)
      let sourceMockFallback = source(1337, ~index=1)
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

      await indexer.getBatchWritePromise()

      t.expect(
        (
          sourceMockPrimary.getItemsOrThrowCalls->Array.length,
          sourceMockFallback.getItemsOrThrowCalls->Array.length,
        ),
        ~message="Should keep using fallback source for the next query after ImpossibleForTheQuery",
      ).toEqual((0, 1))
    },
  )

  scenario->Scenario.it(
    "Effect rate limiting across multiple windows",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
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
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 100,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
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
                indexer.metric("envio_effect_queue"),
                indexer.metric("envio_effect_active_calls"),
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

      await indexer.getBatchWritePromise()

      // All effects should complete successfully - verify via calls count metric
      t.expect(
        await indexer.metric("envio_effect_call_total"),
        ~message="should have called effect 6 times total",
      ).toEqual([
        {
          value: "6",
          labels: Dict.fromArray([("effect", "testEffectMultiWindow"), ("scope", "crossChain")]),
        },
      ])

      // Check that we captured metrics during execution
      // With 2 calls per window and 6 total calls: 4 items queued, max 2 active
      t.expect(
        queueMetricDuringExecution.contents->Option.getOrThrow,
        ~message="queue should have 4 items during execution",
      ).toEqual([
        {
          value: "4",
          labels: Dict.fromArray([("effect", "testEffectMultiWindow"), ("scope", "crossChain")]),
        },
      ])
      t.expect(
        activeMetricDuringExecution.contents->Option.getOrThrow,
        ~message="active calls should be at rate limit (2)",
      ).toEqual([
        {
          value: "2",
          labels: Dict.fromArray([("effect", "testEffectMultiWindow"), ("scope", "crossChain")]),
        },
      ])

      // Final check - queue should be empty
      t.expect(
        await indexer.metric("envio_effect_queue"),
        ~message="queue should be empty after all windows complete",
      ).toEqual([
        {
          value: "0",
          labels: Dict.fromArray([("effect", "testEffectMultiWindow"), ("scope", "crossChain")]),
        },
      ])
    },
  )

  scenario->Scenario.it(
    "Effect rate limiting with single call per window",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
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

      // Single batch with 4 calls that will be rate limited
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 100,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              let resultsPromise = Promise.all([
                context.effect(testEffectNested, "call-1"),
                context.effect(testEffectNested, "call-2"),
                context.effect(testEffectNested, "call-3"),
                context.effect(testEffectNested, "call-4"),
              ])

              // Check metrics while effects are executing (shortly after trigger)
              await Utils.delay(3)
              let (queueMetric1, activeMetric1) = await Promise.all2((
                indexer.metric("envio_effect_queue"),
                indexer.metric("envio_effect_active_calls"),
              ))
              queueMetricDuringExecution := Some(queueMetric1)
              activeMetricDuringExecution := Some(activeMetric1)

              // Check again after first window should complete
              await Utils.delay(14)
              queueMetricAfterFirstWindow := Some(await indexer.metric("envio_effect_queue"))

              let _ = await resultsPromise
            },
          },
        ],
        ~latestFetchedBlockNumber=100,
      )

      await indexer.getBatchWritePromise()

      // All 4 effects should complete successfully despite rate limiting
      t.expect(executionOrder->Array.length, ~message="should have executed all 4 calls").toEqual(4)

      // Verify via calls count metric
      t.expect(
        await indexer.metric("envio_effect_call_total"),
        ~message="should have called effect 4 times total",
      ).toEqual([
        {
          value: "4",
          labels: Dict.fromArray([("effect", "testEffectNested"), ("scope", "crossChain")]),
        },
      ])

      // Check that we captured metrics during execution
      // With 1 call per window and 4 total calls: 3 items queued, max 1 active
      t.expect(
        queueMetricDuringExecution.contents->Option.getOrThrow,
        ~message="queue should have 3 items during execution",
      ).toEqual([
        {
          value: "3",
          labels: Dict.fromArray([("effect", "testEffectNested"), ("scope", "crossChain")]),
        },
      ])
      t.expect(
        activeMetricDuringExecution.contents->Option.getOrThrow,
        ~message="active calls should be at rate limit (1)",
      ).toEqual([
        {
          value: "1",
          labels: Dict.fromArray([("effect", "testEffectNested"), ("scope", "crossChain")]),
        },
      ])

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
        await indexer.metric("envio_effect_queue"),
        ~message="queue should be empty after all batches complete",
      ).toEqual([
        {
          value: "0",
          labels: Dict.fromArray([("effect", "testEffectNested"), ("scope", "crossChain")]),
        },
      ])
    },
  )

  scenario->Scenario.it(
    "Effect cache can be disabled per-call via context.cache",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
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
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 100,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
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
      await indexer.getBatchWritePromise()

      t.expect(
        callCount.contents,
        ~message="Effect should be called 2 times (test1 once with cache=false, test2 once)",
      ).toEqual(2)

      t.expect(
        await indexer.queryEffectCache(testEffectWithCacheControl, ~scope=CrossChain),
        ~message="Should only have test2 in DB (test1 was called with cache=false and subsequent calls used in-memory cache)",
      ).toEqual([{"id": `"test2"`, "output": %raw(`"test2-output"`)}])
    },
  )

  scenario->Scenario.it(
    "Effect error in one call shouldn't cause other calls to fail",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
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
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 100,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
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
      await indexer.getBatchWritePromise()

      // Verify that only p2's successful result was cached
      t.expect(
        await indexer.queryEffectCache(throwingEffect, ~scope=CrossChain),
        ~message="Should only cache p2's successful result, not p1's failed call",
      ).toEqual([{"id": `"shouldn't-fail"`, "output": %raw(`"shouldn't-fail-output"`)}])
    },
  )

  scenario->Scenario.it(
    "Live source should not participate in initial height fetch but should after sync",
    ~sources=[
      {chain: 1337, methods, sourceFor: Source.Sync},
      {chain: 1337, methods, sourceFor: Source.Realtime},
    ],
    async (~t, ~indexer, ~source) => {
      let syncSource = source(1337)
      let liveSource = source(1337, ~index=1)
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
      await indexer.getBatchWritePromise()

      // After entering reorg threshold, continue fetching until we reach head (300)
      // The indexer will fetch in batches, we need to resolve each one
      syncSource.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=200)
      await indexer.getBatchWritePromise()

      syncSource.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()

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
      await indexer.getBatchWritePromise()

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

  scenario->Scenario.it(
    "Partition queries adjust ranges depending on responses",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)

      // Step 1: Resolve height (blockLag=200 by default, headBlock=19800)
      sourceMock.resolveGetHeightOrThrow(20_000)
      await Utils.delay(0)
      await Utils.delay(0)

      // Step 2: Query 1 — resolve at block 500 (range=501)
      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
        ~message="Step 2 should have initial query",
      ).toEqual([{"fromBlock": 1, "toBlock": Some(19800), "retry": 0, "p": "0"}])
      sourceMock.resolveGetItemsOrThrow(
        [{blockNumber: 100, logIndex: 0}],
        ~latestFetchedBlockNumber=500,
      )
      await indexer.getBatchWritePromise()

      // Step 3: Query 2 — resolve at block 800 (range=300)
      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
        ~message="Step 3 should have follow-up query",
      ).toEqual([{"fromBlock": 501, "toBlock": Some(19800), "retry": 0, "p": "0"}])
      sourceMock.resolveGetItemsOrThrow(
        [{blockNumber: 600, logIndex: 0}],
        ~latestFetchedBlockNumber=800,
      )
      await indexer.getBatchWritePromise()

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
      await indexer.getBatchWritePromise()
      // Drain the in-flight 540-chunk backlog so the partition regenerates its
      // tail at the grown chunkRange (540). New tail chunks reach ceil(540*1.8)=972.
      sourceMock.getItemsOrThrowCalls
      ->Array.copy
      ->Array.forEach(
        c =>
          c.resolve(
            [{blockNumber: c.payload["fromBlock"], logIndex: 0}],
            ~latestFetchedBlockNumber=c.payload["toBlock"]->Option.getOr(c.payload["fromBlock"]),
          ),
      )
      await indexer.getBatchWritePromise()

      // Assert: full-size responses grew the chunk size beyond the initial 540.
      let maxChunkSize = sourceMock.getItemsOrThrowCalls->Array.reduce(
        0,
        (max, c) =>
          switch c.payload["toBlock"] {
          | Some(tb) => Pervasives.max(max, tb - c.payload["fromBlock"] + 1)
          | None => max
          },
      )
      t.expect(
        maxChunkSize > 540,
        ~message="Tail chunks should have grown beyond the initial 540",
      ).toBe(true)

      // Phase B — chunks shrink on partial response:
      // Resolve the first pending chunk (at queue front) at a small partial range
      // (100 blocks) so the partition advances and the heuristic shrinks.
      let firstPending = sourceMock.getItemsOrThrowCalls->Array.get(0)->Option.getOrThrow
      firstPending.resolve(
        [{blockNumber: firstPending.payload["fromBlock"], logIndex: 0}],
        ~latestFetchedBlockNumber=firstPending.payload["fromBlock"] + 99,
      )
      await indexer.getBatchWritePromise()

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
    },
  )

  scenario->Scenario.it(
    "Items from later chunk wait for earlier chunk to complete",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)

      // Setup: same preamble — get to 4 chunked queries
      sourceMock.resolveGetHeightOrThrow(10_000)
      await Utils.delay(0)
      await Utils.delay(0)
      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
        ~message="Should have initial query",
      ).toEqual([{"fromBlock": 1, "toBlock": Some(9800), "retry": 0, "p": "0"}])
      sourceMock.resolveGetItemsOrThrow(
        [{blockNumber: 100, logIndex: 0}],
        ~latestFetchedBlockNumber=500,
      )
      await indexer.getBatchWritePromise()
      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
        ~message="Should have follow-up query",
      ).toEqual([{"fromBlock": 501, "toBlock": Some(9800), "retry": 0, "p": "0"}])
      sourceMock.resolveGetItemsOrThrow(
        [{blockNumber: 600, logIndex: 0}],
        ~latestFetchedBlockNumber=800,
      )
      await indexer.getBatchWritePromise()

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
          handler: async args => {
            let context = args.context->asContext
            context.simpleEntity.set({id: "item-2000", value: "from-chunk3"})
          },
        },
      ])
      // Wait for chunk3's response to be processed
      await Utils.delay(0)
      await Utils.delay(0)

      // Item at 2000 should NOT be in DB yet — earlier chunks haven't completed,
      // so bufferBlockNumber=800 and 2000 > 800 means it's not ready.
      t.expect(
        await (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
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
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "item-850", value: "from-chunk1"})
            },
          },
        ],
        ~latestFetchedBlockNumber=1340,
      )
      await indexer.getBatchWritePromise()

      // Only item-850 should be in DB — chunk2 hasn't completed,
      // so chunk3's item at 2000 is still beyond the buffer.
      t.expect(
        await (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
        ~message="Only item-850 should be in DB while chunk2 is pending",
      ).toEqual([{id: "item-850", value: "from-chunk1"}])

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
      await indexer.getBatchWritePromise()

      // Both items should now be in DB
      t.expect(
        await (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
        ~message="Both items should be in DB after chunk1 fully completes",
      ).toEqual([{id: "item-850", value: "from-chunk1"}, {id: "item-2000", value: "from-chunk3"}])
    },
  )

  partitionScenario->Scenario.it(
    "Partitions too far apart fetch separately, then merge once they are in range",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      // Queries described by the block they start at rather than by partition
      // id: the ids follow the contract set, the ranges follow the behaviour
      // under test.
      let pending = () =>
        sourceMock.getItemsOrThrowCalls
        ->Array.map(c => (c.payload["p"], c.payload["fromBlock"]))
        ->Array.toSorted(((_, a), (_, b)) => Int.compare(a, b))
      let partitionAt = fromBlock =>
        pending()
        ->Array.find(((_, from)) => from === fromBlock)
        ->Option.map(((p, _)) => p)
      let callAt = fromBlock =>
        sourceMock.getItemsOrThrowCalls
        ->Array.find(c => c.payload["fromBlock"] === fromBlock)
        ->Option.getOrThrow

      sourceMock.resolveGetHeightOrThrow(100_000)
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        pending(),
        ~message="one partition for the config addresses, querying to the reorg threshold",
      ).toEqual([("0", 1)])

      // Register DC1 at block 5000 and DC2 at block 25100. The 20100-block gap
      // exceeds tooFarBlockRange (20000), so they cannot share a partition. The
      // events at blocks 3000-3099 give the chain a density signal; without one
      // it is cold and its target block is capped, which would gate the far
      // partitions this choreography relies on fetching in parallel.
      sourceMock.resolveGetItemsOrThrow(
        [
          ...Array.fromInitializer(
            ~length=100,
            (i): MockSource.itemMock => {blockNumber: 3000 + i, logIndex: 0},
          ),
          {
            blockNumber: 5000,
            logIndex: 0,
            contractRegister: async args => {
              let context = args.context->asRegisterContext
              context.chain.gravatar.add(
                "0x1111111111111111111111111111111111111111"->Address.Evm.fromStringOrThrow,
              )
            },
          },
          {
            blockNumber: 25100,
            logIndex: 0,
            contractRegister: async args => {
              let context = args.context->asRegisterContext
              context.chain.gravatar.add(
                "0x2222222222222222222222222222222222222222"->Address.Evm.fromStringOrThrow,
              )
            },
          },
        ],
        ~latestFetchedBlockNumber=25100,
      )
      await indexer.getBatchWritePromise()

      let dc1Partition = partitionAt(5000)
      let dc2Partition = partitionAt(25100)
      t.expect(
        (
          pending()->Array.map(((_, from)) => from),
          dc1Partition != dc2Partition,
          dc1Partition->Option.isSome && dc2Partition->Option.isSome,
        ),
        ~message="each dynamic contract fetches from its own registration block, in its own partition",
      ).toEqual(([5000, 25100, 25101], true, true))

      // Advance DC2 a little. Its partition stays separate while DC1 is still
      // more than tooFarBlockRange behind it.
      callAt(25100).resolve([{blockNumber: 25200, logIndex: 0}], ~latestFetchedBlockNumber=25600)
      await Utils.delay(0)
      await Utils.delay(0)
      await Utils.delay(0)

      // DC1 catches up to block 12500. DC2's merge block is now within
      // tooFarBlockRange of it, so the two dynamic-contract partitions merge
      // into one that carries both addresses.
      callAt(5000).resolve([], ~latestFetchedBlockNumber=12500)
      await Scenario.waitUntil(
        () =>
          sourceMock.getItemsOrThrowCalls->Array.some(
            c => c.payload->MockSource.CallPayload.addresses->Array.length === 2,
          ),
        ~message="a partition holding both dynamic-contract addresses",
      )

      let merged =
        sourceMock.getItemsOrThrowCalls
        ->Array.filter(c => c.payload->MockSource.CallPayload.addresses->Array.length === 2)
        ->Array.map(c => c.payload["p"])
        ->Utils.Set.fromArray
        ->Utils.Set.toArray
      t.expect(
        (
          merged->Array.length,
          merged->Array.get(0) != dc1Partition,
          merged->Array.get(0) != dc2Partition,
        ),
        ~message="the merge produces a single new partition, not a reuse of either input",
      ).toEqual((1, true, true))
    },
  )

  multichainScenario->Scenario.it(
    "Multichain with reorg: staggered chain catch-up still enters reorg threshold",
    ~sources=[{chain: 1337, methods}, {chain: 100, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock1337 = source(1337)
      let sourceMock100 = source(100)
      await Utils.delay(0)

      // Chain 1337 catches up first
      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock1337)

      // System should NOT be in reorg threshold yet (chain 100 still backfilling)
      t.expect(
        await indexer.metric("envio_reorg_threshold"),
        ~message="Should not be in reorg threshold while chain 100 is still backfilling",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Now chain 100 catches up
      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock100)

      // System should now be in reorg threshold
      t.expect(
        await indexer.metric("envio_reorg_threshold"),
        ~message="Should be in reorg threshold after both chains caught up",
      ).toEqual([{value: "1", labels: Dict.make()}])

      // Chains are at block 100, need to advance to 300 after threshold entry.
      // Only the most-behind chain (100 — the progress tie breaks by ascending
      // chain id) holds a query; 1337 queries once the leader's budget releases.
      sourceMock100.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()

      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
        ~message="All chains should be synced to head after advancing to block 300",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )

  noRollbackMultichainScenario->Scenario.it(
    "Multichain without reorg: staggered chain catch-up reports readiness correctly",
    ~sources=[{chain: 1337, methods}, {chain: 100, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock1337 = source(1337)
      let sourceMock100 = source(100)
      await Utils.delay(0)

      // Without reorg, chains don't use blockLag so they fetch from startBlock to knownHeight
      // Chain 1337 catches up first
      t.expect(sourceMock1337.getHeightOrThrowCalls->Array.length).toEqual(1)
      sourceMock1337.resolveGetHeightOrThrow(300)

      sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()

      // No chain is marked ready until every chain catches up
      t.expect(
        await indexer.metric("envio_progress_ready"),
        ~message="No chain is ready while chain 100 is still syncing",
      ).toEqual([
        {value: "0", labels: Dict.fromArray([("chainId", "100")])},
        {value: "0", labels: Dict.fromArray([("chainId", "1337")])},
      ])
      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
        ~message="Not all chains synced yet",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Chain 100 catches up
      t.expect(sourceMock100.getHeightOrThrowCalls->Array.length).toEqual(1)
      sourceMock100.resolveGetHeightOrThrow(300)

      sourceMock100.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()

      // Both chains should now be ready
      t.expect(
        await indexer.metric("envio_progress_ready"),
        ~message="Both chains should be ready",
      ).toEqual([
        {value: "1", labels: Dict.fromArray([("chainId", "100")])},
        {value: "1", labels: Dict.fromArray([("chainId", "1337")])},
      ])
      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
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
  noRollbackMultichainScenario->Scenario.it(
    "Multichain realtime: a near-head chain keeps polling while another chain backfills a large range",
    ~sources=[{chain: 1337, methods}, {chain: 100, methods}],
    ~targetBufferSize=2000,
    async (~t, ~indexer, ~source) => {
      let leaderSource = source(1337)
      let followerSource = source(100)

      // Phase 1: both chains catch up to head (block 100) and become realtime.
      // A handful of events on each seeds a density signal.
      leaderSource.resolveGetHeightOrThrow(100)
      followerSource.resolveGetHeightOrThrow(100)

      leaderSource.resolveGetItemsOrThrow(
        [{blockNumber: 20, logIndex: 0}, {blockNumber: 60, logIndex: 0}],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()
      followerSource.resolveGetItemsOrThrow(
        [{blockNumber: 20, logIndex: 0}, {blockNumber: 60, logIndex: 0}],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
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
        await MockSource.waitItemsQuery(leaderSource)
        let call = leaderSource.getItemsOrThrowCalls->Array.getUnsafe(0)
        let fromBlock = call.payload["fromBlock"]
        call.resolve(
          [{blockNumber: fromBlock + 20, logIndex: 0}, {blockNumber: fromBlock + 60, logIndex: 0}],
          ~latestFetchedBlockNumber=fromBlock + 99,
        )
        await indexer.getBatchWritePromise()
      }

      // The follower is below its own head (frontier 100 < head 105). The
      // indexer is realtime, so the cross-chain alignment clamp is dropped:
      // instead of being starved behind the backfilling leader, the follower
      // fetches its small range to head...
      await MockSource.waitItemsQuery(followerSource)
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
