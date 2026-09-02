open Vitest

let contractsYaml = `
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
  - name: NftFactory
    events:
      - event: "SimpleNftCreated(string name, address contractAddress)"
  - name: SimpleNft
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 tokenId)"
`

let chainYaml = chainId =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
      - name: NftFactory
        address: "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
      - name: SimpleNft
`

let schema = `
type SimpleEntity {
  id: ID!
  value: String!
}

type EntityWithBigDecimal {
  id: ID!
  bigDecimal: BigDecimal!
}
`

// SimpleNft is the contract the dynamic-contract cases register addresses into.
// It needs a registration of its own, otherwise there is nothing to fetch for a
// newly registered address and no partition is created for it.
let handlers = `
import { indexer } from "envio";

indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, async () => {});
`

let makeScenario = (~name, ~chains, ~extra="") =>
  Scenario.make(
    ~configYaml=`
name: ${name}
rollback_on_reorg: true${extra}${contractsYaml}chains:${chains}`,
    ~schema,
    ~handlers,
  )

let scenario = makeScenario(~name="rollback", ~chains=chainYaml(1337))
let multichainScenario = makeScenario(
  ~name="rollback-multichain",
  ~chains=chainYaml(100) ++ chainYaml(1337),
)
let threeChainScenario = makeScenario(
  ~name="rollback-three-chain",
  ~chains=chainYaml(100) ++ chainYaml(137) ++ chainYaml(1337),
)
// One event per batch, so a reorg lands between two batches of the same range.
let batchSize1Scenario = makeScenario(
  ~name="rollback-batch-size-1",
  ~chains=chainYaml(100) ++ chainYaml(1337),
  ~extra="\nfull_batch_size: 1",
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

// Every case here pins `reorgThresholdReadyTolerance` to 0. The config default
// is 100, which pulls a chain into the reorg threshold 100 blocks early and so
// shifts which batches write checkpoints — these cases assert on checkpoint ids
// and history rows, so the boundary has to be the literal one.

type simpleEntity = {id: string, value: string}
type entityWithBigDecimal = {id: string, bigDecimal: BigDecimal.t}

type simpleEntityOps = {
  set: simpleEntity => unit,
  deleteUnsafe: string => unit,
}
type bigDecimalOps = {set: entityWithBigDecimal => unit}
type handlerContext = {
  @as("SimpleEntity") simpleEntity: simpleEntityOps,
  @as("EntityWithBigDecimal") entityWithBigDecimal: bigDecimalOps,
}

type contractOps = {add: Address.t => unit}
type registerChain = {@as("SimpleNft") simpleNft: contractOps}
type registerContext = {chain: registerChain}

type mockEventBlock = {number: int}
type mockEvent = {block: mockEventBlock, logIndex: int}

let asContext = (context: Internal.handlerContext) =>
  context->(Utils.magic: Internal.handlerContext => handlerContext)

let asRegisterContext = (context: Internal.contractRegisterContext) =>
  context->(Utils.magic: Internal.contractRegisterContext => registerContext)

// Query only dynamically registered addresses (exclude config addresses with registrationBlock=-1)
let queryDynamicAddresses = (indexer: IndexerRunner.t) =>
  indexer.queryAddresses()->Promise.thenResolve(rows =>
    rows->Array.filter(r => r.registrationBlock !== -1)
  )

describe("E2E rollback tests", () => {
  let testSingleChainRollback = async (
    ~t,
    ~sourceMock: MockSource.t,
    ~indexer: IndexerRunner.t,
    ~firstHistoryCheckpointId=2n,
    ~chainId=1337->ChainId.fromInt,
  ) => {
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
      ~message="Should enter reorg threshold and request now to the latest block",
    ).toEqual(
      Some({
        "fromBlock": 101,
        "toBlock": None,
        "retry": 0,
        "p": "0",
      }),
    )

    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 101,
          logIndex: 0,
          handler: async args => {
            let context = args.context->asContext
            // This shouldn't be written to the db at all
            // and deduped on the in-memory store level
            context.simpleEntity.set({
              id: "1",
              value: "value-1",
            })
            context.simpleEntity.set({
              id: "1",
              value: "value-2",
            })

            context.simpleEntity.set({
              id: "2",
              value: "value-1",
            })
          },
        },
        {
          blockNumber: 101,
          logIndex: 1,
          handler: async args => {
            let context = args.context->asContext
            // This should overwrite the previous value
            // set on log index 0. No history rows should be created
            // since they are per batch now.
            context.simpleEntity.set({
              id: "2",
              value: "value-2",
            })

            context.simpleEntity.set({
              id: "4",
              value: "value-1",
            })
          },
        },
        {
          blockNumber: 102,
          logIndex: 0,
          handler: async args => {
            let context = args.context->asContext
            // This should create a new history row
            context.simpleEntity.set({
              id: "3",
              value: "value-1",
            })

            // Test rollback of creating + deleting an entity
            context.simpleEntity.deleteUnsafe("4")
          },
        },
        {
          blockNumber: 103,
          logIndex: 0,
          handler: async args => {
            let context = args.context->asContext
            // This should be ignored, since it's after the latest fetch block
            // The case is invalid, but this is good
            context.simpleEntity.set({
              id: "3",
              value: "value-2",
            })
          },
        },
      ],
      ~latestFetchedBlockNumber=102,
    )

    await indexer.getBatchWritePromise()

    t.expect(
      await Promise.all3((
        indexer.queryCheckpoints(),
        (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
        (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>),
      )),
      ~message="Should have two entities in the db",
    ).toEqual((
      [
        {
          id: firstHistoryCheckpointId,
          blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0101")),
          blockNumber: 101,
          chainId,
          eventsProcessed: 2,
        },
        {
          id: firstHistoryCheckpointId->BigInt.add(1n),
          blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0102")),
          blockNumber: 102,
          chainId,
          eventsProcessed: 1,
        },
      ],
      [
        {
          id: "1",
          value: "value-2",
        },
        {
          id: "2",
          value: "value-2",
        },
        {
          id: "3",
          value: "value-1",
        },
      ],
      [
        Set({
          checkpointId: firstHistoryCheckpointId,
          entityId: "1"->EntityId.unsafeOfString,
          entity: {
            id: "1",
            value: "value-2",
          },
        }),
        Set({
          checkpointId: firstHistoryCheckpointId,
          entityId: "2"->EntityId.unsafeOfString,
          entity: {
            id: "2",
            value: "value-2",
          },
        }),
        Set({
          checkpointId: firstHistoryCheckpointId->BigInt.add(1n),
          entityId: "3"->EntityId.unsafeOfString,
          entity: {
            id: "3",
            value: "value-1",
          },
        }),
        Set({
          checkpointId: firstHistoryCheckpointId,
          entityId: "4"->EntityId.unsafeOfString,
          entity: {
            id: "4",
            value: "value-1",
          },
        }),
        Delete({
          checkpointId: firstHistoryCheckpointId->BigInt.add(1n),
          entityId: "4"->EntityId.unsafeOfString,
        }),
      ],
    ))

    t.expect(sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last).toEqual(
      Some({
        "fromBlock": 103,
        "toBlock": None,
        "retry": 0,
        "p": "0",
      }),
    )

    // Should trigger rollback
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 103,
          logIndex: 0,
          handler: async args => {
            let context = args.context->asContext
            // The value is not used, since we reset fetch state
            // for rollback
            context.simpleEntity.set({
              id: "3",
              value: "value-1",
            })
          },
        },
      ],
      ~prevRangeLastBlock={
        blockNumber: 102,
        blockHash: "0x102a",
      },
    )
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getBlockHashesCalls,
      ~message="Should have called getBlockHashes to find rollback depth",
    ).toEqual([[100, 101]])
    sourceMock.resolveGetBlockHashes([
      // The block 100 is untouched so we can rollback to it; 101 came back on a
      // different hash, so it belongs to the reorg.
      {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
      {blockNumber: 101, blockHash: "0x101a", blockTimestamp: 101},
    ])

    await indexer.getRollbackReadyPromise()

    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
      ~message="Should rollback fetch state",
    ).toEqual(
      Some({
        "fromBlock": 101,
        "toBlock": None,
        "retry": 0,
        // IDs reset on rollback, recreated partition starts at 0
        "p": "0",
      }),
    )
    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 101,
        logIndex: 1,
        handler: async args => {
          let context = args.context->asContext
          // From value-2 to value-1
          context.simpleEntity.set({
            id: "1",
            value: "value-1",
          })
          // The same value as before rollback
          context.simpleEntity.set({
            id: "2",
            value: "value-2",
          })
        },
      },
    ])

    await indexer.getBatchWritePromise()

    t.expect(
      await Promise.all3((
        indexer.queryCheckpoints(),
        (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
        (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>),
      )),
      ~message="Should correctly rollback entities",
    ).toEqual((
      [
        {
          id: firstHistoryCheckpointId->BigInt.add(3n),
          blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0101")),
          blockNumber: 101,
          chainId,
          eventsProcessed: 1,
        },
      ],
      [
        {
          id: "1",
          value: "value-1",
        },
        {
          id: "2",
          value: "value-2",
        },
      ],
      [
        Set({
          checkpointId: firstHistoryCheckpointId->BigInt.add(3n),
          entityId: "1"->EntityId.unsafeOfString,
          entity: {
            id: "1",
            value: "value-1",
          },
        }),
        Set({
          checkpointId: firstHistoryCheckpointId->BigInt.add(3n),
          entityId: "2"->EntityId.unsafeOfString,
          entity: {
            id: "2",
            value: "value-2",
          },
        }),
      ],
    ))
  }

  multichainScenario->Scenario.it(
    "Should stay in reorg threshold on restart when progress is past threshold",
    ~sources=[{chain: 100, methods, isWildcard: true}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock1337 = source(1337)
      let sourceMock100 = source(100)
      await Utils.delay(0)

      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock1337),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock100),
      ))

      // Only the most-behind chain (100 — the progress tie breaks by ascending
      // chain id) holds the post-threshold query; drive it to head first so the
      // budget releases and chain 1337 gets its own follow-up.
      t.expect(
        sourceMock100.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
        ~message="Should enter reorg threshold and request now to the latest block",
      ).toEqual(
        Some({
          "fromBlock": 101,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        }),
      )
      sourceMock100.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()

      t.expect(
        sourceMock1337.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
        ~message="Chain 1337 follows once the leader's budget releases",
      ).toEqual(
        Some({
          "fromBlock": 101,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        }),
      )
      sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=110)
      await indexer.getBatchWritePromise()

      t.expect(await indexer.metric("envio_reorg_threshold")).toEqual([
        {value: "1", labels: Dict.make()},
      ])

      let restarted = await indexer.restart()

      sourceMock1337.getHeightOrThrowCalls->Utils.Array.clearInPlace
      sourceMock100.getHeightOrThrowCalls->Utils.Array.clearInPlace

      // Allow async operations to settle
      await Utils.delay(0)
      await Utils.delay(0)
      await Utils.delay(0)

      // After restart, we should still be in reorg threshold because
      // progressBlockNumber (110) > sourceBlockNumber (300) - maxReorgDepth (200) = 100
      t.expect(await restarted.metric("envio_reorg_threshold")).toEqual([
        {value: "1", labels: Dict.make()},
      ])

      // After restart, both chains have knownHeight from sourceBlockNumber,
      // so they don't need to call getHeightOrThrow
      t.expect(
        sourceMock1337.getHeightOrThrowCalls->Array.length,
        ~message="should not call getHeightOrThrow on restart (uses sourceBlockNumber as knownHeight)",
      ).toEqual(0)

      // Both chains are ready immediately, so chain 1337 should continue fetching
      t.expect(
        sourceMock1337.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
        ~message="Should continue indexing from where we left off",
      ).toEqual(
        Some({
          "fromBlock": 111,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        }),
      )

      sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=200, ~knownHeight=320)

      await restarted.getBatchWritePromise()

      t.expect(
        sourceMock1337.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
        ~message="Continue normally inside of the reorg threshold",
      ).toEqual(
        Some({
          "fromBlock": 201,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        }),
      )

      t.expect(await restarted.metric("envio_reorg_threshold")).toEqual([
        {value: "1", labels: Dict.make()},
      ])
    },
  )

  scenario->Scenario.it(
    "Rollback of a single chain indexer",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)

      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)
      await testSingleChainRollback(~t, ~sourceMock, ~indexer)
    },
  )

  let resolveIndexerError = ref(None)
  let indexerErrorPromise = Promise.make((resolve, _reject) => {
    resolveIndexerError := Some(resolve)
  })

  scenario->Scenario.it(
    "Rolls back SET -> DELETE -> SET to the deleted state",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    ~onError=errHandler => {
      let resolve =
        resolveIndexerError.contents->Option.getOrThrow(
          ~message="Indexer error observer was not initialized",
        )
      resolve(errHandler)
    },
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 101,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "1", value: "before-delete"})
            },
          },
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.deleteUnsafe("1")
            },
          },
        ],
        ~latestFetchedBlockNumber=102,
      )
      await indexer.getBatchWritePromise()

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "1", value: "after-recreate"})
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await indexer.getBatchWritePromise()

      // getBatchWritePromise can observe the loop between the response resolving
      // and processing starting, so wait until this specific batch is visible.
      let shouldKeepWaitingForHistory = ref(true)
      let rec waitForRecreatedEntityHistory = async () => {
        if shouldKeepWaitingForHistory.contents {
          let hasRecreatedEntityHistory =
            (
              await (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>)
            )->Array.length === 3
          if shouldKeepWaitingForHistory.contents && !hasRecreatedEntityHistory {
            await Utils.delay(1)
            await waitForRecreatedEntityHistory()
          }
        }
      }
      let historyWaitTimeoutId = ref(None)
      let historyWaitTimeout = Promise.make((resolve, _reject) => {
        historyWaitTimeoutId := Some(setTimeout(resolve, 5_000))
      })
      let historyWaitResult = await Promise.race([
        waitForRecreatedEntityHistory()->Promise.thenResolve(_ => Ok()),
        indexerErrorPromise->Promise.thenResolve(errHandler => Error(Some(errHandler))),
        historyWaitTimeout->Promise.thenResolve(_ => Error(None)),
      ])
      shouldKeepWaitingForHistory := false
      historyWaitTimeoutId.contents->Option.forEach(clearTimeout)
      switch historyWaitResult {
      | Ok() => ()
      | Error(Some(errHandler)) => errHandler->ErrorHandling.raiseExn
      | Error(None) =>
        JsError.throwWithMessage("Timed out waiting for SET -> DELETE -> SET history")
      }

      t.expect(
        await Promise.all2((
          (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
          (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>),
        )),
        ~message="Should establish SET -> DELETE -> SET history before the rollback",
      ).toEqual((
        [{id: "1", value: "after-recreate"}],
        [
          Set({
            checkpointId: 2n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {id: "1", value: "before-delete"},
          }),
          Delete({checkpointId: 3n, entityId: "1"->EntityId.unsafeOfString}),
          Set({
            checkpointId: 4n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {id: "1", value: "after-recreate"},
          }),
        ],
      ))

      // Detect a reorg at block 103, then establish block 102 (the DELETE
      // checkpoint) as the latest valid block.
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(104),
        ~latestFetchedBlockNumber=104,
        ~prevRangeLastBlock={blockNumber: 103, blockHash: "0x0103ee"},
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="Should query the scanned blocks below the reorg",
      ).toEqual([[100, 101, 102]])
      sourceMock.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
        {blockNumber: 102, blockHash: "0x0102", blockTimestamp: 102},
      ])

      switch await Promise.race([
        indexer.getRollbackReadyPromise()->Promise.thenResolve(_ => Ok()),
        indexerErrorPromise->Promise.thenResolve(errHandler => Error(errHandler)),
      ]) {
      | Ok() => ()
      | Error(errHandler) => errHandler->ErrorHandling.raiseExn
      }

      // Commit the rollback diff without recreating the entity on the canonical chain.
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(103),
        ~latestFetchedBlockNumber=103,
        ~latestFetchedBlockHash="0x0103ee",
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
        ~message="The entity should remain deleted at the rollback target",
      ).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Parks a reorg detected while a batch is still processing",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      // Hold the block-101 batch open inside its handler so a reorg can be detected
      // while the batch is still in flight.
      let releaseHandler = ref(() => ())
      let handlerGate = Promise.make((resolve, _) => releaseHandler := (() => resolve()))

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 101,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "1", value: "from-reorged-block"})
              await handlerGate
            },
          },
        ],
        ~latestFetchedBlockNumber=101,
        ~latestFetchedBlockHash="0x0101",
      )

      // Wait until the processing loop has launched the next fetch — the batch is now
      // in flight, blocked in the handler above.
      while sourceMock.getItemsOrThrowCalls->Utils.Array.isEmpty {
        await Utils.delay(0)
      }

      // A reorg lands mid-batch: block 101 came back with a different hash.
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=102,
        ~prevRangeLastBlock={blockNumber: 101, blockHash: "0x101a"},
      )
      await Utils.delay(0)
      await Utils.delay(0)

      // The rollback starts finding its depth even though the batch hasn't finished.
      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="a reorg detected mid-batch should start finding the rollback depth",
      ).toEqual([[100]])
      sourceMock.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
      ])

      // Releasing the handler lets the batch finish; its progress is applied and the
      // parked rollback then executes and re-requests from the rolled-back block.
      releaseHandler.contents()
      await indexer.getRollbackReadyPromise()

      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
        ~message="after the parked rollback executes, the indexer re-requests from the valid block",
      ).toEqual(Some({"fromBlock": 101, "toBlock": None, "retry": 0, "p": "0"}))
    },
  )

  scenario->Scenario.it(
    "Fires onRollbackCommit per affected chain after the rollback write",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      // Registered inside the body: the listener is process-global, so a
      // registration at suite scope would also collect the rollbacks every
      // other case in this file fires.
      let rollbackCommitCalls = []
      let unregister = RollbackCommit.register(async (args: RollbackCommit.args) => {
        rollbackCommitCalls->Array.push(args)
      })

      let sourceMock = source(1337)
      await Utils.delay(0)

      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)
      await testSingleChainRollback(~t, ~sourceMock, ~indexer)
      unregister()

      t.expect(
        rollbackCommitCalls,
        ~message="Should fire once for the reorged chain with the last valid block",
      ).toEqual([{RollbackCommit.chainId: 1337->ChainId.fromInt, rollbackToBlock: 100}])
    },
  )

  scenario->Scenario.it(
    "Stores checkpoints inside of the reorg threshold for batches without items",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)

      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=102)

      await indexer.getBatchWritePromise()

      t.expect(
        await indexer.queryCheckpoints(),
        ~message="Should have added a checkpoint even though there are no items in the batch",
      ).toEqual([
        {
          id: 2n,
          eventsProcessed: 0,
          chainId: 1337->ChainId.fromInt,
          blockNumber: 102,
          blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0102")),
        },
      ])
    },
  )

  scenario->Scenario.it(
    "Shouldn't detect reorg for rollbacked block",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)

      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=102)
      await indexer.getBatchWritePromise()

      sourceMock.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=103,
        ~prevRangeLastBlock={
          blockNumber: 102,
          blockHash: "0x102a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100]])
      sourceMock.resolveGetBlockHashes([
        // The block 100 is untouched so we can rollback to it
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
      ])

      await indexer.getRollbackReadyPromise()
      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
        ~message="Should rollback fetch state and re-request items",
      ).toEqual([
        {
          "fromBlock": 101,
          "toBlock": None,
          "retry": 0,
          // IDs reset on rollback, recreated partition starts at 0
          "p": "0",
        },
      ])

      sourceMock.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=102,
        ~latestFetchedBlockHash="0x102a",
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await indexer.queryCheckpoints(),
        ~message="Should update the checkpoint without retriggering a reorg",
      ).toEqual([
        {
          id: 4n,
          eventsProcessed: 0,
          chainId: 1337->ChainId.fromInt,
          blockNumber: 102,
          blockHash: Js.Null.Value(MockSource.evmBlockHash("0x102a")),
        },
      ])
    },
  )

  multichainScenario->Scenario.it(
    "Single chain rollback should also work for multichain indexer when another chains are stale",
    ~sources=[{chain: 100, methods, isWildcard: true}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock1 = source(1337)
      let sourceMock2 = source(100)
      await Utils.delay(0)

      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock1),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock2),
      ))

      // The most-behind chain (100 — the progress tie breaks by ascending
      // chain id) holds the only post-threshold query, so the rollback runs on
      // it while chain 1337 sits without budget — genuinely stale.
      await testSingleChainRollback(
        ~t,
        ~sourceMock=sourceMock2,
        ~indexer,
        ~firstHistoryCheckpointId=3n,
        ~chainId=100->ChainId.fromInt,
      )
    },
  )

  scenario->Scenario.it(
    "Rollback Dynamic Contract",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)

      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      let calls = []
      let handler = async (args: Internal.handlerArgs) => {
        let event = args.event->(Utils.magic: Internal.event => mockEvent)
        calls->Array.push(event.block.number->Int.toString ++ "-" ++ event.logIndex->Int.toString)
      }

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 101,
            logIndex: 0,
            handler,
          },
          {
            blockNumber: 102,
            logIndex: 0,
            handler,
          },
          {
            blockNumber: 102,
            logIndex: 2,
            contractRegister: async args => {
              let context = args.context->asRegisterContext
              context.chain.simpleNft.add(
                Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0),
              )
            },
            handler,
          },
          {
            blockNumber: 103,
            logIndex: 2,
            contractRegister: async args => {
              let context = args.context->asRegisterContext
              context.chain.simpleNft.add(
                Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(1),
              )
            },
            handler,
          },
          {
            blockNumber: 104,
            logIndex: 2,
            contractRegister: async args => {
              let context = args.context->asRegisterContext
              context.chain.simpleNft.add(
                Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(2),
              )
            },
            handler,
          },
        ],
        ~latestFetchedBlockNumber=104,
      )

      await indexer.getBatchWritePromise()

      t.expect(
        (calls, sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)),
        ~message=`Creates a new partition for DCs and queries it in parallel with the original partition without blocking`,
      ).toEqual((
        ["101-0"],
        [
          {
            // New partition for DCs
            "fromBlock": 102,
            "toBlock": None,
            "retry": 0,
            "p": "1",
          },
          {
            // Continue fetching original partition
            // without blocking
            "fromBlock": 105,
            "toBlock": None,
            "retry": 0,
            "p": "0",
          },
        ],
      ))
      t.expect(
        await queryDynamicAddresses(indexer),
        ~message="Shouldn't store dynamic contracts at this point",
      ).toEqual([])

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 1,
            handler,
          },
        ],
        ~filter=MockSource.coveringBlock(102),
        ~latestFetchedBlockNumber=102,
      )
      await indexer.getBatchWritePromise()
      t.expect(
        (calls, sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)),
        ~message=`Should process the block 102 after DC partition finished fetching it`,
      ).toEqual((
        ["101-0", "102-0", "102-1", "102-2"],
        [
          {
            "fromBlock": 105,
            "toBlock": None,
            "retry": 0,
            "p": "0",
          },
          {
            "fromBlock": 103,
            "toBlock": None,
            "retry": 0,
            "p": "1",
          },
        ],
      ))
      t.expect(
        await queryDynamicAddresses(indexer),
        ~message="Added the processed dynamic contract to the db",
      ).toEqual([
        {
          IndexerRunner.address: Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0),
          chainId: 1337->ChainId.fromInt,
          registrationBlock: 102,
          contractName: "SimpleNft",
        },
      ])

      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(103),
        ~latestFetchedBlockNumber=103,
      )
      await indexer.getBatchWritePromise()
      t.expect(
        (await queryDynamicAddresses(indexer))->Array.length,
        ~message="Should add the processed dynamic contracts to the db",
      ).toEqual(2)

      // Should trigger rollback
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(104),
        ~prevRangeLastBlock={
          blockNumber: 103,
          blockHash: "0x103a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100, 101, 102]])
      sourceMock.resolveGetBlockHashes([
        // The block 102 is untouched so we can rollback to it
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
        {blockNumber: 102, blockHash: "0x0102", blockTimestamp: 102},
      ])

      sourceMock.drainItemsQueries()

      await indexer.getRollbackReadyPromise()

      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
        ~message="Should rollback fetch state and re-request items",
      ).toEqual([
        // Normal partition (recreated fresh, no chunking)
        {
          "fromBlock": 103,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        },
        // DC partition (recreated fresh, no chunking since chunk history lost)
        {
          "fromBlock": 103,
          "toBlock": None,
          "retry": 0,
          "p": "1",
        },
      ])

      // Asserted here rather than after the re-fetch below: the rollback is
      // resolved but nothing has been written yet, and how many ticks a write
      // takes is the storage's business, not this test's.
      t.expect(
        (await queryDynamicAddresses(indexer))->Array.length,
        ~message=`Nothing won't be rollbacked at this point. Since we need to process an event for this (rollback db only on batch write).
  This might be wrong after we start exposing a block hash for progress block.`,
      ).toEqual(2)

      // Both the base and the dynamic-contract partition are waiting at 103.
      sourceMock.drainItemsQueries(~latestFetchedBlockNumber=104)

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 104,
            logIndex: 0,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=104,
      )

      await indexer.getBatchWritePromise()

      t.expect(
        await queryDynamicAddresses(indexer),
        ~message="Should have only one dynamic contract in the db. The second one rollbacked from db, the third one rollbacked from fetch state",
      ).toEqual([
        {
          IndexerRunner.address: Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0),
          chainId: 1337->ChainId.fromInt,
          registrationBlock: 102,
          contractName: "SimpleNft",
        },
      ])
      // After the db rollback, both partitions continue from block 105 (no chunk history yet)
      let payloads = sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)
      t.expect(
        payloads->Array.map(p => (p["p"], p["fromBlock"], p["toBlock"])),
        ~message="Should correctly continue fetching from block 105 after rolling back the db",
      ).toEqual([("1", 105, None), ("0", 105, None)])
    },
  )

  multichainScenario->Scenario.it(
    "Rollback of multichain indexer (single entity id change)",
    ~sources=[{chain: 100, methods, isWildcard: true}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock1337 = source(1337)
      let sourceMock100 = source(100)
      await Utils.delay(0)

      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock1337),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock100),
      ))

      let callCount = ref(0)
      let getCallCount = () => {
        let count = callCount.contents
        callCount := count + 1
        count
      }

      // For this test only work with a single changing entity
      // with the same id. Use call counter to see how it's different to entity history order
      let handler = async (args: Internal.handlerArgs) => {
        let context = args.context->asContext
        context.simpleEntity.set({
          id: "1",
          value: `call-${getCallCount()->Int.toString}`,
        })
      }

      // The most-behind chain (100 — the progress tie breaks by ascending chain
      // id) holds the only post-threshold query; chain 1337's appears once the
      // leader's response releases the budget.
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await MockSource.waitItemsQuery(sourceMock1337)
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 1,
            handler,
          },
          {
            blockNumber: 103,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await indexer.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=106,
      )
      await indexer.getBatchWritePromise()
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=106,
      )
      await indexer.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 107,
            logIndex: 4,
            handler,
          },
        ],
        ~filter=MockSource.coveringBlock(107),
        ~latestFetchedBlockNumber=109,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await Promise.all3((
          indexer.queryCheckpoints(),
          (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
          (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>),
        )),
        ~message=`Should create history rows and checkpoints`,
      ).toEqual((
        [
          {
            id: 3n,
            eventsProcessed: 1,
            chainId: 100->ChainId.fromInt,
            blockNumber: 103,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0103")),
          },
          {
            id: 4n,
            eventsProcessed: 2,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 103,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0103")),
          },
          {
            id: 5n,
            eventsProcessed: 1,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 106,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0106")),
          },
          {
            id: 6n,
            eventsProcessed: 1,
            chainId: 100->ChainId.fromInt,
            blockNumber: 106,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0106")),
          },
          {
            id: 7n,
            eventsProcessed: 1,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 107,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0107")),
          },
          // Block 108 is skipped, since we don't have
          // ether events processed or block hash for it
          {
            id: 8n,
            eventsProcessed: 0,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 109,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0109")),
          },
        ],
        [
          {
            id: "1",
            value: "call-5",
          },
        ],
        [
          Set({
            checkpointId: 3n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-0",
            },
          }),
          Set({
            checkpointId: 4n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-2",
            },
          }),
          Set({
            checkpointId: 5n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-3",
            },
          }),
          Set({
            checkpointId: 6n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-4",
            },
          }),
          Set({
            checkpointId: 7n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-5",
            },
          }),
        ],
      ))

      t.expect(
        {
          let metrics = await indexer.metric("envio_progress_events")
          // For some reason the test returns the metrics in different order
          metrics->Array.toSorted(
            (a, b) =>
              Int.compare(
                a.value->Int.fromString->Option.getOr(0),
                b.value->Int.fromString->Option.getOr(0),
              ),
          )
        },
        ~message="Events count before rollback",
      ).toEqual([
        {value: "2", labels: Dict.fromArray([("chainId", "100")])},
        {value: "4", labels: Dict.fromArray([("chainId", "1337")])},
      ])
      t.expect(
        {
          let metrics = await indexer.metric("envio_progress_block")
          // For some reason the test returns the metrics in different order
          metrics->Array.toSorted(
            (a, b) =>
              Int.compare(
                a.value->Int.fromString->Option.getOr(0),
                b.value->Int.fromString->Option.getOr(0),
              ),
          )
        },
        ~message="Progress block number before rollback",
      ).toEqual([
        {value: "106", labels: Dict.fromArray([("chainId", "100")])},
        {value: "109", labels: Dict.fromArray([("chainId", "1337")])},
      ])
      t.expect(
        await indexer.metric("envio_rollback_events"),
        ~message="Rollbacked events count before rollback",
      ).toEqual([{value: "0", labels: Dict.make()}])
      t.expect(
        await indexer.metric("envio_rollback_total"),
        ~message="Rollbacks count before rollback",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Should trigger rollback
      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(110),
        ~prevRangeLastBlock={
          blockNumber: 106,
          blockHash: "0x106a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock1337.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100, 103]])
      sourceMock1337.resolveGetBlockHashes([
        // The block 103 is untouched so we can rollback to it
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 103, blockHash: "0x0103", blockTimestamp: 103},
      ])

      // Clean up pending calls from before rollback
      sourceMock100.drainItemsQueries()
      sourceMock1337.drainItemsQueries()

      await indexer.getRollbackReadyPromise()

      t.expect(
        await indexer.metric("envio_progress_events"),
        ~message="Events count after rollback",
      ).toEqual([
        {value: "1", labels: Dict.fromArray([("chainId", "100")])},
        {value: "2", labels: Dict.fromArray([("chainId", "1337")])},
      ])
      t.expect(
        await indexer.metric("envio_progress_block"),
        ~message="Progress block number after rollback",
      ).toEqual([
        {value: "105", labels: Dict.fromArray([("chainId", "100")])},
        {value: "105", labels: Dict.fromArray([("chainId", "1337")])},
      ])
      t.expect(
        await indexer.metric("envio_rollback_events"),
        ~message="Rollbacked events count after rollback",
      ).toEqual([{value: "3", labels: Dict.make()}])
      t.expect(
        await indexer.metric("envio_rollback_total"),
        ~message="Rollbacks count after rollback",
      ).toEqual([{value: "1", labels: Dict.make()}])

      t.expect(
        (
          sourceMock100.getItemsOrThrowCalls->Array.map(c => c.payload),
          sourceMock1337.getItemsOrThrowCalls->Array.map(c => c.payload),
        ),
        ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
      ).toEqual((
        // Chain 100: partition KEPT (lfb <= target), chunk history preserved.
        // chunkRange=3 -> chunkSize=ceil(3*1.8)=6, tiled uniformly from 106 up to
        // the per-partition cap of 12 chunks.
        [
          {"fromBlock": 106, "toBlock": Some(111), "retry": 0, "p": "0"},
          {"fromBlock": 112, "toBlock": Some(117), "retry": 0, "p": "0"},
          {"fromBlock": 118, "toBlock": Some(123), "retry": 0, "p": "0"},
          {"fromBlock": 124, "toBlock": Some(129), "retry": 0, "p": "0"},
          {"fromBlock": 130, "toBlock": Some(135), "retry": 0, "p": "0"},
          {"fromBlock": 136, "toBlock": Some(141), "retry": 0, "p": "0"},
          {"fromBlock": 142, "toBlock": Some(147), "retry": 0, "p": "0"},
          {"fromBlock": 148, "toBlock": Some(153), "retry": 0, "p": "0"},
          {"fromBlock": 154, "toBlock": Some(159), "retry": 0, "p": "0"},
          {"fromBlock": 160, "toBlock": Some(165), "retry": 0, "p": "0"},
          {"fromBlock": 166, "toBlock": Some(171), "retry": 0, "p": "0"},
          {"fromBlock": 172, "toBlock": Some(177), "retry": 0, "p": "0"},
        ],
        // Chain 1337: partition DELETED (lfb > target), recreated fresh
        [
          {
            "fromBlock": 106,
            "toBlock": None,
            "retry": 0,
            "p": "0",
          },
        ],
      ))

      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({
                id: "1",
                value: `should-be-ignored-by-filter`,
              })
            },
          },
          {
            blockNumber: 106,
            logIndex: 2,
            handler: async args => {
              let context = args.context->asContext
              // Set the same value as before rollback
              context.simpleEntity.set({
                id: "1",
                value: `call-4`,
              })
            },
          },
        ],
        ~filter=MockSource.coveringBlock(106),
      )

      await indexer.getBatchWritePromise()

      t.expect(
        await Promise.all3((
          indexer.queryCheckpoints(),
          (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
          (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>),
        )),
      ).toEqual((
        [
          {
            id: 3n,
            eventsProcessed: 1,
            chainId: 100->ChainId.fromInt,
            blockNumber: 103,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0103")),
          },
          {
            id: 4n,
            eventsProcessed: 2,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 103,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0103")),
          },
          // Reorg checkpoint id was checkpoint id 5
          // for chain 1337. After rollback it was removed
          // and replaced with chain id 100.
          {
            id: 10n,
            eventsProcessed: 2,
            chainId: 100->ChainId.fromInt,
            blockNumber: 106,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0106")),
          },
          {
            id: 11n,
            eventsProcessed: 0,
            chainId: 100->ChainId.fromInt,
            blockNumber: 111,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0111")),
          },
        ],
        [
          {
            id: "1",
            value: "call-4",
          },
        ],
        [
          Set({
            checkpointId: 3n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-0",
            },
          }),
          Set({
            checkpointId: 4n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-2",
            },
          }),
          Set({
            checkpointId: 10n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-4",
            },
          }),
        ],
      ))
    },
  )

  // Fixes duplicate history bug before 2.31
  multichainScenario->Scenario.it(
    "Rollback of multichain indexer (single entity id change + another entity on non-reorg chain)",
    ~sources=[{chain: 100, methods, isWildcard: true}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock1337 = source(1337)
      let sourceMock100 = source(100)
      await Utils.delay(0)

      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock1337),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock100),
      ))

      let callCount = ref(0)
      let getCallCount = () => {
        let count = callCount.contents
        callCount := count + 1
        count
      }

      // For this test only work with a single changing entity
      // with the same id. Use call counter to see how it's different to entity history order
      let handler = async (args: Internal.handlerArgs) => {
        let context = args.context->asContext
        context.simpleEntity.set({
          id: "1",
          value: `call-${getCallCount()->Int.toString}`,
        })
      }

      // The most-behind chain (100 — the progress tie breaks by ascending
      // chain id) holds the only post-threshold query; chain 1337's appears
      // once the leader's response releases the budget.
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 2,
            handler,
          },
        ],
        ~filter=MockSource.coveringBlock(106),
        ~latestFetchedBlockNumber=103,
      )
      await MockSource.waitItemsQuery(sourceMock1337)
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 1,
            handler,
          },
          {
            blockNumber: 103,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await indexer.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=106,
      )
      await indexer.getBatchWritePromise()
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 2,
            handler,
          },
          {
            blockNumber: 106,
            logIndex: 3,
            handler: async args => {
              let context = args.context->asContext
              context.entityWithBigDecimal.set({
                id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              })
            },
          },
        ],
        ~filter=MockSource.coveringBlock(106),
        ~latestFetchedBlockNumber=106,
      )
      await indexer.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 107,
            logIndex: 4,
            handler,
          },
        ],
        ~filter=MockSource.coveringBlock(107),
        ~latestFetchedBlockNumber=109,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await Promise.all3((
          indexer.queryCheckpoints(),
          (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
          (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>),
        )),
        ~message=`Should create history rows and checkpoints`,
      ).toEqual((
        [
          {
            id: 3n,
            eventsProcessed: 1,
            chainId: 100->ChainId.fromInt,
            blockNumber: 103,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0103")),
          },
          {
            id: 4n,
            eventsProcessed: 2,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 103,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0103")),
          },
          {
            id: 5n,
            eventsProcessed: 1,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 106,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0106")),
          },
          {
            id: 6n,
            eventsProcessed: 2,
            chainId: 100->ChainId.fromInt,
            blockNumber: 106,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0106")),
          },
          {
            id: 7n,
            eventsProcessed: 1,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 107,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0107")),
          },
          // Block 108 is skipped, since we don't have
          // ether events processed or block hash for it
          {
            id: 8n,
            eventsProcessed: 0,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 109,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0109")),
          },
        ],
        [
          {
            id: "1",
            value: "call-5",
          },
        ],
        [
          Set({
            checkpointId: 3n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-0",
            },
          }),
          Set({
            checkpointId: 4n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-2",
            },
          }),
          Set({
            checkpointId: 5n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-3",
            },
          }),
          Set({
            checkpointId: 6n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-4",
            },
          }),
          Set({
            checkpointId: 7n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-5",
            },
          }),
        ],
      ))
      t.expect(
        await Promise.all2((
          (indexer.query("EntityWithBigDecimal"): promise<array<entityWithBigDecimal>>),
          (
            indexer.queryHistory("EntityWithBigDecimal"): promise<
              array<Change.t<entityWithBigDecimal>>,
            >
          ),
        )),
        ~message="Should also add another entity for a non-reorg chain, which should also be rollbacked",
      ).toEqual((
        [
          {
            id: "foo",
            bigDecimal: BigDecimal.fromFloat(0.),
          },
        ],
        [
          Set({
            checkpointId: 6n,
            entityId: "foo"->EntityId.unsafeOfString,
            entity: {
              id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            },
          }),
        ],
      ))

      // Should trigger rollback
      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(110),
        ~prevRangeLastBlock={
          blockNumber: 106,
          blockHash: "0x106a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock1337.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100, 103]])
      sourceMock1337.resolveGetBlockHashes([
        // The block 103 is untouched so we can rollback to it
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 103, blockHash: "0x0103", blockTimestamp: 103},
      ])

      // Clean up pending calls from before rollback
      sourceMock100.drainItemsQueries()
      sourceMock1337.drainItemsQueries()

      await indexer.getRollbackReadyPromise()

      t.expect(
        (
          sourceMock1337.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.first,
          sourceMock100.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.first,
        ),
        ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
      ).toEqual((
        // Chain 1337: partition DELETED, recreated fresh (no chunking)
        Some({
          "fromBlock": 106,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        }),
        // Chain 100: partition KEPT, chunk history preserved.
        // chunkRange=3 -> chunkSize=6, first uniform chunk is 106-111.
        Some({
          "fromBlock": 106,
          "toBlock": Some(111),
          "retry": 0,
          "p": "0",
        }),
      ))

      // Set the same value as before rollback
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 2,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({
                id: "1",
                value: `call-4`,
              })
            },
          },
          {
            blockNumber: 106,
            logIndex: 3,
            handler: async args => {
              let context = args.context->asContext
              context.entityWithBigDecimal.set({
                id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              })
            },
          },
        ],
        ~filter=MockSource.coveringBlock(106),
      )

      await indexer.getBatchWritePromise()

      t.expect(
        await Promise.all3((
          indexer.queryCheckpoints(),
          (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
          (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>),
        )),
      ).toEqual((
        [
          {
            id: 3n,
            eventsProcessed: 1,
            chainId: 100->ChainId.fromInt,
            blockNumber: 103,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0103")),
          },
          {
            id: 4n,
            eventsProcessed: 2,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 103,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0103")),
          },
          // Reorg checkpoint id was checkpoint id 5
          // for chain 1337. After rollback it was removed
          // and replaced with chain id 100.
          {
            id: 10n,
            eventsProcessed: 2,
            chainId: 100->ChainId.fromInt,
            blockNumber: 106,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0106")),
          },
          {
            id: 11n,
            eventsProcessed: 0,
            chainId: 100->ChainId.fromInt,
            blockNumber: 111,
            blockHash: Js.Null.Value(MockSource.evmBlockHash("0x0111")),
          },
        ],
        [
          {
            id: "1",
            value: "call-4",
          },
        ],
        [
          Set({
            checkpointId: 3n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-0",
            },
          }),
          Set({
            checkpointId: 4n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-2",
            },
          }),
          Set({
            checkpointId: 10n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {
              id: "1",
              value: "call-4",
            },
          }),
        ],
      ))
      t.expect(
        await Promise.all2((
          (indexer.query("EntityWithBigDecimal"): promise<array<entityWithBigDecimal>>),
          (
            indexer.queryHistory("EntityWithBigDecimal"): promise<
              array<Change.t<entityWithBigDecimal>>,
            >
          ),
        )),
        ~message="Should also add another entity for a non-reorg chain, which should also be rollbacked (theoretically)",
      ).toEqual((
        [
          {
            id: "foo",
            bigDecimal: BigDecimal.fromFloat(0.),
          },
        ],
        [
          Set({
            checkpointId: 10n,
            entityId: "foo"->EntityId.unsafeOfString,
            entity: {
              id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            },
          }),
        ],
      ))
    },
  )

  scenario->Scenario.it(
    "Deletes a rolled back address when a second reorg lands before the write",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)

      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      sourceMock.resolveGetItemsOrThrow([])
      await indexer.getBatchWritePromise()

      sourceMock.resolveGetItemsOrThrow([
        {
          blockNumber: 102,
          logIndex: 0,
          contractRegister: async args => {
            let context = args.context->asRegisterContext
            context.chain.simpleNft.add(
              Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0),
            )
          },
          handler: async _ => (),
        },
      ])
      await indexer.getBatchWritePromise()
      // The registration only reaches storage once the partition created for it
      // has fetched the block that registered it.
      sourceMock.resolveGetItemsOrThrow(
        [{blockNumber: 102, logIndex: 1, handler: async _ => ()}],
        ~filter=MockSource.coveringBlock(102),
        ~latestFetchedBlockNumber=102,
      )
      await indexer.getBatchWritePromise()
      t.expect(
        (await queryDynamicAddresses(indexer))->Array.length,
        ~message="the registration is stored before any reorg",
      ).toEqual(1)

      // First reorg: rolls back past block 102, so the address store drops the
      // registration and hands its row over for deletion.
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=query => query["p"] === "1",
        ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102a"},
      )
      await Utils.delay(0)
      await Utils.delay(0)
      sourceMock.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
      ])
      await indexer.getRollbackReadyPromise()

      // Second reorg before any batch is written: the store has already
      // tombstoned the registration, so it reports nothing this time round.
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(102),
        ~prevRangeLastBlock={blockNumber: 101, blockHash: "0x101a"},
      )
      await Utils.delay(0)
      await Utils.delay(0)
      sourceMock.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
      ])
      await indexer.getRollbackReadyPromise()

      sourceMock.resolveGetItemsOrThrow([], ~filter=MockSource.coveringBlock(101))
      await indexer.getBatchWritePromise()

      t.expect(
        await queryDynamicAddresses(indexer),
        ~message="the write carries both rollbacks' deletions, not just the last one's",
      ).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Double reorg should NOT cause negative event counter (regression test)",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)

      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      sourceMock.resolveGetItemsOrThrow([])
      await indexer.getBatchWritePromise()

      // Process initial events - 1 event across block 102
      sourceMock.resolveGetItemsOrThrow([
        {
          blockNumber: 102,
          logIndex: 0,
          handler: async args => {
            let context = args.context->asContext
            context.simpleEntity.set({
              id: "1",
              value: "value-1",
            })
          },
        },
      ])
      await indexer.getBatchWritePromise()

      // Check initial metrics - should have 3 events processed
      t.expect(
        await indexer.metric("envio_progress_events"),
        ~message="Should have 1 event processed initially",
      ).toEqual([{value: "1", labels: Dict.fromArray([("chainId", "1337")])}])

      // Trigger first reorg
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(103),
        ~prevRangeLastBlock={
          blockNumber: 102,
          blockHash: "0x102a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="Should have called getBlockHashes for first reorg",
      ).toEqual([[100, 101]])

      // Rollback to block 100 - blocks 101-103 are reorged
      sourceMock.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
      ])

      await indexer.getRollbackReadyPromise()

      // Check metrics after first rollback - should have rolled back all 3 events
      t.expect(
        await indexer.metric("envio_progress_events"),
        ~message="Should have 0 events after first rollback",
      ).toEqual([{value: "0", labels: Dict.fromArray([("chainId", "1337")])}])

      // Detects second reorg
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(102),
        ~prevRangeLastBlock={
          blockNumber: 101,
          blockHash: "0x101a",
        },
      )

      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="Should have called getBlockHashes for second reorg",
      ).toEqual([[100, 101], [100]])
      // Rollback to block 100 - blocks 101-103 are reorged
      sourceMock.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
      ])
      await indexer.getRollbackReadyPromise()

      // Check metrics after processing - should have 2 events
      t.expect(
        await indexer.metric("envio_progress_events"),
        ~message="Shouldn't go to negative with the counter",
      ).toEqual([{value: "0", labels: Dict.fromArray([("chainId", "1337")])}])

      // Process batch after rollback
      sourceMock.drainItemsQueries()
      await indexer.getBatchWritePromise()

      t.expect(
        await (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
        ~message="Should have all entities rolled back",
      ).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Should NOT be in reorg threshold on restart when DB is only initialized (sourceBlockNumber=0, progressBlockNumber=-1)",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let _sourceMock = source(1337)
      t.expect(
        await indexer.metric("envio_reorg_threshold"),
        ~message="Should NOT be in reorg threshold when we just created the indexer",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Restart immediately without writing any batches
      // At this point: progressBlockNumber=-1, sourceBlockNumber=0 in DB
      let restarted = await indexer.restart()
      await Utils.delay(0)

      t.expect(
        await restarted.metric("envio_reorg_threshold"),
        ~message="Should NOT be in reorg threshold when sourceBlockNumber is 0 and DB just initialized",
      ).toEqual([{value: "0", labels: Dict.make()}])
    },
  )

  // Reproduces the bug where:
  // 1. Both chains process events, then chain 1337 detects reorg → rollback to block 100
  // 2. After rollback, chain 1337 detects ANOTHER reorg at block 100 → rollback to block 100 again
  // 3. Second rollback subtracts events that were already rolled back → counter goes negative
  // The root cause: only the reorg chain's counter is restored (onQueryResponse in IndexerLoop),
  // but the non-reorg chain's counter stays at 0 while DB still has the old checkpoints.

  multichainScenario->Scenario.it(
    "Multi-chain reorg→rollback→reorg loop: reorg chain repeatedly reorgs while other chain's events get rolled back each time (negative counter regression)",
    ~sources=[{chain: 100, methods, isWildcard: true}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock1337 = source(1337)
      let sourceMock100 = source(100)
      await Utils.delay(0)

      // Both chains enter reorg threshold (blocks 1-100 fetched, knownHeight=300)
      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock1337),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock100),
      ))

      // Both chains process events at blocks 102-103
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "1", value: "value-1"})
            },
          },
          {
            blockNumber: 103,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "2", value: "value-2"})
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      // Chain 1337's query appears once the leader's (chain 100) response
      // releases the budget.
      await MockSource.waitItemsQuery(sourceMock1337)
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "3", value: "value-3"})
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        {
          let metrics = await indexer.metric("envio_progress_events")
          metrics->Array.toSorted(
            (a, b) =>
              Int.compare(
                a.value->Int.fromString->Option.getOr(0),
                b.value->Int.fromString->Option.getOr(0),
              ),
          )
        },
        ~message="Events count before rollback",
      ).toEqual([
        {value: "1", labels: Dict.fromArray([("chainId", "1337")])},
        {value: "2", labels: Dict.fromArray([("chainId", "100")])},
      ])

      // === FIRST REORG on chain 1337 at block 103 ===
      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 103,
          blockHash: "0x103a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      // getBlockHashes called with [100, 102]: both are stored in the
      // threshold below 103. Block 100 still matches and 102 came back on
      // the new fork → rollback target = 100.
      sourceMock1337.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 102, blockHash: "0x102a", blockTimestamp: 102},
      ])

      // Clean up pending calls from before rollback
      sourceMock100.drainItemsQueries()

      await indexer.getRollbackReadyPromise()

      t.expect(
        {
          let metrics = await indexer.metric("envio_progress_events")
          metrics->Array.toSorted(
            (a, b) =>
              Int.compare(
                a.value->Int.fromString->Option.getOr(0),
                b.value->Int.fromString->Option.getOr(0),
              ),
          )
        },
        ~message="After first rollback: all events should be rolled back to 0",
      ).toEqual([
        {value: "0", labels: Dict.fromArray([("chainId", "100")])},
        {value: "0", labels: Dict.fromArray([("chainId", "1337")])},
      ])

      // === SECOND REORG on chain 1337 at block 100 ===
      // After first rollback, stored blocks: {0: "0x0", 100: "0x100"}
      // Chain 1337 re-fetches from block 101, prevRangeLastBlock auto = {100, "0x100"}
      // We override to trigger reorg: block 100 hash changed
      // No getBlockHashes call needed: getThresholdBlockNumbersBelowBlock(~blockNumber=100) = []
      // so getHighestBlockBelowThreshold = 300 - 200 = 100 is used directly.
      // Wait for the SetRollbackState tasks (NextQuery, ProcessEventBatch) to be scheduled


      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 100,
          blockHash: "0x100a",
        },
      )

      // Allow microtask queue to process the fetch response callbacks,
      // which dispatch ValidatePartitionQueryResponse and transition
      // the state from RollbackReady → ReorgDetected.
      // Without this, getRollbackReadyPromise would immediately resolve
      // from the FIRST rollback's RollbackReady state.
      await Utils.delay(0)
      await Utils.delay(0)

      await indexer.getRollbackReadyPromise()

      // THE BUG: After second rollback, chain 100's event counter goes negative
      // because the rollback subtracts events that were already rolled back.
      // Only chain 1337's counter was restored (onQueryResponse in IndexerLoop),
      // but chain 100's counter stayed at 0 while DB still had the old checkpoints.
      t.expect(
        {
          let metrics = await indexer.metric("envio_progress_events")
          metrics->Array.toSorted(
            (a, b) =>
              Int.compare(
                a.labels
                ->Dict.get("chainId")
                ->Option.getOr("")
                ->Int.fromString
                ->Option.getOr(0),
                b.labels
                ->Dict.get("chainId")
                ->Option.getOr("")
                ->Int.fromString
                ->Option.getOr(0),
              ),
          )
        },
        ~message="After second rollback: event counters should NOT be negative",
      ).toEqual([
        {value: "0", labels: Dict.fromArray([("chainId", "100")])},
        {value: "0", labels: Dict.fromArray([("chainId", "1337")])},
      ])
    },
  )

  // Root cause test: validatePartitionQueryResponse must restore counters
  // for every chain when re-reorging from RollbackReady state.
  // Without the fix, only the reorg chain's counter is restored,
  // causing non-reorg chains to go negative on the second rollback.

  threeChainScenario->Scenario.it(
    "Reorg-on-reorg restores ALL chains' counters, not just the reorg chain's",
    ~sources=[
      {chain: 100, methods, isWildcard: true},
      {chain: 137, methods, isWildcard: true},
      {chain: 1337, methods},
    ],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock1337 = source(1337)
      let sourceMock100 = source(100)
      let sourceMock137 = source(137)
      await Utils.delay(0)

      // All three chains enter reorg threshold
      let _ = await Promise.all3((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock1337),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock100),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock137),
      ))

      // Queries are serialized by the budget waterfall in ascending-chain-id
      // order on the progress tie (100, then 137, then 1337): a chain keeps the
      // budget until it reaches head, so drive each to head before the next
      // one's turn. Each chain processes events at blocks 102-103.
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "1", value: "value-1"})
            },
          },
          {
            blockNumber: 103,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "2", value: "value-2"})
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await MockSource.waitItemsQuery(sourceMock100)
      sourceMock100.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await MockSource.waitItemsQuery(sourceMock137)
      sourceMock137.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "4", value: "value-4"})
            },
          },
          {
            blockNumber: 103,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "5", value: "value-5"})
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await MockSource.waitItemsQuery(sourceMock137)
      sourceMock137.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await MockSource.waitItemsQuery(sourceMock1337)
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "3", value: "value-3"})
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        {
          let metrics = await indexer.metric("envio_progress_events")
          // Chain 137's counter also includes its pinned onBlock handlers firing
          // on the way to head; their processing races batch writes, so only the
          // event-driven chains are asserted.
          let metrics = metrics->Array.filter(m => m.labels->Dict.get("chainId") != Some("137"))
          metrics->Array.toSorted(
            (a, b) =>
              Int.compare(
                a.value->Int.fromString->Option.getOr(0),
                b.value->Int.fromString->Option.getOr(0),
              ),
          )
        },
        ~message="Events count before rollback: chain 1337=1, chain 100=2",
      ).toEqual([
        {value: "1", labels: Dict.fromArray([("chainId", "1337")])},
        {value: "2", labels: Dict.fromArray([("chainId", "100")])},
      ])

      // === FIRST REORG on chain 1337 at block 103 ===
      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 103,
          blockHash: "0x103a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      sourceMock1337.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 102, blockHash: "0x102a", blockTimestamp: 102},
      ])

      await indexer.getRollbackReadyPromise()

      t.expect(
        {
          let metrics = await indexer.metric("envio_progress_events")
          // Chain 137's counter also includes its pinned onBlock handlers firing
          // on the way to head; their processing races batch writes, so only the
          // event-driven chains are asserted.
          let metrics = metrics->Array.filter(m => m.labels->Dict.get("chainId") != Some("137"))
          metrics->Array.toSorted(
            (a, b) =>
              Int.compare(
                a.labels->Dict.get("chainId")->Option.getOr("")->Int.fromString->Option.getOr(0),
                b.labels->Dict.get("chainId")->Option.getOr("")->Int.fromString->Option.getOr(0),
              ),
          )
        },
        ~message="After first rollback: counters restored to the pre-reorg state",
      ).toEqual([
        {value: "0", labels: Dict.fromArray([("chainId", "100")])},
        {value: "0", labels: Dict.fromArray([("chainId", "1337")])},
      ])

      // === SECOND REORG on chain 1337 at block 100 ===
      // After the rollback the reorg chain's refetch query goes out directly.
      await MockSource.waitItemsQuery(sourceMock1337)

      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 100,
          blockHash: "0x100a",
        },
      )

      await Utils.delay(0)
      await Utils.delay(0)

      await indexer.getRollbackReadyPromise()

      // The root cause bug: without restoring ALL chains' counters,
      // chain 100 and chain 137 would be at -2 instead of 0.
      t.expect(
        {
          let metrics = await indexer.metric("envio_progress_events")
          // Chain 137's counter also includes its pinned onBlock handlers firing
          // on the way to head; their processing races batch writes, so only the
          // event-driven chains are asserted.
          let metrics = metrics->Array.filter(m => m.labels->Dict.get("chainId") != Some("137"))
          metrics->Array.toSorted(
            (a, b) =>
              Int.compare(
                a.labels->Dict.get("chainId")->Option.getOr("")->Int.fromString->Option.getOr(0),
                b.labels->Dict.get("chainId")->Option.getOr("")->Int.fromString->Option.getOr(0),
              ),
          )
        },
        ~message="After second rollback: non-reorg chain 100 must NOT go negative",
      ).toEqual([
        {value: "0", labels: Dict.fromArray([("chainId", "100")])},
        {value: "0", labels: Dict.fromArray([("chainId", "1337")])},
      ])
    },
  )

  // 1. Setup mock source and indexer

  scenario->Scenario.it(
    "Should NOT have duplicate queries after rollback with chunked partitions",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)

      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      // 3. Process 2 queries to build chunk history (3+ block ranges each)
      // Query 1: 101-103 (range=3) -> enables sourceRangeCapacity=3
      switch sourceMock.getItemsOrThrowCalls {
      | [call] => call.resolve([{blockNumber: 101, logIndex: 0}], ~latestFetchedBlockNumber=103)
      | _ => JsError.throwWithMessage("Step 3 should have a single pending call")
      }
      await indexer.getBatchWritePromise()

      // Query 2: 104-106 (range=3) -> enables prevSourceRangeCapacity=3
      // After this, chunking will be enabled with chunkRange=min(3,3)=3
      // A new query batch should be created with chunks
      switch sourceMock.getItemsOrThrowCalls {
      | [call] => call.resolve([{blockNumber: 104, logIndex: 0}], ~latestFetchedBlockNumber=106)
      | _ => JsError.throwWithMessage("Step 3 should have a single pending call")
      }
      await indexer.getBatchWritePromise()

      // 4. Chunking is active (chunkRange=3 -> chunkSize=ceil(3*1.8)=6). Uniform
      // chunks tiled from 107: 107-112, 113-118, 119-124, ...
      let findChunk = fromBlock =>
        switch sourceMock.getItemsOrThrowCalls->Array.find(
          c => c.payload["fromBlock"] == fromBlock,
        ) {
        | Some(c) => c
        | None =>
          JsError.throwWithMessage(
            `Expected a pending chunk starting at block ${fromBlock->Int.toString}`,
          )
        }

      // 5. Resolve the 113-118 chunk with a PARTIAL range (to 115), leaving a gap
      // at 116-118 in the same partition (no new partition created).
      findChunk(113).resolve([], ~latestFetchedBlockNumber=115)
      // 6. Resolve the earlier chunk normally so the main partition consumes up
      // to 115, detects the gap, and creates a gap-fill query.
      findChunk(107).resolve([], ~latestFetchedBlockNumber=112)

      await indexer.getBatchWritePromise()

      let payloads = sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)
      let gapFills = payloads->Array.filter(p => p["fromBlock"] == 116 && p["toBlock"] == Some(118))
      t.expect(
        (gapFills, payloads->Array.every(p => p["p"] == "0")),
        ~message="Should create exactly one gap-fill query for the partial chunk range in the same partition, with no duplicate partition",
      ).toEqual(([{"fromBlock": 116, "toBlock": Some(118), "retry": 0, "p": "0"}], true))

      // 8. Trigger rollback via reorg detection to block 116
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(116),
        ~prevRangeLastBlock={
          blockNumber: 115,
          blockHash: "0x115a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100, 101, 103, 104, 106, 112]])

      // Rollback to block 112
      sourceMock.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 100},
        {blockNumber: 103, blockHash: "0x0103", blockTimestamp: 100},
        {blockNumber: 104, blockHash: "0x0104", blockTimestamp: 100},
        {blockNumber: 106, blockHash: "0x0106", blockTimestamp: 100},
        {blockNumber: 112, blockHash: "0x0112", blockTimestamp: 100},
      ])

      // Clean up pending calls from before rollback
      sourceMock.drainItemsQueries()

      await indexer.getRollbackReadyPromise()

      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
        ~message="Should NOT have duplicate queries - only partition 0, no partition 1",
      ).toEqual([
        // Partition recreated fresh (no chunk history), single unchunked query
        {
          "fromBlock": 115,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        },
      ])
    },
  )

  // Setup mock source and indexer

  scenario->Scenario.it(
    "Should efficiently refetch only blocks after rollback target with chunked partitions",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)

      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      // Query 1: 101-103 (range=3) -> enables sourceRangeCapacity=3
      switch sourceMock.getItemsOrThrowCalls {
      | [call] => call.resolve([{blockNumber: 101, logIndex: 0}], ~latestFetchedBlockNumber=103)
      | _ => JsError.throwWithMessage("Should have a single pending call for query 1")
      }
      await indexer.getBatchWritePromise()

      // Query 2: 104-106 (range=3) -> enables prevSourceRangeCapacity=3
      // After this, chunking will be enabled with chunkRange=min(3,3)=3
      switch sourceMock.getItemsOrThrowCalls {
      | [call] => call.resolve([{blockNumber: 104, logIndex: 0}], ~latestFetchedBlockNumber=106)
      | _ => JsError.throwWithMessage("Should have a single pending call for query 2")
      }
      await indexer.getBatchWritePromise()

      // Chunked queries: chunkRange=3 -> chunkSize=ceil(3*1.8)=6. Uniform chunks
      // tiled from 107: 107-112, 113-118, 119-124, ...
      let calls = sourceMock.getItemsOrThrowCalls
      t.expect(
        calls->Array.length >= 3,
        ~message="Should have at least 3 chunked queries",
      ).toBeTruthy()
      let chunk1 = calls->Array.getUnsafe(0)
      let chunk2 = calls->Array.getUnsafe(1)
      let chunk3 = calls->Array.getUnsafe(2)
      t.expect(
        (chunk1.payload, chunk2.payload, chunk3.payload),
        ~message="Should create chunked queries",
      ).toEqual((
        {"fromBlock": 107, "toBlock": Some(112), "retry": 0, "p": "0"},
        {"fromBlock": 113, "toBlock": Some(118), "retry": 0, "p": "0"},
        {"fromBlock": 119, "toBlock": Some(124), "retry": 0, "p": "0"},
      ))

      // Resolve the first two chunks, with chunk2 only fetching half its range
      // (to 115). The partition consumes up to 115 and detects the 116-118 gap.
      chunk1.resolve([], ~latestFetchedBlockNumber=112)
      chunk2.resolve([], ~latestFetchedBlockNumber=115) // first half of 113-118
      await indexer.getBatchWritePromise()
      // lfb=115

      // Resolve the 116-118 continuation, storing a reorg checkpoint at block 118.
      let continuationCall = switch sourceMock.getItemsOrThrowCalls->Array.find(
        call => {
          call.payload["fromBlock"] == 116
        },
      ) {
      | Some(call) => call
      | None =>
        JsError.throwWithMessage("Should have a pending continuation call with fromBlock == 116")
      }
      continuationCall.resolve([], ~latestFetchedBlockNumber=118)
      await Utils.delay(0)

      // Trigger rollback on a tail query that starts after 118, so the reorged
      // prevRangeLastBlock=118 is that query's real parent block rather than
      // being paired with an unrelated earlier pending call via queue order.
      let postReorgCall =
        sourceMock.getItemsOrThrowCalls
        ->Array.find(call => call.payload["fromBlock"] > 118)
        ->Option.getOrThrow
      postReorgCall.resolve(
        [],
        ~prevRangeLastBlock={
          blockNumber: 118,
          blockHash: "0x118a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      // Stored checkpoints below reorgBlockNumber(118): [100, 103, 106, 112, 115]
      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100, 101, 103, 104, 106, 112, 115]])

      // All searched blocks are valid, so the reorg is shallow (only block 118).
      sourceMock.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 100},
        {blockNumber: 103, blockHash: "0x0103", blockTimestamp: 100},
        {blockNumber: 104, blockHash: "0x0104", blockTimestamp: 100},
        {blockNumber: 106, blockHash: "0x0106", blockTimestamp: 100},
        {blockNumber: 112, blockHash: "0x0112", blockTimestamp: 100},
        {blockNumber: 115, blockHash: "0x0115", blockTimestamp: 100},
      ])

      // Clean up pending calls from before rollback
      sourceMock.drainItemsQueries()

      await indexer.getRollbackReadyPromise()

      // The reorg is at block 118, so the rollback lands just below it and the
      // partition refetches only from 118 onward — never re-fetching 107-117.
      let queries = sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)

      t.expect(
        queries,
        ~message="Should efficiently refetch only blocks after the rollback target (from 118), not the whole range",
      ).toEqual([
        {
          "fromBlock": 118,
          "p": "0",
          "retry": 0,
          "toBlock": None,
        },
      ])
    },
  )

  // batchSize=1 ensures that chain 100's single event fills the batch,
  // causing chain 1337 to be SKIPPED during batch preparation.
  // This means chain 1337 gets no checkpoint at block 101.

  batchSize1Scenario->Scenario.it(
    "Should not enter infinite reorg loop when reorg chain has no events processed since target checkpoint",
    ~sources=[{chain: 100, methods, isWildcard: true}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let sourceMock1 = source(1337)
      let sourceMock2 = source(100)
      await Utils.delay(0)

      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock1),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock2),
      ))

      // The most-behind chain (100 — the progress tie breaks by ascending
      // chain id) holds the only post-threshold query; chain 1337's appears
      // once the leader's response releases the budget.
      // Chain 100 fetches block 101 with 1 event.
      sourceMock2.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 101,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({
                id: "1",
                value: "from-chain-100",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=101,
      )
      await MockSource.waitItemsQuery(sourceMock1)

      // Chain 1337 fetches block 101 with 0 events.
      // registerReorgGuard stores block hash "0x101" for block 101.
      sourceMock1.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=101)

      // Fetch response processing uses multiple layers of setTimeout(0):
      // 1. ValidatePartitionQueryResponse → dispatches ProcessPartitionQueryResponse task
      // 2. ProcessPartitionQueryResponse → dispatches SubmitPartitionQueryResponse action
      //    which dispatches NextQuery + ProcessEventBatch tasks
      // 3. NextQuery starts fetches, ProcessEventBatch creates batch
      // We need 3 delays to let all layers fire.
      // After this delay:
      // - NextQuery started a fetch for block 102 — but both chains are
      //   equally behind now, so only the leader (chain 100, tie broken by
      //   ascending chain id) holds it; chain 1337's follow-up appears once
      //   chain 100's response releases the budget.
      // - ProcessEventBatch created batch: with batchSize=1, chain 100's
      //   1 event fills the batch. Chain 1337 is SKIPPED — no checkpoint.
      //   The batch write is async and still in-flight.

      sourceMock2.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=102)
      await MockSource.waitItemsQuery(sourceMock1)

      // Chain 1337 now has a pending fetch from block 102 (started by NextQuery
      // once chain 100's budget released). Resolve it with prevRangeLastBlock
      // having a DIFFERENT hash for block 101.
      // registerReorgGuard compares stored "0x101" vs received "0x101a" → MISMATCH.
      // Reorg is detected while the batch write is still in-flight,
      // so chain 1337 never gets a checkpoint at block 101.
      // getRollbackProgressDiff won't return an entry for chain 1337 (None branch).
      sourceMock1.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=102,
        ~prevRangeLastBlock={
          blockNumber: 101,
          blockHash: "0x101a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock1.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100]])
      sourceMock1.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
      ])

      await indexer.getRollbackReadyPromise()

      // The rollback resets every chain's fetch frontier to a consistent
      // checkpoint, so chain 100 also has a fresh (and a stale pre-rollback)
      // pending query competing for budget — clean those up so chain 1337
      // gets its own.
      // Clean up chain 100's dangling pre-rollback query; its known density
      // caps the refetch reservation, so the budget reaches chain 1337 right
      // after.
      sourceMock2.drainItemsQueries()
      await MockSource.waitItemsQuery(sourceMock1)

      let actualPayloads = sourceMock1.getItemsOrThrowCalls->Array.map(c => c.payload)
      t.expect(
        actualPayloads->Utils.Array.last,
        ~message="Should rollback fetch state for reorg chain even with no events processed",
      ).toEqual(
        Some({
          "fromBlock": 101,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        }),
      )

      // Clear getBlockHashesCalls from the initial rollback
      sourceMock1.getBlockHashesCalls->Utils.Array.clearInPlace

      // Resolve the re-fetch with the new (reorged) block hash.
      // With the fix: stale "0x101" was removed by rollbackToValidBlockNumber(100),
      // so "0x101a" is stored fresh — no mismatch.
      // Without the fix: stored "0x101" vs received "0x101a" → another reorg!
      sourceMock1.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=101,
        ~latestFetchedBlockHash="0x101a",
      )
      await indexer.getBatchWritePromise()

      // Verify no second reorg is detected (no infinite loop)
      t.expect(
        sourceMock1.getBlockHashesCalls,
        ~message="Should not trigger another reorg (no infinite loop)",
      ).toEqual([])
    },
  )

  let stallWriteBatch: ref<option<promise<unit>>> = ref(None)
  let writeBatchCalls = ref(0)
  let rollbackReadBeforeFlush = ref(false)

  multichainScenario->Scenario.it(
    "Flushes in-flight batch write before computing rollback diffs (no silent data loss on non-reorg chain)",
    ~sources=[{chain: 100, methods, isWildcard: true}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    ~mapStorage=storage => {
      ...storage,
      // Record an ordering violation instead of relying on timing alone:
      // the rollback must not read checkpoints while a stalled batch
      // write is still pending.
      getRollbackTargetCheckpoint: (~reorgChainId, ~lastKnownValidBlockNumber) => {
        if stallWriteBatch.contents->Option.isSome {
          rollbackReadBeforeFlush := true
        }
        storage.getRollbackTargetCheckpoint(~reorgChainId, ~lastKnownValidBlockNumber)
      },
      getRollbackProgressDiff: (~scope, ~rollbackTargetCheckpointId) => {
        if stallWriteBatch.contents->Option.isSome {
          rollbackReadBeforeFlush := true
        }
        storage.getRollbackProgressDiff(~scope, ~rollbackTargetCheckpointId)
      },
      writeBatch: (
        ~batch,
        ~rollback,
        ~isInReorgThreshold,
        ~config,
        ~allEntities,
        ~updatedEffectsCache,
        ~updatedEntities,
        ~registeredAddresses,
        ~chainMetaData,
        ~onWrite,
      ) => {
        writeBatchCalls := writeBatchCalls.contents + 1
        let run = async () => {
          switch stallWriteBatch.contents {
          | Some(gate) => await gate
          | None => ()
          }
          await storage.writeBatch(
            ~batch,
            ~rollback,
            ~isInReorgThreshold,
            ~config,
            ~allEntities,
            ~updatedEffectsCache,
            ~updatedEntities,
            ~registeredAddresses,
            ~chainMetaData,
            ~onWrite,
          )
        }
        run()
      },
    },
    async (~t, ~indexer, ~source) => {
      let sourceMock1337 = source(1337)
      let sourceMock100 = source(100)
      await Utils.delay(0)

      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock1337),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock100),
      ))

      // Chain 100 progresses first so its checkpoint lands below the future
      // rollback target checkpoint (chain 1337 at block 103). Otherwise the
      // global checkpoint ordering would roll chain 100 back anyway and mask
      // the in-flight write race.
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({
                id: "victim",
                value: "before",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await indexer.getBatchWritePromise()

      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({
                id: "reorg",
                value: "valid",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await indexer.getBatchWritePromise()

      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({
                id: "reorg",
                value: "reorged",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=106,
      )
      await indexer.getBatchWritePromise()

      // Stall the next batch write so it stays in-flight during the rollback
      let resolveStall = ref(() => ())
      stallWriteBatch := Some(Promise.make((resolve, _reject) => resolveStall := (() => resolve())))
      let writeBatchCallsBeforeStall = writeBatchCalls.contents

      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({
                id: "victim",
                value: "in-flight",
              })
            },
          },
        ],
        ~filter=MockSource.coveringBlock(106),
        ~latestFetchedBlockNumber=106,
      )
      // Wait until the batch is processed and its (stalled) write has started
      while writeBatchCalls.contents == writeBatchCallsBeforeStall {
        await Utils.delay(1)
      }

      // Reorg on chain 1337 while chain 100's batch write is still in-flight
      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(107),
        ~prevRangeLastBlock={
          blockNumber: 106,
          blockHash: "0x106a",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock1337.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100, 103]])
      sourceMock1337.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 103, blockHash: "0x0103", blockTimestamp: 103},
      ])

      // Let the rollback proceed to the flush of the stalled write, then
      // release it. If the rollback read the progress diff before flushing,
      // chain 100's checkpoint at block 106 wouldn't be in the db yet: its
      // entity change would be reverted without the chain being rolled back,
      // and the event would never be reprocessed.
      await Utils.delay(10)
      resolveStall.contents()
      stallWriteBatch := None

      // Clean up pending calls from before rollback
      sourceMock100.drainItemsQueries()
      sourceMock1337.drainItemsQueries()

      await indexer.getRollbackReadyPromise()

      t.expect(
        rollbackReadBeforeFlush.contents,
        ~message="Rollback must flush the in-flight batch write before reading rollback checkpoints from the db",
      ).toEqual(false)

      t.expect(
        (
          sourceMock100.getItemsOrThrowCalls->Array.map(c => c.payload),
          sourceMock1337.getItemsOrThrowCalls->Array.map(c => c.payload),
        ),
        ~message="Both chains should refetch from block 106 after rollback (chain 100's in-flight checkpoint was flushed and included in the progress diff)",
      ).toEqual((
        // Chain 100: partition kept (lfb <= target), chunk history preserved.
        // chunkRange=3 -> chunkSize=6, tiled uniformly from 106 up to the
        // per-partition cap of 12 chunks.
        [
          {"fromBlock": 106, "toBlock": Some(111), "retry": 0, "p": "0"},
          {"fromBlock": 112, "toBlock": Some(117), "retry": 0, "p": "0"},
          {"fromBlock": 118, "toBlock": Some(123), "retry": 0, "p": "0"},
          {"fromBlock": 124, "toBlock": Some(129), "retry": 0, "p": "0"},
          {"fromBlock": 130, "toBlock": Some(135), "retry": 0, "p": "0"},
          {"fromBlock": 136, "toBlock": Some(141), "retry": 0, "p": "0"},
          {"fromBlock": 142, "toBlock": Some(147), "retry": 0, "p": "0"},
          {"fromBlock": 148, "toBlock": Some(153), "retry": 0, "p": "0"},
          {"fromBlock": 154, "toBlock": Some(159), "retry": 0, "p": "0"},
          {"fromBlock": 160, "toBlock": Some(165), "retry": 0, "p": "0"},
          {"fromBlock": 166, "toBlock": Some(171), "retry": 0, "p": "0"},
          {"fromBlock": 172, "toBlock": Some(177), "retry": 0, "p": "0"},
        ],
        // Chain 1337: partition deleted (lfb > target), recreated fresh
        [{"fromBlock": 106, "toBlock": None, "retry": 0, "p": "0"}],
      ))

      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({
                id: "victim",
                value: "reapplied",
              })
            },
          },
        ],
        ~filter=MockSource.coveringBlock(106),
        ~latestFetchedBlockNumber=106,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        (
          (await (indexer.query("SimpleEntity"): promise<array<simpleEntity>>))->Array.toSorted((
            a,
            b,
          ) => String.compare(a.id, b.id)),
          await (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>),
          await indexer.metric("envio_rollback_events"),
        ),
        ~message="Chain 100's in-flight entity change should be rolled back together with its progress and reapplied on refetch",
      ).toEqual((
        [
          {
            id: "reorg",
            value: "valid",
          },
          {
            id: "victim",
            value: "reapplied",
          },
        ],
        [
          Set({
            checkpointId: 4n,
            entityId: "reorg"->EntityId.unsafeOfString,
            entity: {
              id: "reorg",
              value: "valid",
            },
          }),
          Set({
            checkpointId: 3n,
            entityId: "victim"->EntityId.unsafeOfString,
            entity: {
              id: "victim",
              value: "before",
            },
          }),
          Set({
            checkpointId: 8n,
            entityId: "victim"->EntityId.unsafeOfString,
            entity: {
              id: "victim",
              value: "reapplied",
            },
          }),
        ],
        [{value: "2", labels: Dict.make()}],
      ))
    },
  )
})
