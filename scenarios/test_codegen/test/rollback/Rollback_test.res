open Belt
open RescriptMocha

// A workaround for ReScript v11 issue, where it makes the field optional
// instead of setting a value to undefined. It's fixed in v12.
let undefined = (%raw(`undefined`): option<'a>)

describe("E2E rollback tests", () => {
  let testSingleChainRollback = async (
    ~sourceMock: Mock.Source.t,
    ~indexerMock: Mock.Indexer.t,
    ~firstHistoryCheckpointId=2.,
  ) => {
    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls->Utils.Array.last,
      Some({
        "fromBlock": 101,
        "toBlock": None,
        "retry": 0,
      }),
      ~message="Should enter reorg threshold and request now to the latest block",
    )

    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 101,
          logIndex: 0,
          handler: async ({context}) => {
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
          handler: async ({context}) => {
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
          handler: async ({context}) => {
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
          handler: async ({context}) => {
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

    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await Promise.all3((
        indexerMock.queryCheckpoints(),
        indexerMock.query(module(Entities.SimpleEntity)),
        indexerMock.queryHistory(module(Entities.SimpleEntity)),
      )),
      (
        [
          {
            id: firstHistoryCheckpointId,
            blockHash: Js.Null.empty,
            blockNumber: 101,
            chainId: 1337,
            eventsProcessed: 2,
          },
          {
            id: firstHistoryCheckpointId +. 1.,
            blockHash: Js.Null.Value("0x102"),
            blockNumber: 102,
            chainId: 1337,
            eventsProcessed: 1,
          },
        ],
        [
          {
            Entities.SimpleEntity.id: "1",
            value: "value-2",
          },
          {
            Entities.SimpleEntity.id: "2",
            value: "value-2",
          },
          {
            Entities.SimpleEntity.id: "3",
            value: "value-1",
          },
        ],
        [
          Set({
            checkpointId: firstHistoryCheckpointId,
            entityId: "1",
            entity: {
              Entities.SimpleEntity.id: "1",
              value: "value-2",
            },
          }),
          Set({
            checkpointId: firstHistoryCheckpointId,
            entityId: "2",
            entity: {
              Entities.SimpleEntity.id: "2",
              value: "value-2",
            },
          }),
          Set({
            checkpointId: firstHistoryCheckpointId +. 1.,
            entityId: "3",
            entity: {
              Entities.SimpleEntity.id: "3",
              value: "value-1",
            },
          }),
          Set({
            checkpointId: firstHistoryCheckpointId,
            entityId: "4",
            entity: {
              Entities.SimpleEntity.id: "4",
              value: "value-1",
            },
          }),
          Delete({
            checkpointId: firstHistoryCheckpointId +. 1.,
            entityId: "4",
          }),
        ],
      ),
      ~message="Should have two entities in the db",
    )

    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls->Utils.Array.last,
      Some({
        "fromBlock": 103,
        "toBlock": None,
        "retry": 0,
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
            context.simpleEntity.set({
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

    Assert.deepEqual(
      sourceMock.getBlockHashesCalls,
      [[100]],
      ~message="Should have called getBlockHashes to find rollback depth",
    )
    sourceMock.resolveGetBlockHashes([
      // The block 100 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
    ])

    await indexerMock.getRollbackReadyPromise()

    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls->Utils.Array.last,
      Some({
        "fromBlock": 101,
        "toBlock": None,
        "retry": 0,
      }),
      ~message="Should rollback fetch state",
    )
    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 101,
        logIndex: 1,
        handler: async ({context}) => {
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

    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await Promise.all3((
        indexerMock.queryCheckpoints(),
        indexerMock.query(module(Entities.SimpleEntity)),
        indexerMock.queryHistory(module(Entities.SimpleEntity)),
      )),
      (
        [
          {
            id: firstHistoryCheckpointId +. 3.,
            blockHash: Js.Null.Value("0x101"),
            blockNumber: 101,
            chainId: 1337,
            eventsProcessed: 1,
          },
        ],
        [
          {
            Entities.SimpleEntity.id: "1",
            value: "value-1",
          },
          {
            Entities.SimpleEntity.id: "2",
            value: "value-2",
          },
        ],
        [
          Set({
            checkpointId: firstHistoryCheckpointId +. 3.,
            entityId: "1",
            entity: {
              Entities.SimpleEntity.id: "1",
              value: "value-1",
            },
          }),
          Set({
            checkpointId: firstHistoryCheckpointId +. 3.,
            entityId: "2",
            entity: {
              Entities.SimpleEntity.id: "2",
              value: "value-2",
            },
          }),
        ],
      ),
      ~message="Should correctly rollback entities",
    )
  }

  Async.it("Should stay in reorg threshold on restart when progress is past threshold", async () => {
    let sourceMock1337 = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let sourceMock100 = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#100,
    )
    let chains = [
      {
        Mock.Indexer.chain: #1337,
        sourceConfig: Config.CustomSources([sourceMock1337.source]),
      },
      {
        Mock.Indexer.chain: #100,
        sourceConfig: Config.CustomSources([sourceMock100.source]),
      },
    ]
    let indexerMock = await Mock.Indexer.make(~chains)
    await Utils.delay(0)

    let _ = await Promise.all2((
      Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock=sourceMock1337),
      Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock=sourceMock100),
    ))

    Assert.deepEqual(
      sourceMock1337.getItemsOrThrowCalls->Utils.Array.last,
      Some({
        "fromBlock": 101,
        "toBlock": None,
        "retry": 0,
      }),
      ~message="Should enter reorg threshold and request now to the latest block",
    )
    sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=110)
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await indexerMock.metric("envio_reorg_threshold"),
      [{value: "1", labels: Js.Dict.empty()}],
    )

    let indexerMock = await indexerMock.restart()

    sourceMock1337.getHeightOrThrowCalls->Utils.Array.clearInPlace
    sourceMock1337.getItemsOrThrowCalls->Utils.Array.clearInPlace
    sourceMock100.getHeightOrThrowCalls->Utils.Array.clearInPlace
    sourceMock100.getItemsOrThrowCalls->Utils.Array.clearInPlace

    // Allow async operations to settle
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)

    // After restart, we should still be in reorg threshold because
    // progressBlockNumber (110) > sourceBlockNumber (300) - maxReorgDepth (200) = 100
    Assert.deepEqual(
      await indexerMock.metric("envio_reorg_threshold"),
      [{value: "1", labels: Js.Dict.empty()}],
    )

    // After restart, both chains have knownHeight from sourceBlockNumber,
    // so they don't need to call getHeightOrThrow
    Assert.deepEqual(
      sourceMock1337.getHeightOrThrowCalls->Array.length,
      0,
      ~message="should not call getHeightOrThrow on restart (uses sourceBlockNumber as knownHeight)",
    )

    // Both chains are ready immediately, so chain 1337 should continue fetching
    Assert.deepEqual(
      sourceMock1337.getItemsOrThrowCalls->Utils.Array.last,
      Some({
        "fromBlock": 111,
        "toBlock": None,
        "retry": 0,
      }),
      ~message="Should continue indexing from where we left off",
    )

    sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=200, ~knownHeight=320)

    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      sourceMock1337.getItemsOrThrowCalls->Utils.Array.last,
      Some({
        "fromBlock": 201,
        "toBlock": None,
        "retry": 0,
      }),
      ~message="Continue normally inside of the reorg threshold",
    )

    Assert.deepEqual(
      await indexerMock.metric("envio_reorg_threshold"),
      [{value: "1", labels: Js.Dict.empty()}],
    )
  })

  Async.it("Rollback of a single chain indexer", async () => {
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

    await Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock)
    await testSingleChainRollback(~sourceMock, ~indexerMock)
  })

  Async.it(
    "Stores checkpoints inside of the reorg threshold for batches without items",
    async () => {
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

      await Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock)

      sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=102)

      await indexerMock.getBatchWritePromise()

      Assert.deepEqual(
        await indexerMock.queryCheckpoints(),
        [
          {
            id: 2.,
            eventsProcessed: 0,
            chainId: 1337,
            blockNumber: 102,
            blockHash: Js.Null.Value("0x102"),
          },
        ],
        ~message="Should have added a checkpoint even though there are no items in the batch",
      )
    },
  )

  Async.it("Shouldn't detect reorg for rollbacked block", async () => {
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

    await Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock)

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

    Assert.deepEqual(
      sourceMock.getBlockHashesCalls,
      [[100]],
      ~message="Should have called getBlockHashes to find rollback depth",
    )
    sourceMock.resolveGetBlockHashes([
      // The block 100 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
    ])

    sourceMock.getItemsOrThrowCalls->Utils.Array.clearInPlace

    await indexerMock.getRollbackReadyPromise()
    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls,
      [
        {
          "fromBlock": 101,
          "toBlock": None,
          "retry": 0,
        },
      ],
      ~message="Should rollback fetch state and re-request items",
    )

    sourceMock.resolveGetItemsOrThrow(
      [],
      ~latestFetchedBlockNumber=102,
      ~latestFetchedBlockHash="0x102-reorged",
    )
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await indexerMock.queryCheckpoints(),
      [
        {
          id: 4.,
          eventsProcessed: 0,
          chainId: 1337,
          blockNumber: 102,
          blockHash: Js.Null.Value("0x102-reorged"),
        },
      ],
      ~message="Should update the checkpoint without retriggering a reorg",
    )
  })

  Async.it(
    "Single chain rollback should also work for unordered multichain indexer when another chains are stale",
    async () => {
      let sourceMock1 = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMock2 = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      let indexerMock = await Mock.Indexer.make(
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
        Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock=sourceMock1),
        Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock=sourceMock2),
      ))

      await testSingleChainRollback(
        ~sourceMock=sourceMock1,
        ~indexerMock,
        ~firstHistoryCheckpointId=3.,
      )
    },
  )

  Async.it("Rollback Dynamic Contract", async () => {
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

    await Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock)

    let calls = []
    let handler = async (
      {event}: Internal.genericHandlerArgs<Types.eventLog<unknown>, Types.handlerContext>,
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
            context.addSimpleNft(TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0))
          },
          handler,
        },
        {
          blockNumber: 103,
          logIndex: 2,
          contractRegister: async ({context}) => {
            context.addSimpleNft(TestHelpers.Addresses.mockAddresses->Array.getUnsafe(1))
          },
          handler,
        },
        {
          blockNumber: 104,
          logIndex: 2,
          contractRegister: async ({context}) => {
            context.addSimpleNft(TestHelpers.Addresses.mockAddresses->Array.getUnsafe(2))
          },
          handler,
        },
      ],
      ~latestFetchedBlockNumber=104,
    )
    await indexerMock.getBatchWritePromise()

    let expectedGetItemsCallsAfterFirstBatch = [
      {
        "fromBlock": 0,
        "toBlock": Some(100),
        "retry": 0,
      },
      {
        "fromBlock": 101,
        "toBlock": None,
        "retry": 0,
      },
      {
        "fromBlock": 102,
        "toBlock": Some(104),
        "retry": 0,
      },
    ]
    Assert.deepEqual(
      (calls, sourceMock.getItemsOrThrowCalls),
      (["101-0"], expectedGetItemsCallsAfterFirstBatch),
      ~message=`Should query newly registered contracts first,
      before processing the blocks 102 and 104
      (since they might add new events with lower log index)`,
    )
    Assert.deepEqual(
      await indexerMock.query(module(InternalTable.DynamicContractRegistry)),
      [],
      ~message="Shouldn't store dynamic contracts at this point",
    )

    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 102,
          logIndex: 1,
          handler,
        },
      ],
      ~latestFetchedBlockNumber=102,
    )
    await indexerMock.getBatchWritePromise()
    Assert.deepEqual(
      (calls, sourceMock.getItemsOrThrowCalls),
      (
        ["101-0", "102-0", "102-1", "102-2"],
        expectedGetItemsCallsAfterFirstBatch->Array.concat([
          {
            "fromBlock": 103,
            "toBlock": Some(104),
            "retry": 0,
          },
        ]),
      ),
      ~message=`Should process the block 102 after all dynamic contracts finished fetching it`,
    )
    Assert.deepEqual(
      await indexerMock.query(module(InternalTable.DynamicContractRegistry)),
      [
        {
          id: `1337-${TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0)->Address.toString}`,
          chainId: 1337,
          registeringEventBlockNumber: 102,
          registeringEventLogIndex: 2,
          registeringEventBlockTimestamp: 102,
          registeringEventContractName: "MockContract",
          registeringEventName: "MockEvent",
          registeringEventSrcAddress: "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
          contractAddress: TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0),
          contractName: "SimpleNft",
        },
      ],
      ~message="Added the processed dynamic contract to the db",
    )

    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=103)
    await indexerMock.getBatchWritePromise()
    Assert.deepEqual(
      (await indexerMock.query(module(InternalTable.DynamicContractRegistry)))->Array.length,
      2,
      ~message="Should add the processed dynamic contracts to the db",
    )

    // Should trigger rollback
    sourceMock.resolveGetItemsOrThrow(
      [],
      ~prevRangeLastBlock={
        blockNumber: 103,
        blockHash: "0x103-reorged",
      },
    )
    await Utils.delay(0)
    await Utils.delay(0)

    Assert.deepEqual(
      sourceMock.getBlockHashesCalls,
      [[100, 101, 102]],
      ~message="Should have called getBlockHashes to find rollback depth",
    )
    sourceMock.resolveGetBlockHashes([
      // The block 102 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
      {blockNumber: 102, blockHash: "0x102", blockTimestamp: 102},
    ])

    sourceMock.getItemsOrThrowCalls->Utils.Array.clearInPlace

    await indexerMock.getRollbackReadyPromise()
    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls,
      [
        {
          "fromBlock": 103,
          "toBlock": None,
          "retry": 0,
        },
      ],
      ~message="Should rollback fetch state and re-request items",
    )
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=104)
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)
    Assert.deepEqual(
      (await indexerMock.query(module(InternalTable.DynamicContractRegistry)))->Array.length,
      2,
      ~message=`Nothing won't be rollbacked at this point. Since we need to process an event for this (rollback db only on batch write).
This might be wrong after we start exposing a block hash for progress block.`,
    )

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

    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await indexerMock.query(module(InternalTable.DynamicContractRegistry)),
      [
        {
          id: `1337-${TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0)->Address.toString}`,
          chainId: 1337,
          registeringEventBlockNumber: 102,
          registeringEventLogIndex: 2,
          registeringEventBlockTimestamp: 102,
          registeringEventContractName: "MockContract",
          registeringEventName: "MockEvent",
          registeringEventSrcAddress: "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
          contractAddress: TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0),
          contractName: "SimpleNft",
        },
      ],
      ~message="Should have only one dynamic contract in the db. The second one rollbacked from db, the third one rollbacked from fetch state",
    )
    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls,
      [
        {
          "fromBlock": 103,
          "toBlock": None,
          "retry": 0,
        },
        {
          "fromBlock": 103,
          // We rollback fetch state when we have two partitions.
          // It should be possible to merge them during rollback,
          // which we should ideally do.
          "toBlock": Some(104),
          "retry": 0,
        },
        {
          "fromBlock": 105,
          "toBlock": None,
          "retry": 0,
        },
      ],
      ~message="Should correctly continue fetching from block 105 after rolling back the db",
    )
  })

  Async.it("Rollback of unordered multichain indexer (single entity id change)", async () => {
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

    sourceMock1337.resolveGetItemsOrThrow([
      {
        blockNumber: 101,
        logIndex: 1,
        handler,
      },
      {
        blockNumber: 101,
        logIndex: 2,
        handler,
      },
    ])
    sourceMock100.resolveGetItemsOrThrow([
      {
        blockNumber: 101,
        logIndex: 2,
        handler,
      },
    ])
    await indexerMock.getBatchWritePromise()
    sourceMock1337.resolveGetItemsOrThrow([
      {
        blockNumber: 102,
        logIndex: 2,
        handler,
      },
    ])
    await indexerMock.getBatchWritePromise()
    sourceMock100.resolveGetItemsOrThrow([
      {
        blockNumber: 102,
        logIndex: 2,
        handler,
      },
    ])
    await indexerMock.getBatchWritePromise()
    sourceMock1337.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 103,
          logIndex: 4,
          handler,
        },
      ],
      ~latestFetchedBlockNumber=105,
    )
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await Promise.all3((
        indexerMock.queryCheckpoints(),
        indexerMock.query(module(Entities.SimpleEntity)),
        indexerMock.queryHistory(module(Entities.SimpleEntity)),
      )),
      (
        [
          {
            id: 3.,
            eventsProcessed: 1,
            chainId: 100,
            blockNumber: 101,
            blockHash: Js.Null.Value("0x101"),
          },
          {
            id: 4.,
            eventsProcessed: 2,
            chainId: 1337,
            blockNumber: 101,
            blockHash: Js.Null.Value("0x101"),
          },
          {
            id: 5.,
            eventsProcessed: 1,
            chainId: 1337,
            blockNumber: 102,
            blockHash: Js.Null.Value("0x102"),
          },
          {
            id: 6.,
            eventsProcessed: 1,
            chainId: 100,
            blockNumber: 102,
            blockHash: Js.Null.Value("0x102"),
          },
          {
            id: 7.,
            eventsProcessed: 1,
            chainId: 1337,
            blockNumber: 103,
            blockHash: Js.Null.Null,
          },
          // Block 104 is skipped, since we don't have
          // ether events processed or block hash for it
          {
            id: 8.,
            eventsProcessed: 0,
            chainId: 1337,
            blockNumber: 105,
            blockHash: Js.Null.Value("0x105"),
          },
        ],
        [
          {
            Entities.SimpleEntity.id: "1",
            value: "call-5",
          },
        ],
        [
          Set({
            checkpointId: 3.,
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
              value: "call-2",
            },
          }),
          Set({
            checkpointId: 5.,
            entityId: "1",
            entity: {
              Entities.SimpleEntity.id: "1",
              value: "call-3",
            },
          }),
          Set({
            checkpointId: 6.,
            entityId: "1",
            entity: {
              Entities.SimpleEntity.id: "1",
              value: "call-4",
            },
          }),
          Set({
            checkpointId: 7.,
            entityId: "1",
            entity: {
              Entities.SimpleEntity.id: "1",
              value: "call-5",
            },
          }),
        ],
      ),
      ~message=`Should create history rows and checkpoints`,
    )

    Assert.deepEqual(
      await indexerMock.metric("envio_progress_events_count"),
      [
        {value: "2", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "4", labels: Js.Dict.fromArray([("chainId", "1337")])},
      ],
      ~message="Events count before rollback",
    )
    Assert.deepEqual(
      await indexerMock.metric("envio_progress_block_number"),
      [
        {value: "102", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "105", labels: Js.Dict.fromArray([("chainId", "1337")])},
      ],
      ~message="Progress block number before rollback",
    )
    Assert.deepEqual(
      await indexerMock.metric("envio_rollback_events_count"),
      [{value: "0", labels: Js.Dict.empty()}],
      ~message="Rollbacked events count before rollback",
    )
    Assert.deepEqual(
      await indexerMock.metric("envio_rollback_count"),
      [{value: "0", labels: Js.Dict.empty()}],
      ~message="Rollbacks count before rollback",
    )

    // Should trigger rollback
    sourceMock1337.resolveGetItemsOrThrow(
      [],
      ~prevRangeLastBlock={
        blockNumber: 102,
        blockHash: "0x102-reorged",
      },
    )
    await Utils.delay(0)
    await Utils.delay(0)

    Assert.deepEqual(
      sourceMock1337.getBlockHashesCalls,
      [[100, 101]],
      ~message="Should have called getBlockHashes to find rollback depth",
    )
    sourceMock1337.resolveGetBlockHashes([
      // The block 101 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
    ])

    await indexerMock.getRollbackReadyPromise()

    Assert.deepEqual(
      await indexerMock.metric("envio_progress_events_count"),
      [
        {value: "1", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "2", labels: Js.Dict.fromArray([("chainId", "1337")])},
      ],
      ~message="Events count after rollback",
    )
    Assert.deepEqual(
      await indexerMock.metric("envio_progress_block_number"),
      [
        {value: "101", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "101", labels: Js.Dict.fromArray([("chainId", "1337")])},
      ],
      ~message="Progress block number after rollback",
    )
    Assert.deepEqual(
      await indexerMock.metric("envio_rollback_events_count"),
      [{value: "3", labels: Js.Dict.empty()}],
      ~message="Rollbacked events count after rollback",
    )
    Assert.deepEqual(
      await indexerMock.metric("envio_rollback_count"),
      [{value: "1", labels: Js.Dict.empty()}],
      ~message="Rollbacks count after rollback",
    )

    Assert.deepEqual(
      (
        sourceMock1337.getItemsOrThrowCalls->Utils.Array.last,
        sourceMock100.getItemsOrThrowCalls->Utils.Array.last,
      ),
      (
        Some({
          "fromBlock": 102,
          "toBlock": None,
          "retry": 0,
        }),
        Some({
          "fromBlock": 102,
          "toBlock": None,
          "retry": 0,
        }),
      ),
      ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
    )

    sourceMock100.resolveGetItemsOrThrow([
      {
        blockNumber: 102,
        logIndex: 0,
        handler: async ({context}) => {
          context.simpleEntity.set({
            id: "1",
            value: `should-be-ignored-by-filter`,
          })
        },
      },
      {
        blockNumber: 102,
        logIndex: 2,
        handler: async ({context}) => {
          // Set the same value as before rollback
          context.simpleEntity.set({
            id: "1",
            value: `call-4`,
          })
        },
      },
    ])

    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await Promise.all3((
        indexerMock.queryCheckpoints(),
        indexerMock.query(module(Entities.SimpleEntity)),
        indexerMock.queryHistory(module(Entities.SimpleEntity)),
      )),
      (
        [
          {
            id: 3.,
            eventsProcessed: 1,
            chainId: 100,
            blockNumber: 101,
            blockHash: Js.Null.Value("0x101"),
          },
          {
            id: 4.,
            eventsProcessed: 2,
            chainId: 1337,
            blockNumber: 101,
            blockHash: Js.Null.Value("0x101"),
          },
          // Reorg checkpoint id was checkpoint id 5
          // for chain 1337. After rollback it was removed
          // and replaced with chain id 100
          {
            id: 10.,
            eventsProcessed: 2,
            chainId: 100,
            blockNumber: 102,
            blockHash: Js.Null.Value("0x102"),
          },
        ],
        [
          {
            Entities.SimpleEntity.id: "1",
            value: "call-4",
          },
        ],
        [
          Set({
            checkpointId: 3.,
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
              value: "call-2",
            },
          }),
          Set({
            checkpointId: 10.,
            entityId: "1",
            entity: {
              Entities.SimpleEntity.id: "1",
              value: "call-4",
            },
          }),
        ],
      ),
    )
  })

  // Fixes duplicate history bug before 2.31
  Async.it(
    "Rollback of unordered multichain indexer (single entity id change + another entity on non-reorg chain)",
    async () => {
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

      sourceMock1337.resolveGetItemsOrThrow([
        {
          blockNumber: 101,
          logIndex: 1,
          handler,
        },
        {
          blockNumber: 101,
          logIndex: 2,
          handler,
        },
      ])
      sourceMock100.resolveGetItemsOrThrow([
        {
          blockNumber: 101,
          logIndex: 2,
          handler,
        },
      ])
      await indexerMock.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow([
        {
          blockNumber: 102,
          logIndex: 2,
          handler,
        },
      ])
      await indexerMock.getBatchWritePromise()
      sourceMock100.resolveGetItemsOrThrow([
        {
          blockNumber: 102,
          logIndex: 2,
          handler,
        },
        {
          blockNumber: 102,
          logIndex: 3,
          handler: async ({context}) => {
            context.entityWithBigDecimal.set({
              id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            })
          },
        },
      ])
      await indexerMock.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 4,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=105,
      )
      await indexerMock.getBatchWritePromise()

      Assert.deepEqual(
        await Promise.all3((
          indexerMock.queryCheckpoints(),
          indexerMock.query(module(Entities.SimpleEntity)),
          indexerMock.queryHistory(module(Entities.SimpleEntity)),
        )),
        (
          [
            {
              id: 3.,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 101,
              blockHash: Js.Null.Value("0x101"),
            },
            {
              id: 4.,
              eventsProcessed: 2,
              chainId: 1337,
              blockNumber: 101,
              blockHash: Js.Null.Value("0x101"),
            },
            {
              id: 5.,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
            },
            {
              id: 6.,
              eventsProcessed: 2,
              chainId: 100,
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
            },
            {
              id: 7.,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 103,
              blockHash: Js.Null.Null,
            },
            // Block 104 is skipped, since we don't have
            // ether events processed or block hash for it
            {
              id: 8.,
              eventsProcessed: 0,
              chainId: 1337,
              blockNumber: 105,
              blockHash: Js.Null.Value("0x105"),
            },
          ],
          [
            {
              Entities.SimpleEntity.id: "1",
              value: "call-5",
            },
          ],
          [
            Set({
              checkpointId: 3.,
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
                value: "call-2",
              },
            }),
            Set({
              checkpointId: 5.,
              entityId: "1",
              entity: {
                Entities.SimpleEntity.id: "1",
                value: "call-3",
              },
            }),
            Set({
              checkpointId: 6.,
              entityId: "1",
              entity: {
                Entities.SimpleEntity.id: "1",
                value: "call-4",
              },
            }),
            Set({
              checkpointId: 7.,
              entityId: "1",
              entity: {
                Entities.SimpleEntity.id: "1",
                value: "call-5",
              },
            }),
          ],
        ),
        ~message=`Should create history rows and checkpoints`,
      )
      Assert.deepEqual(
        await Promise.all2((
          indexerMock.query(module(Entities.EntityWithBigDecimal)),
          indexerMock.queryHistory(module(Entities.EntityWithBigDecimal)),
        )),
        (
          [
            {
              id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            },
          ],
          [
            Set({
              checkpointId: 6.,
              entityId: "foo",
              entity: {
                Entities.EntityWithBigDecimal.id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              },
            }),
          ],
        ),
        ~message="Should also add another entity for a non-reorg chain, which should also be rollbacked",
      )

      // Should trigger rollback
      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 102,
          blockHash: "0x102-reorged",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      Assert.deepEqual(
        sourceMock1337.getBlockHashesCalls,
        [[100, 101]],
        ~message="Should have called getBlockHashes to find rollback depth",
      )
      sourceMock1337.resolveGetBlockHashes([
        // The block 101 is untouched so we can rollback to it
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
        {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
      ])

      await indexerMock.getRollbackReadyPromise()

      Assert.deepEqual(
        (
          sourceMock1337.getItemsOrThrowCalls->Utils.Array.last,
          sourceMock100.getItemsOrThrowCalls->Utils.Array.last,
        ),
        (
          Some({
            "fromBlock": 102,
            "toBlock": None,
            "retry": 0,
          }),
          Some({
            "fromBlock": 102,
            "toBlock": None,
            "retry": 0,
          }),
        ),
        ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
      )

      // Set the same value as before rollback
      sourceMock100.resolveGetItemsOrThrow([
        {
          blockNumber: 102,
          logIndex: 2,
          handler: async ({context}) => {
            context.simpleEntity.set({
              id: "1",
              value: `call-4`,
            })
          },
        },
        {
          blockNumber: 102,
          logIndex: 3,
          handler: async ({context}) => {
            context.entityWithBigDecimal.set({
              id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            })
          },
        },
      ])

      await indexerMock.getBatchWritePromise()

      Assert.deepEqual(
        await Promise.all3((
          indexerMock.queryCheckpoints(),
          indexerMock.query(module(Entities.SimpleEntity)),
          indexerMock.queryHistory(module(Entities.SimpleEntity)),
        )),
        (
          [
            {
              id: 3.,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 101,
              blockHash: Js.Null.Value("0x101"),
            },
            {
              id: 4.,
              eventsProcessed: 2,
              chainId: 1337,
              blockNumber: 101,
              blockHash: Js.Null.Value("0x101"),
            },
            // Reorg checkpoint id was checkpoint id 5
            // for chain 1337. After rollback it was removed
            // and replaced with chain id 100
            {
              id: 10.,
              eventsProcessed: 2,
              chainId: 100,
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
            },
          ],
          [
            {
              Entities.SimpleEntity.id: "1",
              value: "call-4",
            },
          ],
          [
            Set({
              checkpointId: 3.,
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
                value: "call-2",
              },
            }),
            Set({
              checkpointId: 10.,
              entityId: "1",
              entity: {
                Entities.SimpleEntity.id: "1",
                value: "call-4",
              },
            }),
          ],
        ),
      )
      Assert.deepEqual(
        await Promise.all2((
          indexerMock.query(module(Entities.EntityWithBigDecimal)),
          indexerMock.queryHistory(module(Entities.EntityWithBigDecimal)),
        )),
        (
          [
            {
              id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            },
          ],
          [
            Set({
              checkpointId: 10.,
              entityId: "foo",
              entity: {
                Entities.EntityWithBigDecimal.id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              },
            }),
          ],
        ),
        ~message="Should also add another entity for a non-reorg chain, which should also be rollbacked (theoretically)",
      )
    },
  )

  Async.it(
    "Rollback of ordered multichain indexer (single entity id change + another entity on non-reorg chain)",
    async () => {
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

      sourceMock1337.resolveGetItemsOrThrow([
        {
          blockNumber: 101,
          logIndex: 2,
          handler,
        },
      ])
      sourceMock100.resolveGetItemsOrThrow([])
      await indexerMock.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow([
        {
          blockNumber: 102,
          logIndex: 2,
          handler,
        },
      ])
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 2,
            handler: async ({context}) => {
              context.entityWithBigDecimal.set({
                id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              })
            },
          },
          {
            blockNumber: 103,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      await indexerMock.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow([])
      await indexerMock.getBatchWritePromise()

      Assert.deepEqual(
        await Promise.all3((
          indexerMock.queryCheckpoints(),
          indexerMock.query(module(Entities.SimpleEntity)),
          indexerMock.queryHistory(module(Entities.SimpleEntity)),
        )),
        (
          [
            {
              id: 2.,
              eventsProcessed: 0,
              chainId: 100,
              blockNumber: 101,
              blockHash: Js.Null.Value("0x101"),
            },
            {
              id: 3.,
              eventsProcessed: 0,
              chainId: 1337,
              blockNumber: 100,
              blockHash: Js.Null.Value("0x100"),
            },
            {
              id: 4.,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 101,
              blockHash: Js.Null.Value("0x101"),
            },
            {
              id: 5.,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 102,
              blockHash: Js.Null.Null,
            },
            {
              id: 6.,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
            },
            {
              id: 7.,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 103,
              blockHash: Js.Null.Value("0x103"),
            },
          ],
          [
            {
              Entities.SimpleEntity.id: "1",
              value: "call-2",
            },
          ],
          [
            Set({
              checkpointId: 4.,
              entityId: "1",
              entity: {
                Entities.SimpleEntity.id: "1",
                value: "call-0",
              },
            }),
            Set({
              checkpointId: 6.,
              entityId: "1",
              entity: {
                Entities.SimpleEntity.id: "1",
                value: "call-1",
              },
            }),
            Set({
              checkpointId: 7.,
              entityId: "1",
              entity: {
                Entities.SimpleEntity.id: "1",
                value: "call-2",
              },
            }),
          ],
        ),
        ~message=`Should create multiple history rows:
Sorted by timestamp and chain id`,
      )
      Assert.deepEqual(
        await Promise.all2((
          indexerMock.query(module(Entities.EntityWithBigDecimal)),
          indexerMock.queryHistory(module(Entities.EntityWithBigDecimal)),
        )),
        (
          [
            {
              id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            },
          ],
          [
            Set({
              checkpointId: 5.,
              entityId: "foo",
              entity: {
                Entities.EntityWithBigDecimal.id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              },
            }),
          ],
        ),
        ~message="Should also add another entity for a non-reorg chain, which should also be rollbacked (theoretically)",
      )

      Assert.deepEqual(
        await indexerMock.metric("envio_progress_events_count"),
        [
          {value: "2", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "2", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
        ~message="Events count before rollback",
      )
      Assert.deepEqual(
        await indexerMock.metric("envio_progress_block_number"),
        [
          {value: "103", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "102", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
        ~message="Progress block number before rollback",
      )

      // Should trigger rollback
      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 103,
          blockHash: "0x103-reorged",
        },
      )
      await Utils.delay(0)
      await Utils.delay(0)

      Assert.deepEqual(
        sourceMock1337.getBlockHashesCalls,
        [[100, 101, 102]],
        ~message="Should have called getBlockHashes to find rollback depth",
      )
      sourceMock1337.resolveGetBlockHashes([
        // The block 101 is untouched so we can rollback to it
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
        {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
        {blockNumber: 102, blockHash: "0x102-reorged", blockTimestamp: 102},
      ])

      await indexerMock.getRollbackReadyPromise()

      Assert.deepEqual(
        await indexerMock.metric("envio_progress_events_count"),
        [
          {value: "0", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "1", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
        ~message="Events count after rollback",
      )
      Assert.deepEqual(
        await indexerMock.metric("envio_progress_block_number"),
        [
          {value: "101", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "101", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
        ~message="Progress block number after rollback",
      )

      Assert.deepEqual(
        (
          sourceMock1337.getItemsOrThrowCalls->Utils.Array.last,
          sourceMock100.getItemsOrThrowCalls->Utils.Array.last,
        ),
        (
          Some({
            "fromBlock": 102,
            "toBlock": None,
            "retry": 0,
          }),
          Some({
            "fromBlock": 102,
            "toBlock": None,
            "retry": 0,
          }),
        ),
        ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
      )

      // Set the same value as before rollback
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 2,
            handler: async ({context}) => {
              context.entityWithBigDecimal.set({
                id: "foo",
                // Another value now
                bigDecimal: BigDecimal.fromFloat(0.),
              })
            },
          },
          {
            blockNumber: 103,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=103,
      )
      sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=103)

      await indexerMock.getBatchWritePromise()

      Assert.deepEqual(
        await Promise.all3((
          indexerMock.queryCheckpoints(),
          indexerMock.query(module(Entities.SimpleEntity)),
          indexerMock.queryHistory(module(Entities.SimpleEntity)),
        )),
        (
          [
            {
              id: 2.,
              eventsProcessed: 0,
              chainId: 100,
              blockNumber: 101,
              blockHash: Js.Null.Value("0x101"),
            },
            {
              id: 3.,
              eventsProcessed: 0,
              chainId: 1337,
              blockNumber: 100,
              blockHash: Js.Null.Value("0x100"),
            },
            {
              id: 4.,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 101,
              blockHash: Js.Null.Value("0x101"),
            },
            // Block 101 for chain 100 is skipped,
            // since it doesn't have events processed or block hash
            {
              id: 9.,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 102,
              blockHash: Js.Null.Null,
            },
            {
              id: 10.,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 103,
              blockHash: Js.Null.Value("0x103"),
            },
          ],
          [
            {
              Entities.SimpleEntity.id: "1",
              value: "call-3",
            },
          ],
          [
            Set({
              checkpointId: 4.,
              entityId: "1",
              entity: {
                Entities.SimpleEntity.id: "1",
                value: "call-0",
              },
            }),
            Set({
              checkpointId: 10.,
              entityId: "1",
              entity: {
                Entities.SimpleEntity.id: "1",
                value: "call-3",
              },
            }),
          ],
        ),
      )
      Assert.deepEqual(
        await Promise.all2((
          indexerMock.query(module(Entities.EntityWithBigDecimal)),
          indexerMock.queryHistory(module(Entities.EntityWithBigDecimal)),
        )),
        (
          [
            {
              id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            },
          ],
          [
            Set({
              checkpointId: 9.,
              entityId: "foo",
              entity: {
                Entities.EntityWithBigDecimal.id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              },
            }),
          ],
        ),
        ~message="Should also add another entity for a non-reorg chain, which should also be rollbacked (theoretically)",
      )
    },
  )

  Async.it("Double reorg should NOT cause negative event counter (regression test)", async () => {
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

    await Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock)

    sourceMock.resolveGetItemsOrThrow([])
    await indexerMock.getBatchWritePromise()

    // Process initial events - 1 event across block 102
    sourceMock.resolveGetItemsOrThrow([
      {
        blockNumber: 102,
        logIndex: 0,
        handler: async ({context}) => {
          context.simpleEntity.set({
            id: "1",
            value: "value-1",
          })
        },
      },
    ])
    await indexerMock.getBatchWritePromise()

    // Check initial metrics - should have 3 events processed
    Assert.deepEqual(
      await indexerMock.metric("envio_progress_events_count"),
      [{value: "1", labels: Js.Dict.fromArray([("chainId", "1337")])}],
      ~message="Should have 1 event processed initially",
    )

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

    Assert.deepEqual(
      sourceMock.getBlockHashesCalls,
      [[100, 101]],
      ~message="Should have called getBlockHashes for first reorg",
    )

    // Rollback to block 100 - blocks 101-103 are reorged
    sourceMock.resolveGetBlockHashes([
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
    ])

    await indexerMock.getRollbackReadyPromise()

    // Check metrics after first rollback - should have rolled back all 3 events
    Assert.deepEqual(
      await indexerMock.metric("envio_progress_events_count"),
      [{value: "0", labels: Js.Dict.fromArray([("chainId", "1337")])}],
      ~message="Should have 0 events after first rollback",
    )

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

    Assert.deepEqual(
      sourceMock.getBlockHashesCalls,
      [[100, 101], [100]],
      ~message="Should have called getBlockHashes for second reorg",
    )
    // Rollback to block 100 - blocks 101-103 are reorged
    sourceMock.resolveGetBlockHashes([{blockNumber: 100, blockHash: "0x100", blockTimestamp: 100}])
    await indexerMock.getRollbackReadyPromise()

    // Check metrics after processing - should have 2 events
    Assert.deepEqual(
      await indexerMock.metric("envio_progress_events_count"),
      [{value: "0", labels: Js.Dict.fromArray([("chainId", "1337")])}],
      ~message="Shouldn't go to negative with the counter",
    )

    // Process batch after rollback
    sourceMock.resolveGetItemsOrThrow([])
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await indexerMock.query(module(Entities.SimpleEntity)),
      [],
      ~message="Should have all entities rolled back",
    )
  })

  Async.it(
    "Should NOT be in reorg threshold on restart when progress is below threshold",
    async () => {
      // Regression test: isInReorgThreshold must be correct after restart.
      // Fix 1: isProgressInReorgThreshold returns false if sourceBlockNumber is 0
      // Fix 2: sourceBlockNumber is persisted during batch write

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

      // Get initial height (300) and progress to block 50
      sourceMock.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 50,
            logIndex: 0,
            handler: async ({context}) => {
              context.simpleEntity.set({id: "1", value: "value-1"})
            },
          },
        ],
        ~latestFetchedBlockNumber=50,
      )
      await indexerMock.getBatchWritePromise()

      // Verify NOT in reorg threshold before restart
      // Progress (50) < reorg threshold (100 = 300 - 200)
      Assert.deepEqual(
        await indexerMock.metric("envio_reorg_threshold"),
        [{value: "0", labels: Js.Dict.empty()}],
        ~message="Should NOT be in reorg threshold before restart",
      )

      // Immediately restart - this is where the bug manifests
      let indexerMock = await indexerMock.restart()
      await Utils.delay(0)
      await Utils.delay(0)

      // CRITICAL: After restart, should still NOT be in reorg threshold
      // BUG: If sourceBlockNumber wasn't persisted (is 0), this will incorrectly be "1"
      Assert.deepEqual(
        await indexerMock.metric("envio_reorg_threshold"),
        [{value: "0", labels: Js.Dict.empty()}],
        ~message="Should NOT be in reorg threshold after restart (sourceBlockNumber must be persisted)",
      )
    },
  )

  Async.it(
    "Should NOT be in reorg threshold on restart when sourceBlockNumber is 0",
    async () => {
      // Test the defensive check: when sourceBlockNumber is 0 (DB initialized but
      // no batches written yet), isInReorgThreshold should be false.

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

      // Restart immediately - DB has sourceBlockNumber=0
      let indexerMock = await indexerMock.restart()
      await Utils.delay(0)

      // CRITICAL: Should NOT be in reorg threshold when sourceBlockNumber=0
      Assert.deepEqual(
        await indexerMock.metric("envio_reorg_threshold"),
        [{value: "0", labels: Js.Dict.empty()}],
        ~message="Should NOT be in reorg threshold when sourceBlockNumber is 0",
      )
    },
  )
})
