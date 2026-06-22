open Vitest

// Query only dynamically registered addresses (exclude config addresses with registrationBlock=-1)
let queryDynamicAddresses = (indexerMock: MockIndexer.Indexer.t) =>
  (
    indexerMock.queryRaw(InternalTable.EnvioAddresses.entityConfig): promise<
      array<InternalTable.EnvioAddresses.t>,
    >
  )->Promise.thenResolve(rows => rows->Array.filter(r => r.registrationBlock !== -1))

describe("E2E rollback tests", () => {
  let testSingleChainRollback = async (
    ~t,
    ~sourceMock: MockIndexer.Source.t,
    ~indexerMock: MockIndexer.Indexer.t,
    ~firstHistoryCheckpointId=2n,
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
          handler: async ({context}) => {
            // This shouldn't be written to the db at all
            // and deduped on the in-memory store level
            context.\"SimpleEntity".set({
              id: "1",
              value: "value-1",
            })
            context.\"SimpleEntity".set({
              id: "1",
              value: "value-2",
            })

            context.\"SimpleEntity".set({
              id: "2",
              value: "value-1",
            })
          },
        },
        {
          blockNumber: 101,
          logIndex: 1,
          handler: async ({context}) => {
            // This should overwrite the previous value
            // set on log index 0. No history rows should be created
            // since they are per batch now.
            context.\"SimpleEntity".set({
              id: "2",
              value: "value-2",
            })

            context.\"SimpleEntity".set({
              id: "4",
              value: "value-1",
            })
          },
        },
        {
          blockNumber: 102,
          logIndex: 0,
          handler: async ({context}) => {
            // This should create a new history row
            context.\"SimpleEntity".set({
              id: "3",
              value: "value-1",
            })

            // Test rollback of creating + deleting an entity
            context.\"SimpleEntity".deleteUnsafe("4")
          },
        },
        {
          blockNumber: 103,
          logIndex: 0,
          handler: async ({context}) => {
            // This should be ignored, since it's after the latest fetch block
            // The case is invalid, but this is good
            context.\"SimpleEntity".set({
              id: "3",
              value: "value-2",
            })
          },
        },
      ],
      ~latestFetchedBlockNumber=102,
    )

    await indexerMock.getBatchWritePromise()

    t.expect(
      await Promise.all3((
        indexerMock.queryCheckpoints(),
        indexerMock.query(SimpleEntity),
        indexerMock.queryHistory(SimpleEntity),
      )),
      ~message="Should have two entities in the db",
    ).toEqual((
      [
        {
          id: firstHistoryCheckpointId,
          blockHash: Null.null,
          blockNumber: 101,
          chainId: 1337,
          eventsProcessed: 2,
        },
        {
          id: firstHistoryCheckpointId->BigInt.add(1n),
          blockHash: Js.Null.Value("0x102"),
          blockNumber: 102,
          chainId: 1337,
          eventsProcessed: 1,
        },
      ],
      [
        {
          Indexer.Entities.SimpleEntity.id: "1",
          value: "value-2",
        },
        {
          Indexer.Entities.SimpleEntity.id: "2",
          value: "value-2",
        },
        {
          Indexer.Entities.SimpleEntity.id: "3",
          value: "value-1",
        },
      ],
      [
        Set({
          checkpointId: firstHistoryCheckpointId,
          entityId: "1",
          entity: {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "value-2",
          },
        }),
        Set({
          checkpointId: firstHistoryCheckpointId,
          entityId: "2",
          entity: {
            Indexer.Entities.SimpleEntity.id: "2",
            value: "value-2",
          },
        }),
        Set({
          checkpointId: firstHistoryCheckpointId->BigInt.add(1n),
          entityId: "3",
          entity: {
            Indexer.Entities.SimpleEntity.id: "3",
            value: "value-1",
          },
        }),
        Set({
          checkpointId: firstHistoryCheckpointId,
          entityId: "4",
          entity: {
            Indexer.Entities.SimpleEntity.id: "4",
            value: "value-1",
          },
        }),
        Delete({
          checkpointId: firstHistoryCheckpointId->BigInt.add(1n),
          entityId: "4",
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
          handler: async ({context}) => {
            // The value is not used, since we reset fetch state
            // for rollback
            context.\"SimpleEntity".set({
              id: "3",
              value: "value-1",
            })
          },
        },
      ],
      ~prevRangeLastBlock={
        blockNumber: 102,
        blockHash: "0x102-reorged",
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
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
    ])

    await indexerMock.getRollbackReadyPromise()

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
        handler: async ({context}) => {
          // From value-2 to value-1
          context.\"SimpleEntity".set({
            id: "1",
            value: "value-1",
          })
          // The same value as before rollback
          context.\"SimpleEntity".set({
            id: "2",
            value: "value-2",
          })
        },
      },
    ])

    await indexerMock.getBatchWritePromise()

    t.expect(
      await Promise.all3((
        indexerMock.queryCheckpoints(),
        indexerMock.query(SimpleEntity),
        indexerMock.queryHistory(SimpleEntity),
      )),
      ~message="Should correctly rollback entities",
    ).toEqual((
      [
        {
          id: firstHistoryCheckpointId->BigInt.add(3n),
          blockHash: Js.Null.Value("0x101"),
          blockNumber: 101,
          chainId: 1337,
          eventsProcessed: 1,
        },
      ],
      [
        {
          Indexer.Entities.SimpleEntity.id: "1",
          value: "value-1",
        },
        {
          Indexer.Entities.SimpleEntity.id: "2",
          value: "value-2",
        },
      ],
      [
        Set({
          checkpointId: firstHistoryCheckpointId->BigInt.add(3n),
          entityId: "1",
          entity: {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "value-1",
          },
        }),
        Set({
          checkpointId: firstHistoryCheckpointId->BigInt.add(3n),
          entityId: "2",
          entity: {
            Indexer.Entities.SimpleEntity.id: "2",
            value: "value-2",
          },
        }),
      ],
    ))
  }

  Async.it("Should stay in reorg threshold on restart when progress is past threshold", async t => {
    let sourceMock1337 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let sourceMock100 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#100,
    )
    let chains = [
      {
        MockIndexer.Indexer.chain: #1337,
        sourceConfig: Config.CustomSources([sourceMock1337.source]),
      },
      {
        MockIndexer.Indexer.chain: #100,
        sourceConfig: Config.CustomSources([sourceMock100.source]),
      },
    ]
    let indexerMock = await MockIndexer.Indexer.make(~chains)
    await Utils.delay(0)

    let _ = await Promise.all2((
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
    ))

    t.expect(
      sourceMock1337.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
      ~message="Should enter reorg threshold and request now to the latest block",
    ).toEqual(
      Some({
        "fromBlock": 101,
        "toBlock": None,
        "retry": 0,
        "p": "0",
      }),
    )
    sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=110)
    await indexerMock.getBatchWritePromise()

    t.expect(await indexerMock.metric("envio_reorg_threshold")).toEqual([
      {value: "1", labels: Dict.make()},
    ])

    let indexerMock = await indexerMock.restart()

    sourceMock1337.getHeightOrThrowCalls->Utils.Array.clearInPlace
    sourceMock100.getHeightOrThrowCalls->Utils.Array.clearInPlace

    // Allow async operations to settle
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)

    // After restart, we should still be in reorg threshold because
    // progressBlockNumber (110) > sourceBlockNumber (300) - maxReorgDepth (200) = 100
    t.expect(await indexerMock.metric("envio_reorg_threshold")).toEqual([
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

    await indexerMock.getBatchWritePromise()

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

    t.expect(await indexerMock.metric("envio_reorg_threshold")).toEqual([
      {value: "1", labels: Dict.make()},
    ])
  })

  Async.it("Rollback of a single chain indexer", async t => {
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

    await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)
    await testSingleChainRollback(~t, ~sourceMock, ~indexerMock)
  })

  Async.it("Parks a reorg detected while a batch is still processing", async t => {
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
    await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

    // Hold the block-101 batch open inside its handler so a reorg can be detected
    // while the batch is still in flight.
    let releaseHandler = ref(() => ())
    let handlerGate = Promise.make((resolve, _) => releaseHandler := () => resolve())

    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 101,
          logIndex: 0,
          handler: async ({context}) => {
            context.\"SimpleEntity".set({id: "1", value: "from-reorged-block"})
            await handlerGate
          },
        },
      ],
      ~latestFetchedBlockNumber=101,
      ~latestFetchedBlockHash="0x101",
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
      ~prevRangeLastBlock={blockNumber: 101, blockHash: "0x101-reorged"},
    )
    await Utils.delay(0)
    await Utils.delay(0)

    // The rollback starts finding its depth even though the batch hasn't finished.
    t.expect(
      sourceMock.getBlockHashesCalls,
      ~message="a reorg detected mid-batch should start finding the rollback depth",
    ).toEqual([[100]])
    sourceMock.resolveGetBlockHashes([{blockNumber: 100, blockHash: "0x100", blockTimestamp: 100}])

    // Releasing the handler lets the batch finish; its progress is applied and the
    // parked rollback then executes and re-requests from the rolled-back block.
    releaseHandler.contents()
    await indexerMock.getRollbackReadyPromise()

    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
      ~message="after the parked rollback executes, the indexer re-requests from the valid block",
    ).toEqual(Some({"fromBlock": 101, "toBlock": None, "retry": 0, "p": "0"}))
  })

  Async.it("Fires onRollbackCommit per affected chain after the rollback write", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let rollbackCommitCalls = []
    let unregister = RollbackCommit.register(async (args: RollbackCommit.args) => {
      rollbackCommitCalls->Array.push(args)
    })
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sourceConfig: Config.CustomSources([sourceMock.source]),
        },
      ],
    )
    await Utils.delay(0)

    await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)
    await testSingleChainRollback(~t, ~sourceMock, ~indexerMock)
    unregister()

    t.expect(
      rollbackCommitCalls,
      ~message="Should fire once for the reorged chain with the last valid block",
    ).toEqual([{RollbackCommit.chainId: 1337, rollbackToBlock: 100}])
  })

  Async.it(
    "Stores checkpoints inside of the reorg threshold for batches without items",
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
      )
      await Utils.delay(0)

      await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

      sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=102)

      await indexerMock.getBatchWritePromise()

      t.expect(
        await indexerMock.queryCheckpoints(),
        ~message="Should have added a checkpoint even though there are no items in the batch",
      ).toEqual([
        {
          id: 2n,
          eventsProcessed: 0,
          chainId: 1337,
          blockNumber: 102,
          blockHash: Js.Null.Value("0x102"),
        },
      ])
    },
  )

  Async.it("Shouldn't detect reorg for rollbacked block", async t => {
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

    await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=102)
    await indexerMock.getBatchWritePromise()

    sourceMock.resolveGetItemsOrThrow(
      [],
      ~latestFetchedBlockNumber=103,
      ~prevRangeLastBlock={
        blockNumber: 102,
        blockHash: "0x102-reorged",
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
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
    ])

    await indexerMock.getRollbackReadyPromise()
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
      ~latestFetchedBlockHash="0x102-reorged",
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      await indexerMock.queryCheckpoints(),
      ~message="Should update the checkpoint without retriggering a reorg",
    ).toEqual([
      {
        id: 4n,
        eventsProcessed: 0,
        chainId: 1337,
        blockNumber: 102,
        blockHash: Js.Null.Value("0x102-reorged"),
      },
    ])
  })

  Async.it(
    "Single chain rollback should also work for multichain indexer when another chains are stale",
    async t => {
      let sourceMock1 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMock2 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {
            chain: #1337,
            sourceConfig: Config.CustomSources([sourceMock1.source]),
          },
          {
            chain: #100,
            sourceConfig: Config.CustomSources([sourceMock2.source]),
          },
        ],
      )
      await Utils.delay(0)

      let _ = await Promise.all2((
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1),
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock2),
      ))

      await testSingleChainRollback(
        ~t,
        ~sourceMock=sourceMock1,
        ~indexerMock,
        ~firstHistoryCheckpointId=3n,
      )
    },
  )

  Async.it("Rollback Dynamic Contract", async t => {
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

    await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

    let calls = []
    let handler = async (
      {event}: Internal.genericHandlerArgs<
        Internal.genericEvent<unknown, Indexer.Block.t, Indexer.Transaction.t>,
        Indexer.handlerContext,
      >,
    ) => {
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
          contractRegister: async ({context}) => {
            context.chain.\"SimpleNft".add(
              Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0),
            )
          },
          handler,
        },
        {
          blockNumber: 103,
          logIndex: 2,
          contractRegister: async ({context}) => {
            context.chain.\"SimpleNft".add(
              Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(1),
            )
          },
          handler,
        },
        {
          blockNumber: 104,
          logIndex: 2,
          contractRegister: async ({context}) => {
            context.chain.\"SimpleNft".add(
              Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(2),
            )
          },
          handler,
        },
      ],
      ~latestFetchedBlockNumber=104,
    )

    await indexerMock.getBatchWritePromise()

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
          "p": "2",
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
      await queryDynamicAddresses(indexerMock),
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
      ~resolveAt=#first,
      ~latestFetchedBlockNumber=102,
    )
    await indexerMock.getBatchWritePromise()
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
          "p": "2",
        },
      ],
    ))
    t.expect(
      await queryDynamicAddresses(indexerMock),
      ~message="Added the processed dynamic contract to the db",
    ).toEqual([
      {
        id: `1337-${Envio.TestHelpers.Addresses.mockAddresses
          ->Array.getUnsafe(0)
          ->Address.toString}`,
        chainId: 1337,
        registrationBlock: 102,
        registrationLogIndex: 2,
        contractName: "SimpleNft",
      },
    ])

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#last, ~latestFetchedBlockNumber=103)
    await indexerMock.getBatchWritePromise()
    t.expect(
      (await queryDynamicAddresses(indexerMock))->Array.length,
      ~message="Should add the processed dynamic contracts to the db",
    ).toEqual(2)

    // Should trigger rollback
    sourceMock.resolveGetItemsOrThrow(
      [],
      ~resolveAt=#first,
      ~prevRangeLastBlock={
        blockNumber: 103,
        blockHash: "0x103-reorged",
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
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
      {blockNumber: 102, blockHash: "0x102", blockTimestamp: 102},
    ])

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all)

    await indexerMock.getRollbackReadyPromise()

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
        "p": "2",
      },
    ])

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#first, ~latestFetchedBlockNumber=104)
    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#first, ~latestFetchedBlockNumber=104)
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)
    t.expect(
      (await queryDynamicAddresses(indexerMock))->Array.length,
      ~message=`Nothing won't be rollbacked at this point. Since we need to process an event for this (rollback db only on batch write).
This might be wrong after we start exposing a block hash for progress block.`,
    ).toEqual(2)

    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 104,
          logIndex: 0,
          handler,
        },
      ],
      ~resolveAt=#first,
      ~latestFetchedBlockNumber=104,
    )

    await indexerMock.getBatchWritePromise()

    t.expect(
      await queryDynamicAddresses(indexerMock),
      ~message="Should have only one dynamic contract in the db. The second one rollbacked from db, the third one rollbacked from fetch state",
    ).toEqual([
      {
        id: `1337-${Envio.TestHelpers.Addresses.mockAddresses
          ->Array.getUnsafe(0)
          ->Address.toString}`,
        chainId: 1337,
        registrationBlock: 102,
        registrationLogIndex: 2,
        contractName: "SimpleNft",
      },
    ])
    // After the db rollback, both partitions continue from block 105 (no chunk history yet)
    let payloads = sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)
    t.expect(
      payloads->Array.map(p => (p["p"], p["fromBlock"], p["toBlock"])),
      ~message="Should correctly continue fetching from block 105 after rolling back the db",
    ).toEqual([("2", 105, None), ("0", 105, None)])
  })

  Async.it("Rollback of multichain indexer (single entity id change)", async t => {
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

    let _ = await Promise.all2((
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
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
      {context}: Internal.genericHandlerArgs<
        Internal.genericEvent<unknown, Indexer.Block.t, Indexer.Transaction.t>,
        Indexer.handlerContext,
      >,
    ) => {
      context.\"SimpleEntity".set({
        id: "1",
        value: `call-${getCallCount()->Int.toString}`,
      })
    }

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
      ~resolveAt=#first,
    )
    sourceMock100.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 103,
          logIndex: 2,
          handler,
        },
      ],
      ~latestFetchedBlockNumber=103,
      ~resolveAt=#first,
    )
    await indexerMock.getBatchWritePromise()
    sourceMock1337.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 106,
          logIndex: 2,
          handler,
        },
      ],
      ~latestFetchedBlockNumber=106,
      ~resolveAt=#first,
    )
    await indexerMock.getBatchWritePromise()
    sourceMock100.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 106,
          logIndex: 2,
          handler,
        },
      ],
      ~latestFetchedBlockNumber=106,
      ~resolveAt=#first,
    )
    await indexerMock.getBatchWritePromise()
    sourceMock1337.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 107,
          logIndex: 4,
          handler,
        },
      ],
      ~resolveAt=#first,
      ~latestFetchedBlockNumber=109,
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      await Promise.all3((
        indexerMock.queryCheckpoints(),
        indexerMock.query(SimpleEntity),
        indexerMock.queryHistory(SimpleEntity),
      )),
      ~message=`Should create history rows and checkpoints`,
    ).toEqual((
      [
        {
          id: 3n,
          eventsProcessed: 1,
          chainId: 100,
          blockNumber: 103,
          blockHash: Js.Null.Value("0x103"),
        },
        {
          id: 4n,
          eventsProcessed: 2,
          chainId: 1337,
          blockNumber: 103,
          blockHash: Js.Null.Value("0x103"),
        },
        {
          id: 5n,
          eventsProcessed: 1,
          chainId: 1337,
          blockNumber: 106,
          blockHash: Js.Null.Value("0x106"),
        },
        {
          id: 6n,
          eventsProcessed: 1,
          chainId: 100,
          blockNumber: 106,
          blockHash: Js.Null.Value("0x106"),
        },
        {
          id: 7n,
          eventsProcessed: 1,
          chainId: 1337,
          blockNumber: 107,
          blockHash: Js.Null.Null,
        },
        // Block 108 is skipped, since we don't have
        // ether events processed or block hash for it
        {
          id: 8n,
          eventsProcessed: 0,
          chainId: 1337,
          blockNumber: 109,
          blockHash: Js.Null.Value("0x109"),
        },
      ],
      [
        {
          Indexer.Entities.SimpleEntity.id: "1",
          value: "call-5",
        },
      ],
      [
        Set({
          checkpointId: 3n,
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
            value: "call-2",
          },
        }),
        Set({
          checkpointId: 5n,
          entityId: "1",
          entity: {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "call-3",
          },
        }),
        Set({
          checkpointId: 6n,
          entityId: "1",
          entity: {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "call-4",
          },
        }),
        Set({
          checkpointId: 7n,
          entityId: "1",
          entity: {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "call-5",
          },
        }),
      ],
    ))

    t.expect(
      {
        let metrics = await indexerMock.metric("envio_progress_events")
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
        let metrics = await indexerMock.metric("envio_progress_block")
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
      await indexerMock.metric("envio_rollback_events"),
      ~message="Rollbacked events count before rollback",
    ).toEqual([{value: "0", labels: Dict.make()}])
    t.expect(
      await indexerMock.metric("envio_rollback_total"),
      ~message="Rollbacks count before rollback",
    ).toEqual([{value: "0", labels: Dict.make()}])

    // Should trigger rollback
    sourceMock1337.resolveGetItemsOrThrow(
      [],
      ~prevRangeLastBlock={
        blockNumber: 106,
        blockHash: "0x106-reorged",
      },
      ~resolveAt=#first,
    )
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock1337.getBlockHashesCalls,
      ~message="Should have called getBlockHashes to find rollback depth",
    ).toEqual([[100, 103]])
    sourceMock1337.resolveGetBlockHashes([
      // The block 103 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 103, blockHash: "0x103", blockTimestamp: 103},
    ])

    // Clean up pending calls from before rollback
    sourceMock100.resolveGetItemsOrThrow([], ~resolveAt=#all)
    sourceMock1337.resolveGetItemsOrThrow([], ~resolveAt=#all)

    await indexerMock.getRollbackReadyPromise()

    t.expect(
      await indexerMock.metric("envio_progress_events"),
      ~message="Events count after rollback",
    ).toEqual([
      {value: "1", labels: Dict.fromArray([("chainId", "100")])},
      {value: "2", labels: Dict.fromArray([("chainId", "1337")])},
    ])
    t.expect(
      await indexerMock.metric("envio_progress_block"),
      ~message="Progress block number after rollback",
    ).toEqual([
      {value: "105", labels: Dict.fromArray([("chainId", "100")])},
      {value: "105", labels: Dict.fromArray([("chainId", "1337")])},
    ])
    t.expect(
      await indexerMock.metric("envio_rollback_events"),
      ~message="Rollbacked events count after rollback",
    ).toEqual([{value: "3", labels: Dict.make()}])
    t.expect(
      await indexerMock.metric("envio_rollback_total"),
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
      // Two 0.9-size probe chunks followed by three full-size chunks.
      [
        {
          "fromBlock": 106,
          "toBlock": Some(108),
          "retry": 0,
          "p": "0",
        },
        {
          "fromBlock": 109,
          "toBlock": Some(111),
          "retry": 0,
          "p": "0",
        },
        {
          "fromBlock": 112,
          "toBlock": Some(117),
          "retry": 0,
          "p": "0",
        },
        {
          "fromBlock": 118,
          "toBlock": Some(123),
          "retry": 0,
          "p": "0",
        },
        {
          "fromBlock": 124,
          "toBlock": Some(129),
          "retry": 0,
          "p": "0",
        },
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
          handler: async ({context}) => {
            context.\"SimpleEntity".set({
              id: "1",
              value: `should-be-ignored-by-filter`,
            })
          },
        },
        {
          blockNumber: 106,
          logIndex: 2,
          handler: async ({context}) => {
            // Set the same value as before rollback
            context.\"SimpleEntity".set({
              id: "1",
              value: `call-4`,
            })
          },
        },
      ],
      ~resolveAt=#first,
    )

    await indexerMock.getBatchWritePromise()

    t.expect(
      await Promise.all3((
        indexerMock.queryCheckpoints(),
        indexerMock.query(SimpleEntity),
        indexerMock.queryHistory(SimpleEntity),
      )),
    ).toEqual((
      [
        {
          id: 3n,
          eventsProcessed: 1,
          chainId: 100,
          blockNumber: 103,
          blockHash: Js.Null.Value("0x103"),
        },
        {
          id: 4n,
          eventsProcessed: 2,
          chainId: 1337,
          blockNumber: 103,
          blockHash: Js.Null.Value("0x103"),
        },
        // Reorg checkpoint id was checkpoint id 5
        // for chain 1337. After rollback it was removed
        // and replaced with chain id 100
        {
          id: 10n,
          eventsProcessed: 2,
          chainId: 100,
          blockNumber: 106,
          blockHash: Js.Null.Value("0x106"),
        },
        {
          id: 11n,
          eventsProcessed: 0,
          chainId: 100,
          blockNumber: 108,
          blockHash: Js.Null.Value("0x108"),
        },
      ],
      [
        {
          Indexer.Entities.SimpleEntity.id: "1",
          value: "call-4",
        },
      ],
      [
        Set({
          checkpointId: 3n,
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
            value: "call-2",
          },
        }),
        Set({
          checkpointId: 10n,
          entityId: "1",
          entity: {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "call-4",
          },
        }),
      ],
    ))
  })

  // Fixes duplicate history bug before 2.31
  Async.it(
    "Rollback of multichain indexer (single entity id change + another entity on non-reorg chain)",
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

      let _ = await Promise.all2((
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
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
        {context}: Internal.genericHandlerArgs<
          Internal.genericEvent<unknown, Indexer.Block.t, Indexer.Transaction.t>,
          Indexer.handlerContext,
        >,
      ) => {
        context.\"SimpleEntity".set({
          id: "1",
          value: `call-${getCallCount()->Int.toString}`,
        })
      }

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
        ~resolveAt=#first,
      )
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=103,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=106,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()
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
            handler: async ({context}) => {
              context.\"EntityWithBigDecimal".set({
                id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=106,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 107,
            logIndex: 4,
            handler,
          },
        ],
        ~resolveAt=#first,
        ~latestFetchedBlockNumber=109,
      )
      await indexerMock.getBatchWritePromise()

      t.expect(
        await Promise.all3((
          indexerMock.queryCheckpoints(),
          indexerMock.query(SimpleEntity),
          indexerMock.queryHistory(SimpleEntity),
        )),
        ~message=`Should create history rows and checkpoints`,
      ).toEqual((
        [
          {
            id: 3n,
            eventsProcessed: 1,
            chainId: 100,
            blockNumber: 103,
            blockHash: Js.Null.Value("0x103"),
          },
          {
            id: 4n,
            eventsProcessed: 2,
            chainId: 1337,
            blockNumber: 103,
            blockHash: Js.Null.Value("0x103"),
          },
          {
            id: 5n,
            eventsProcessed: 1,
            chainId: 1337,
            blockNumber: 106,
            blockHash: Js.Null.Value("0x106"),
          },
          {
            id: 6n,
            eventsProcessed: 2,
            chainId: 100,
            blockNumber: 106,
            blockHash: Js.Null.Value("0x106"),
          },
          {
            id: 7n,
            eventsProcessed: 1,
            chainId: 1337,
            blockNumber: 107,
            blockHash: Js.Null.Null,
          },
          // Block 108 is skipped, since we don't have
          // ether events processed or block hash for it
          {
            id: 8n,
            eventsProcessed: 0,
            chainId: 1337,
            blockNumber: 109,
            blockHash: Js.Null.Value("0x109"),
          },
        ],
        [
          {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "call-5",
          },
        ],
        [
          Set({
            checkpointId: 3n,
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
              value: "call-2",
            },
          }),
          Set({
            checkpointId: 5n,
            entityId: "1",
            entity: {
              Indexer.Entities.SimpleEntity.id: "1",
              value: "call-3",
            },
          }),
          Set({
            checkpointId: 6n,
            entityId: "1",
            entity: {
              Indexer.Entities.SimpleEntity.id: "1",
              value: "call-4",
            },
          }),
          Set({
            checkpointId: 7n,
            entityId: "1",
            entity: {
              Indexer.Entities.SimpleEntity.id: "1",
              value: "call-5",
            },
          }),
        ],
      ))
      t.expect(
        await Promise.all2((
          indexerMock.query(EntityWithBigDecimal),
          indexerMock.queryHistory(EntityWithBigDecimal),
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
            entityId: "foo",
            entity: {
              Indexer.Entities.EntityWithBigDecimal.id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            },
          }),
        ],
      ))

      // Should trigger rollback
      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 106,
          blockHash: "0x106-reorged",
        },
        ~resolveAt=#first,
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock1337.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100, 103]])
      sourceMock1337.resolveGetBlockHashes([
        // The block 103 is untouched so we can rollback to it
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
        {blockNumber: 103, blockHash: "0x103", blockTimestamp: 103},
      ])

      // Clean up pending calls from before rollback
      sourceMock100.resolveGetItemsOrThrow([], ~resolveAt=#all)
      sourceMock1337.resolveGetItemsOrThrow([], ~resolveAt=#all)

      await indexerMock.getRollbackReadyPromise()

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
        // Cold start probes with a 0.9-size chunk first.
        Some({
          "fromBlock": 106,
          "toBlock": Some(108),
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
            handler: async ({context}) => {
              context.\"SimpleEntity".set({
                id: "1",
                value: `call-4`,
              })
            },
          },
          {
            blockNumber: 106,
            logIndex: 3,
            handler: async ({context}) => {
              context.\"EntityWithBigDecimal".set({
                id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              })
            },
          },
        ],
        ~resolveAt=#first,
      )

      await indexerMock.getBatchWritePromise()

      t.expect(
        await Promise.all3((
          indexerMock.queryCheckpoints(),
          indexerMock.query(SimpleEntity),
          indexerMock.queryHistory(SimpleEntity),
        )),
      ).toEqual((
        [
          {
            id: 3n,
            eventsProcessed: 1,
            chainId: 100,
            blockNumber: 103,
            blockHash: Js.Null.Value("0x103"),
          },
          {
            id: 4n,
            eventsProcessed: 2,
            chainId: 1337,
            blockNumber: 103,
            blockHash: Js.Null.Value("0x103"),
          },
          // Reorg checkpoint id was checkpoint id 5
          // for chain 1337. After rollback it was removed
          // and replaced with chain id 100
          {
            id: 10n,
            eventsProcessed: 2,
            chainId: 100,
            blockNumber: 106,
            blockHash: Js.Null.Value("0x106"),
          },
          {
            id: 11n,
            eventsProcessed: 0,
            chainId: 100,
            blockNumber: 108,
            blockHash: Js.Null.Value("0x108"),
          },
        ],
        [
          {
            Indexer.Entities.SimpleEntity.id: "1",
            value: "call-4",
          },
        ],
        [
          Set({
            checkpointId: 3n,
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
              value: "call-2",
            },
          }),
          Set({
            checkpointId: 10n,
            entityId: "1",
            entity: {
              Indexer.Entities.SimpleEntity.id: "1",
              value: "call-4",
            },
          }),
        ],
      ))
      t.expect(
        await Promise.all2((
          indexerMock.query(EntityWithBigDecimal),
          indexerMock.queryHistory(EntityWithBigDecimal),
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
            entityId: "foo",
            entity: {
              Indexer.Entities.EntityWithBigDecimal.id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            },
          }),
        ],
      ))
    },
  )

  Async.it("Double reorg should NOT cause negative event counter (regression test)", async t => {
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

    await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

    sourceMock.resolveGetItemsOrThrow([])
    await indexerMock.getBatchWritePromise()

    // Process initial events - 1 event across block 102
    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 102,
        logIndex: 0,
        handler: async ({context}) => {
          context.\"SimpleEntity".set({
            id: "1",
            value: "value-1",
          })
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    // Check initial metrics - should have 3 events processed
    t.expect(
      await indexerMock.metric("envio_progress_events"),
      ~message="Should have 1 event processed initially",
    ).toEqual([{value: "1", labels: Dict.fromArray([("chainId", "1337")])}])

    // Trigger first reorg
    sourceMock.resolveGetItemsOrThrow(
      [],
      ~prevRangeLastBlock={
        blockNumber: 102,
        blockHash: "0x102-reorged",
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
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
    ])

    await indexerMock.getRollbackReadyPromise()

    // Check metrics after first rollback - should have rolled back all 3 events
    t.expect(
      await indexerMock.metric("envio_progress_events"),
      ~message="Should have 0 events after first rollback",
    ).toEqual([{value: "0", labels: Dict.fromArray([("chainId", "1337")])}])

    // Detects second reorg
    sourceMock.resolveGetItemsOrThrow(
      [],
      ~prevRangeLastBlock={
        blockNumber: 101,
        blockHash: "0x101-reorged",
      },
    )

    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getBlockHashesCalls,
      ~message="Should have called getBlockHashes for second reorg",
    ).toEqual([[100, 101], [100]])
    // Rollback to block 100 - blocks 101-103 are reorged
    sourceMock.resolveGetBlockHashes([{blockNumber: 100, blockHash: "0x100", blockTimestamp: 100}])
    await indexerMock.getRollbackReadyPromise()

    // Check metrics after processing - should have 2 events
    t.expect(
      await indexerMock.metric("envio_progress_events"),
      ~message="Shouldn't go to negative with the counter",
    ).toEqual([{value: "0", labels: Dict.fromArray([("chainId", "1337")])}])

    // Process batch after rollback
    sourceMock.resolveGetItemsOrThrow([])
    await indexerMock.getBatchWritePromise()

    t.expect(
      await indexerMock.query(SimpleEntity),
      ~message="Should have all entities rolled back",
    ).toEqual([])
  })

  Async.it(
    "Should NOT be in reorg threshold on restart when DB is only initialized (sourceBlockNumber=0, progressBlockNumber=-1)",
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
      )

      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
        ~message="Should NOT be in reorg threshold when we just created the indexer",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Restart immediately without writing any batches
      // At this point: progressBlockNumber=-1, sourceBlockNumber=0 in DB
      let indexerMock = await indexerMock.restart()
      await Utils.delay(0)

      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
        ~message="Should NOT be in reorg threshold when sourceBlockNumber is 0 and DB just initialized",
      ).toEqual([{value: "0", labels: Dict.make()}])
    },
  )

  Async.it(
    "Multi-chain reorg→rollback→reorg loop: reorg chain repeatedly reorgs while other chain's events get rolled back each time (negative counter regression)",
    async t => {
      // Reproduces the bug where:
      // 1. Both chains process events, then chain 1337 detects reorg → rollback to block 100
      // 2. After rollback, chain 1337 detects ANOTHER reorg at block 100 → rollback to block 100 again
      // 3. Second rollback subtracts events that were already rolled back → counter goes negative
      // The root cause: only the reorg chain's counter is restored (onQueryResponse in IndexerLoop),
      // but the non-reorg chain's counter stays at 0 while DB still has the old checkpoints.
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

      // Both chains enter reorg threshold (blocks 1-100 fetched, knownHeight=300)
      let _ = await Promise.all2((
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
      ))

      // Both chains process events at blocks 102-103
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({id: "1", value: "value-1"})
            },
          },
          {
            blockNumber: 103,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({id: "2", value: "value-2"})
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
        ~resolveAt=#first,
      )
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({id: "3", value: "value-3"})
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()

      t.expect(
        {
          let metrics = await indexerMock.metric("envio_progress_events")
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
          blockHash: "0x103-reorged",
        },
        ~resolveAt=#first,
      )
      await Utils.delay(0)
      await Utils.delay(0)

      // getBlockHashes called with [100] (only stored block in threshold below 103)
      // Block 100 hash matches → rollback target = 100
      sourceMock1337.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      ])

      // Clean up pending calls from before rollback
      sourceMock100.resolveGetItemsOrThrow([], ~resolveAt=#all)

      await indexerMock.getRollbackReadyPromise()

      t.expect(
        {
          let metrics = await indexerMock.metric("envio_progress_events")
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
      await Utils.delay(0)

      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 100,
          blockHash: "0x100-reorged",
        },
        ~resolveAt=#first,
      )

      // Clean up any pending calls for chain 100
      sourceMock100.resolveGetItemsOrThrow([], ~resolveAt=#all)

      // Allow microtask queue to process the fetch response callbacks,
      // which dispatch ValidatePartitionQueryResponse and transition
      // the state from RollbackReady → ReorgDetected.
      // Without this, getRollbackReadyPromise would immediately resolve
      // from the FIRST rollback's RollbackReady state.
      await Utils.delay(0)
      await Utils.delay(0)

      await indexerMock.getRollbackReadyPromise()

      // THE BUG: After second rollback, chain 100's event counter goes negative
      // because the rollback subtracts events that were already rolled back.
      // Only chain 1337's counter was restored (onQueryResponse in IndexerLoop),
      // but chain 100's counter stayed at 0 while DB still had the old checkpoints.
      t.expect(
        {
          let metrics = await indexerMock.metric("envio_progress_events")
          metrics->Array.toSorted(
            (a, b) =>
              Int.compare(
                a.labels->Dict.get("chainId")->Option.getOr("")->Int.fromString->Option.getOr(0),
                b.labels->Dict.get("chainId")->Option.getOr("")->Int.fromString->Option.getOr(0),
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

  Async.it("Reorg-on-reorg restores ALL chains' counters, not just the reorg chain's", async t => {
    // Root cause test: validatePartitionQueryResponse must restore counters
    // for every chain when re-reorging from RollbackReady state.
    // Without the fix, only the reorg chain's counter is restored,
    // causing non-reorg chains to go negative on the second rollback.
    let sourceMock1337 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let sourceMock100 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#100,
    )
    let sourceMock137 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#137,
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
        {
          chain: #137,
          sourceConfig: Config.CustomSources([sourceMock137.source]),
        },
      ],
    )
    await Utils.delay(0)

    // All three chains enter reorg threshold
    let _ = await Promise.all3((
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock137),
    ))

    // Each chain processes events at blocks 102-103
    sourceMock100.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 102,
          logIndex: 0,
          handler: async ({context}) => {
            context.\"SimpleEntity".set({id: "1", value: "value-1"})
          },
        },
        {
          blockNumber: 103,
          logIndex: 0,
          handler: async ({context}) => {
            context.\"SimpleEntity".set({id: "2", value: "value-2"})
          },
        },
      ],
      ~latestFetchedBlockNumber=103,
      ~resolveAt=#first,
    )
    sourceMock137.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 102,
          logIndex: 0,
          handler: async ({context}) => {
            context.\"SimpleEntity".set({id: "4", value: "value-4"})
          },
        },
        {
          blockNumber: 103,
          logIndex: 0,
          handler: async ({context}) => {
            context.\"SimpleEntity".set({id: "5", value: "value-5"})
          },
        },
      ],
      ~latestFetchedBlockNumber=103,
      ~resolveAt=#first,
    )
    sourceMock1337.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 102,
          logIndex: 0,
          handler: async ({context}) => {
            context.\"SimpleEntity".set({id: "3", value: "value-3"})
          },
        },
      ],
      ~latestFetchedBlockNumber=103,
      ~resolveAt=#first,
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      {
        let metrics = await indexerMock.metric("envio_progress_events")
        metrics->Array.toSorted(
          (a, b) =>
            Int.compare(
              a.value->Int.fromString->Option.getOr(0),
              b.value->Int.fromString->Option.getOr(0),
            ),
        )
      },
      ~message="Events count before rollback: chain 1337=1, chain 100=2, chain 137=2",
    ).toEqual([
      {value: "1", labels: Dict.fromArray([("chainId", "1337")])},
      {value: "2", labels: Dict.fromArray([("chainId", "100")])},
      {value: "2", labels: Dict.fromArray([("chainId", "137")])},
    ])

    // === FIRST REORG on chain 1337 at block 103 ===
    sourceMock1337.resolveGetItemsOrThrow(
      [],
      ~prevRangeLastBlock={
        blockNumber: 103,
        blockHash: "0x103-reorged",
      },
      ~resolveAt=#first,
    )
    await Utils.delay(0)
    await Utils.delay(0)

    sourceMock1337.resolveGetBlockHashes([
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
    ])

    // Clean up pending calls from before rollback
    sourceMock100.resolveGetItemsOrThrow([], ~resolveAt=#all)
    sourceMock137.resolveGetItemsOrThrow([], ~resolveAt=#all)

    await indexerMock.getRollbackReadyPromise()

    t.expect(
      {
        let metrics = await indexerMock.metric("envio_progress_events")
        metrics->Array.toSorted(
          (a, b) =>
            Int.compare(
              a.labels->Dict.get("chainId")->Option.getOr("")->Int.fromString->Option.getOr(0),
              b.labels->Dict.get("chainId")->Option.getOr("")->Int.fromString->Option.getOr(0),
            ),
        )
      },
      ~message="After first rollback: all chains' counters should be 0",
    ).toEqual([
      {value: "0", labels: Dict.fromArray([("chainId", "100")])},
      {value: "0", labels: Dict.fromArray([("chainId", "137")])},
      {value: "0", labels: Dict.fromArray([("chainId", "1337")])},
    ])

    // === SECOND REORG on chain 1337 at block 100 ===
    await Utils.delay(0)

    sourceMock1337.resolveGetItemsOrThrow(
      [],
      ~prevRangeLastBlock={
        blockNumber: 100,
        blockHash: "0x100-reorged",
      },
      ~resolveAt=#first,
    )

    sourceMock100.resolveGetItemsOrThrow([], ~resolveAt=#all)
    sourceMock137.resolveGetItemsOrThrow([], ~resolveAt=#all)

    await Utils.delay(0)
    await Utils.delay(0)

    await indexerMock.getRollbackReadyPromise()

    // The root cause bug: without restoring ALL chains' counters,
    // chain 100 and chain 137 would be at -2 instead of 0.
    t.expect(
      {
        let metrics = await indexerMock.metric("envio_progress_events")
        metrics->Array.toSorted(
          (a, b) =>
            Int.compare(
              a.labels->Dict.get("chainId")->Option.getOr("")->Int.fromString->Option.getOr(0),
              b.labels->Dict.get("chainId")->Option.getOr("")->Int.fromString->Option.getOr(0),
            ),
        )
      },
      ~message="After second rollback: non-reorg chains (100, 137) must NOT go negative",
    ).toEqual([
      {value: "0", labels: Dict.fromArray([("chainId", "100")])},
      {value: "0", labels: Dict.fromArray([("chainId", "137")])},
      {value: "0", labels: Dict.fromArray([("chainId", "1337")])},
    ])
  })

  Async.it("Should NOT have duplicate queries after rollback with chunked partitions", async t => {
    // 1. Setup mock source and indexer
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

    await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

    // 3. Process 2 queries to build chunk history (3+ block ranges each)
    // Query 1: 101-103 (range=3) -> enables prevQueryRange=3
    switch sourceMock.getItemsOrThrowCalls {
    | [call] => call.resolve([], ~latestFetchedBlockNumber=103)
    | _ => JsError.throwWithMessage("Step 3 should have a single pending call")
    }
    await indexerMock.getBatchWritePromise()

    // Query 2: 104-106 (range=3) -> enables prevPrevQueryRange=3
    // After this, chunking will be enabled with chunkRange=min(3,3)=3
    // A new query batch should be created with chunks
    switch sourceMock.getItemsOrThrowCalls {
    | [call] => call.resolve([], ~latestFetchedBlockNumber=106)
    | _ => JsError.throwWithMessage("Step 3 should have a single pending call")
    }
    await indexerMock.getBatchWritePromise()

    // 4. Chunking is active (chunkRange=3). Cold start probes with two 0.9-size
    // chunks (107-109, 110-112) then full 1.8-size chunks (113-118, ...).
    let findChunk = fromBlock =>
      switch sourceMock.getItemsOrThrowCalls->Array.find(c => c.payload["fromBlock"] == fromBlock) {
      | Some(c) => c
      | None => JsError.throwWithMessage(`Expected a pending chunk starting at block ${fromBlock->Int.toString}`)
      }

    // 5. Resolve the 113-118 chunk with a PARTIAL range (to 115), leaving a gap
    // at 116-118 in the same partition (no new partition created).
    findChunk(113).resolve([], ~latestFetchedBlockNumber=115)
    // 6. Resolve the earlier chunks normally so the main partition consumes up
    // to 115, detects the gap, and creates a gap-fill query.
    findChunk(107).resolve([], ~latestFetchedBlockNumber=109)
    findChunk(110).resolve([], ~latestFetchedBlockNumber=112)

    await indexerMock.getBatchWritePromise()

    let payloads = sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)
    let gapFills = payloads->Array.filter(p => p["fromBlock"] == 116 && p["toBlock"] == Some(118))
    t.expect(
      (gapFills, payloads->Array.every(p => p["p"] == "0")),
      ~message="Should create exactly one gap-fill query for the partial chunk range in the same partition, with no duplicate partition",
    ).toEqual(([{"fromBlock": 116, "toBlock": Some(118), "retry": 0, "p": "0"}], true))

    // 8. Trigger rollback via reorg detection to block 116
    sourceMock.resolveGetItemsOrThrow(
      [],
      ~prevRangeLastBlock={
        blockNumber: 115,
        blockHash: "0x115-reorged",
      },
      ~resolveAt=#first,
    )
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getBlockHashesCalls,
      ~message="Should have called getBlockHashes to find rollback depth",
    ).toEqual([[100, 103, 106, 109, 112]])

    // Rollback to block 112
    sourceMock.resolveGetBlockHashes([
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 103, blockHash: "0x103", blockTimestamp: 100},
      {blockNumber: 106, blockHash: "0x106", blockTimestamp: 100},
      {blockNumber: 109, blockHash: "0x109", blockTimestamp: 100},
      {blockNumber: 112, blockHash: "0x112", blockTimestamp: 100},
    ])

    // Clean up pending calls from before rollback
    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all)

    await indexerMock.getRollbackReadyPromise()

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
  })

  Async.it(
    "Should efficiently refetch only blocks after rollback target with chunked partitions",
    async t => {
      // Setup mock source and indexer
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

      await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

      // Query 1: 101-103 (range=3) -> enables prevQueryRange=3
      switch sourceMock.getItemsOrThrowCalls {
      | [call] => call.resolve([], ~latestFetchedBlockNumber=103)
      | _ => JsError.throwWithMessage("Should have a single pending call for query 1")
      }
      await indexerMock.getBatchWritePromise()

      // Query 2: 104-106 (range=3) -> enables prevPrevQueryRange=3
      // After this, chunking will be enabled with chunkRange=min(3,3)=3
      switch sourceMock.getItemsOrThrowCalls {
      | [call] => call.resolve([], ~latestFetchedBlockNumber=106)
      | _ => JsError.throwWithMessage("Should have a single pending call for query 2")
      }
      await indexerMock.getBatchWritePromise()

      // Chunked queries: chunkRange=3 -> cold start probes with two 0.9-size
      // chunks (107-109, 110-112) followed by a full 1.8-size chunk (113-118).
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
        {"fromBlock": 107, "toBlock": Some(109), "retry": 0, "p": "0"},
        {"fromBlock": 110, "toBlock": Some(112), "retry": 0, "p": "0"},
        {"fromBlock": 113, "toBlock": Some(118), "retry": 0, "p": "0"},
      ))

      // Resolve the first three chunks, with chunk3 only fetching half its range
      // (to 115). The partition consumes up to 115 and detects the 116-118 gap.
      chunk1.resolve([], ~latestFetchedBlockNumber=109)
      chunk2.resolve([], ~latestFetchedBlockNumber=112)
      chunk3.resolve([], ~latestFetchedBlockNumber=115) // first half of 113-118
      await indexerMock.getBatchWritePromise()
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
          blockHash: "0x118-reorged",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      // Stored checkpoints below reorgBlockNumber(118): [100, 103, 106, 109, 112, 115]
      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100, 103, 106, 109, 112, 115]])

      // All searched blocks are valid, so the reorg is shallow (only block 118).
      sourceMock.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
        {blockNumber: 103, blockHash: "0x103", blockTimestamp: 100},
        {blockNumber: 106, blockHash: "0x106", blockTimestamp: 100},
        {blockNumber: 109, blockHash: "0x109", blockTimestamp: 100},
        {blockNumber: 112, blockHash: "0x112", blockTimestamp: 100},
        {blockNumber: 115, blockHash: "0x115", blockTimestamp: 100},
      ])

      // Clean up pending calls from before rollback
      sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all)

      await indexerMock.getRollbackReadyPromise()

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

  Async.it(
    "Should not enter infinite reorg loop when reorg chain has no events processed since target checkpoint",
    async t => {
      let sourceMock1 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMock2 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      // batchSize=1 ensures that chain 100's single event fills the batch,
      // causing chain 1337 to be SKIPPED during batch preparation.
      // This means chain 1337 gets no checkpoint at block 101.
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {
            chain: #1337,
            sourceConfig: Config.CustomSources([sourceMock1.source]),
          },
          {
            chain: #100,
            sourceConfig: Config.CustomSources([sourceMock2.source]),
          },
        ],
        ~batchSize=1,
      )
      await Utils.delay(0)

      let _ = await Promise.all2((
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1),
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock2),
      ))

      // Chain 1337 fetches block 101 with 0 events.
      // registerReorgGuard stores block hash "0x101" for block 101.
      sourceMock1.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=101, ~resolveAt=#first)

      // Chain 100 fetches block 101 with 1 event.
      sourceMock2.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 101,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({
                id: "1",
                value: "from-chain-100",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=101,
        ~resolveAt=#first,
      )

      // Fetch response processing uses multiple layers of setTimeout(0):
      // 1. ValidatePartitionQueryResponse → dispatches ProcessPartitionQueryResponse task
      // 2. ProcessPartitionQueryResponse → dispatches SubmitPartitionQueryResponse action
      //    which dispatches NextQuery + ProcessEventBatch tasks
      // 3. NextQuery starts fetches, ProcessEventBatch creates batch
      // We need 3 delays to let all layers fire.
      await Utils.delay(0)
      await Utils.delay(0)
      // After this delay:
      // - NextQuery started fetches for both chains from block 102
      // - ProcessEventBatch created batch: with batchSize=1, chain 100's
      //   1 event fills the batch. Chain 1337 is SKIPPED — no checkpoint.
      //   The batch write is async and still in-flight.
      await Utils.delay(0)

      // Chain 1337 now has a pending fetch from block 102 (started by NextQuery).
      // Resolve it with prevRangeLastBlock having a DIFFERENT hash for block 101.
      // registerReorgGuard compares stored "0x101" vs received "0x101-reorged" → MISMATCH.
      // Reorg is detected while the batch write is still in-flight,
      // so chain 1337 never gets a checkpoint at block 101.
      // getRollbackProgressDiff won't return an entry for chain 1337 (None branch).
      sourceMock1.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=102,
        ~prevRangeLastBlock={
          blockNumber: 101,
          blockHash: "0x101-reorged",
        },
        ~resolveAt=#first,
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock1.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100]])
      sourceMock1.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      ])

      await indexerMock.getRollbackReadyPromise()

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
      // so "0x101-reorged" is stored fresh — no mismatch.
      // Without the fix: stored "0x101" vs received "0x101-reorged" → another reorg!
      sourceMock1.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=101,
        ~latestFetchedBlockHash="0x101-reorged",
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()

      // Verify no second reorg is detected (no infinite loop)
      t.expect(
        sourceMock1.getBlockHashesCalls,
        ~message="Should not trigger another reorg (no infinite loop)",
      ).toEqual([])
    },
  )

  Async.it(
    "Flushes in-flight batch write before computing rollback diffs (no silent data loss on non-reorg chain)",
    async t => {
      let stallWriteBatch: ref<option<promise<unit>>> = ref(None)
      let writeBatchCalls = ref(0)
      let rollbackReadBeforeFlush = ref(false)

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
          getRollbackProgressDiff: (~rollbackTargetCheckpointId) => {
            if stallWriteBatch.contents->Option.isSome {
              rollbackReadBeforeFlush := true
            }
            storage.getRollbackProgressDiff(~rollbackTargetCheckpointId)
          },
          writeBatch: (
            ~batch,
            ~rollback,
            ~isInReorgThreshold,
            ~config,
            ~allEntities,
            ~updatedEffectsCache,
            ~updatedEntities,
            ~chainMetaData,
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
                ~chainMetaData,
              )
            }
            run()
          },
        },
      )
      await Utils.delay(0)

      let _ = await Promise.all2((
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
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
            handler: async ({context}) => {
              context.\"SimpleEntity".set({
                id: "victim",
                value: "before",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()

      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({
                id: "reorg",
                value: "valid",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()

      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({
                id: "reorg",
                value: "reorged",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=106,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()

      // Stall the next batch write so it stays in-flight during the rollback
      let resolveStall = ref(() => ())
      stallWriteBatch := Some(Promise.make((resolve, _reject) => resolveStall := () => resolve()))
      let writeBatchCallsBeforeStall = writeBatchCalls.contents

      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({
                id: "victim",
                value: "in-flight",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=106,
        ~resolveAt=#first,
      )
      // Wait until the batch is processed and its (stalled) write has started
      while writeBatchCalls.contents == writeBatchCallsBeforeStall {
        await Utils.delay(1)
      }

      // Reorg on chain 1337 while chain 100's batch write is still in-flight
      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 106,
          blockHash: "0x106-reorged",
        },
        ~resolveAt=#first,
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock1337.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100, 103]])
      sourceMock1337.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
        {blockNumber: 103, blockHash: "0x103", blockTimestamp: 103},
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
      sourceMock100.resolveGetItemsOrThrow([], ~resolveAt=#all)
      sourceMock1337.resolveGetItemsOrThrow([], ~resolveAt=#all)

      await indexerMock.getRollbackReadyPromise()

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
        // Two 0.9-size probe chunks followed by three full-size chunks.
        [
          {"fromBlock": 106, "toBlock": Some(108), "retry": 0, "p": "0"},
          {"fromBlock": 109, "toBlock": Some(111), "retry": 0, "p": "0"},
          {"fromBlock": 112, "toBlock": Some(117), "retry": 0, "p": "0"},
          {"fromBlock": 118, "toBlock": Some(123), "retry": 0, "p": "0"},
          {"fromBlock": 124, "toBlock": Some(129), "retry": 0, "p": "0"},
        ],
        // Chain 1337: partition deleted (lfb > target), recreated fresh
        [{"fromBlock": 106, "toBlock": None, "retry": 0, "p": "0"}],
      ))

      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({
                id: "victim",
                value: "reapplied",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=106,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()

      t.expect(
        (
          (await indexerMock.query(SimpleEntity))->Array.toSorted((a, b) =>
            String.compare(a.id, b.id)
          ),
          await indexerMock.queryHistory(SimpleEntity),
          await indexerMock.metric("envio_rollback_events"),
        ),
        ~message="Chain 100's in-flight entity change should be rolled back together with its progress and reapplied on refetch",
      ).toEqual((
        [
          {
            Indexer.Entities.SimpleEntity.id: "reorg",
            value: "valid",
          },
          {
            Indexer.Entities.SimpleEntity.id: "victim",
            value: "reapplied",
          },
        ],
        [
          Set({
            checkpointId: 4n,
            entityId: "reorg",
            entity: {
              Indexer.Entities.SimpleEntity.id: "reorg",
              value: "valid",
            },
          }),
          Set({
            checkpointId: 3n,
            entityId: "victim",
            entity: {
              Indexer.Entities.SimpleEntity.id: "victim",
              value: "before",
            },
          }),
          Set({
            checkpointId: 8n,
            entityId: "victim",
            entity: {
              Indexer.Entities.SimpleEntity.id: "victim",
              value: "reapplied",
            },
          }),
        ],
        [{value: "2", labels: Dict.make()}],
      ))
    },
  )
})
