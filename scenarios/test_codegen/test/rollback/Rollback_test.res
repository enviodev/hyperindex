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
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
      Some({
        "fromBlock": 101,
        "toBlock": None,
        "retry": 0,
        "p": "0",
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
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
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
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
      Some({
        "fromBlock": 101,
        "toBlock": None,
        "retry": 0,
        // IDs reset on rollback, recreated partition starts at 0
        "p": "0",
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

  Async.it(
    "Should stay in reorg threshold on restart when progress is past threshold",
    async () => {
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
        sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
        Some({
          "fromBlock": 101,
          "toBlock": None,
          "retry": 0,
          "p": "0",
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
      sourceMock100.getHeightOrThrowCalls->Utils.Array.clearInPlace

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
        sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
        Some({
          "fromBlock": 111,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        }),
        ~message="Should continue indexing from where we left off",
      )

      sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=200, ~knownHeight=320)

      await indexerMock.getBatchWritePromise()

      Assert.deepEqual(
        sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
        Some({
          "fromBlock": 201,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        }),
        ~message="Continue normally inside of the reorg threshold",
      )

      Assert.deepEqual(
        await indexerMock.metric("envio_reorg_threshold"),
        [{value: "1", labels: Js.Dict.empty()}],
      )
    },
  )

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

    await indexerMock.getRollbackReadyPromise()
    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      [
        {
          "fromBlock": 101,
          "toBlock": None,
          "retry": 0,
          // IDs reset on rollback, recreated partition starts at 0
          "p": "0",
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

    Assert.deepEqual(
      (calls, sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)),
      (
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
      ),
      ~message=`Creates a new partition for DCs and queries it in parallel with the original partition without blocking`,
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
      ~resolveAt=#first,
      ~latestFetchedBlockNumber=102,
    )
    await indexerMock.getBatchWritePromise()
    Assert.deepEqual(
      (calls, sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)),
      (
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
      ),
      ~message=`Should process the block 102 after DC partition finished fetching it`,
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

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#last, ~latestFetchedBlockNumber=103)
    await indexerMock.getBatchWritePromise()
    Assert.deepEqual(
      (await indexerMock.query(module(InternalTable.DynamicContractRegistry)))->Array.length,
      2,
      ~message="Should add the processed dynamic contracts to the db",
    )

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

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all)

    await indexerMock.getRollbackReadyPromise()

    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      [
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
      ],
      ~message="Should rollback fetch state and re-request items",
    )

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#first, ~latestFetchedBlockNumber=104)
    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#first, ~latestFetchedBlockNumber=104)
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
      ~resolveAt=#first,
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
    // After the db rollback, both partitions continue from block 105 (no chunk history yet)
    let payloads = sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)
    Assert.deepEqual(
      payloads->Js.Array2.map(p => (p["p"], p["fromBlock"], p["toBlock"])),
      [("2", 105, None), ("0", 105, None)],
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
            blockNumber: 103,
            blockHash: Js.Null.Value("0x103"),
          },
          {
            id: 4.,
            eventsProcessed: 2,
            chainId: 1337,
            blockNumber: 103,
            blockHash: Js.Null.Value("0x103"),
          },
          {
            id: 5.,
            eventsProcessed: 1,
            chainId: 1337,
            blockNumber: 106,
            blockHash: Js.Null.Value("0x106"),
          },
          {
            id: 6.,
            eventsProcessed: 1,
            chainId: 100,
            blockNumber: 106,
            blockHash: Js.Null.Value("0x106"),
          },
          {
            id: 7.,
            eventsProcessed: 1,
            chainId: 1337,
            blockNumber: 107,
            blockHash: Js.Null.Null,
          },
          // Block 108 is skipped, since we don't have
          // ether events processed or block hash for it
          {
            id: 8.,
            eventsProcessed: 0,
            chainId: 1337,
            blockNumber: 109,
            blockHash: Js.Null.Value("0x109"),
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
      {
        let metrics = await indexerMock.metric("envio_progress_events_count")
        // For some reason the test returns the metrics in different order
        metrics->Js.Array2.sortInPlaceWith((a, b) => a.value->Obj.magic - b.value->Obj.magic)
      },
      [
        {value: "2", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "4", labels: Js.Dict.fromArray([("chainId", "1337")])},
      ],
      ~message="Events count before rollback",
    )
    Assert.deepEqual(
      {
        let metrics = await indexerMock.metric("envio_progress_block_number")
        // For some reason the test returns the metrics in different order
        metrics->Js.Array2.sortInPlaceWith((a, b) => a.value->Obj.magic - b.value->Obj.magic)
      },
      [
        {value: "106", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "109", labels: Js.Dict.fromArray([("chainId", "1337")])},
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
        blockNumber: 106,
        blockHash: "0x106-reorged",
      },
      ~resolveAt=#first,
    )
    await Utils.delay(0)
    await Utils.delay(0)

    Assert.deepEqual(
      sourceMock1337.getBlockHashesCalls,
      [[100, 103]],
      ~message="Should have called getBlockHashes to find rollback depth",
    )
    sourceMock1337.resolveGetBlockHashes([
      // The block 103 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 103, blockHash: "0x103", blockTimestamp: 103},
    ])

    // Clean up pending calls from before rollback
    sourceMock100.resolveGetItemsOrThrow([], ~resolveAt=#all)
    sourceMock1337.resolveGetItemsOrThrow([], ~resolveAt=#all)

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
        {value: "105", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "105", labels: Js.Dict.fromArray([("chainId", "1337")])},
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
        sourceMock100.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
        sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      ),
      (
        // Chain 100: partition KEPT (lfb <= target), chunk history preserved
        [
          {
            "fromBlock": 106,
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
      ),
      ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
    )

    sourceMock100.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 106,
          logIndex: 0,
          handler: async ({context}) => {
            context.simpleEntity.set({
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
            context.simpleEntity.set({
              id: "1",
              value: `call-4`,
            })
          },
        },
      ],
      ~resolveAt=#first,
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
            blockNumber: 103,
            blockHash: Js.Null.Value("0x103"),
          },
          {
            id: 4.,
            eventsProcessed: 2,
            chainId: 1337,
            blockNumber: 103,
            blockHash: Js.Null.Value("0x103"),
          },
          // Reorg checkpoint id was checkpoint id 5
          // for chain 1337. After rollback it was removed
          // and replaced with chain id 100
          {
            id: 10.,
            eventsProcessed: 2,
            chainId: 100,
            blockNumber: 106,
            blockHash: Js.Null.Value("0x106"),
          },
          {
            id: 11.,
            eventsProcessed: 0,
            chainId: 100,
            blockNumber: 111,
            blockHash: Js.Null.Value("0x111"),
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
              context.entityWithBigDecimal.set({
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
              blockNumber: 103,
              blockHash: Js.Null.Value("0x103"),
            },
            {
              id: 4.,
              eventsProcessed: 2,
              chainId: 1337,
              blockNumber: 103,
              blockHash: Js.Null.Value("0x103"),
            },
            {
              id: 5.,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 106,
              blockHash: Js.Null.Value("0x106"),
            },
            {
              id: 6.,
              eventsProcessed: 2,
              chainId: 100,
              blockNumber: 106,
              blockHash: Js.Null.Value("0x106"),
            },
            {
              id: 7.,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 107,
              blockHash: Js.Null.Null,
            },
            // Block 108 is skipped, since we don't have
            // ether events processed or block hash for it
            {
              id: 8.,
              eventsProcessed: 0,
              chainId: 1337,
              blockNumber: 109,
              blockHash: Js.Null.Value("0x109"),
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
          blockNumber: 106,
          blockHash: "0x106-reorged",
        },
        ~resolveAt=#first,
      )
      await Utils.delay(0)
      await Utils.delay(0)

      Assert.deepEqual(
        sourceMock1337.getBlockHashesCalls,
        [[100, 103]],
        ~message="Should have called getBlockHashes to find rollback depth",
      )
      sourceMock1337.resolveGetBlockHashes([
        // The block 103 is untouched so we can rollback to it
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
        {blockNumber: 103, blockHash: "0x103", blockTimestamp: 103},
      ])

      // Clean up pending calls from before rollback
      sourceMock100.resolveGetItemsOrThrow([], ~resolveAt=#all)
      sourceMock1337.resolveGetItemsOrThrow([], ~resolveAt=#all)

      await indexerMock.getRollbackReadyPromise()

      Assert.deepEqual(
        (
          sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.first,
          sourceMock100.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.first,
        ),
        (
          // Chain 1337: partition DELETED, recreated fresh (no chunking)
          Some({
            "fromBlock": 106,
            "toBlock": None,
            "retry": 0,
            "p": "0",
          }),
          // Chain 100: partition KEPT, chunk history preserved
          Some({
            "fromBlock": 106,
            "toBlock": Some(111),
            "retry": 0,
            "p": "0",
          }),
        ),
        ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
      )

      // Set the same value as before rollback
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 106,
            logIndex: 2,
            handler: async ({context}) => {
              context.simpleEntity.set({
                id: "1",
                value: `call-4`,
              })
            },
          },
          {
            blockNumber: 106,
            logIndex: 3,
            handler: async ({context}) => {
              context.entityWithBigDecimal.set({
                id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              })
            },
          },
        ],
        ~resolveAt=#first,
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
              blockNumber: 103,
              blockHash: Js.Null.Value("0x103"),
            },
            {
              id: 4.,
              eventsProcessed: 2,
              chainId: 1337,
              blockNumber: 103,
              blockHash: Js.Null.Value("0x103"),
            },
            // Reorg checkpoint id was checkpoint id 5
            // for chain 1337. After rollback it was removed
            // and replaced with chain id 100
            {
              id: 10.,
              eventsProcessed: 2,
              chainId: 100,
              blockNumber: 106,
              blockHash: Js.Null.Value("0x106"),
            },
            {
              id: 11.,
              eventsProcessed: 0,
              chainId: 100,
              blockNumber: 111,
              blockHash: Js.Null.Value("0x111"),
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

      sourceMock1337.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 2,
            handler,
          },
        ],
        ~latestFetchedBlockNumber=102,
        ~resolveAt=#first,
      )
      sourceMock100.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=102, ~resolveAt=#first)
      await indexerMock.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow(
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
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 2,
            handler: async ({context}) => {
              context.entityWithBigDecimal.set({
                id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              })
            },
          },
          {
            blockNumber: 104,
            logIndex: 2,
            handler,
          },
        ],
        ~resolveAt=#first,
        ~latestFetchedBlockNumber=104,
      )
      await indexerMock.getBatchWritePromise()
      sourceMock1337.resolveGetItemsOrThrow([], ~resolveAt=#first)
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
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
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
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
            },
            {
              id: 5.,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 103,
              blockHash: Js.Null.Null,
            },
            {
              id: 6.,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 103,
              blockHash: Js.Null.Value("0x103"),
            },
            {
              id: 7.,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 104,
              blockHash: Js.Null.Value("0x104"),
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
          {value: "104", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "103", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
        ~message="Progress block number before rollback",
      )

      // Should trigger rollback
      sourceMock1337.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 105,
          blockHash: "0x105-reorged",
        },
        ~resolveAt=#first,
      )
      await Utils.delay(0)
      await Utils.delay(0)

      Assert.deepEqual(
        sourceMock1337.getBlockHashesCalls,
        [[100, 102, 103]],
        ~message="Should have called getBlockHashes to find rollback depth",
      )
      sourceMock1337.resolveGetBlockHashes([
        // The block 102 is untouched so we can rollback to it
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
        {blockNumber: 102, blockHash: "0x102", blockTimestamp: 102},
        {blockNumber: 103, blockHash: "0x103-reorged", blockTimestamp: 103},
      ])

      // Clean up pending calls from before rollback
      sourceMock100.resolveGetItemsOrThrow([], ~resolveAt=#all)
      sourceMock1337.resolveGetItemsOrThrow([], ~resolveAt=#all)

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
          {value: "102", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "102", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
        ~message="Progress block number after rollback",
      )

      Assert.deepEqual(
        (
          sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.first,
          sourceMock100.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.first,
        ),
        (
          // Chain 1337: partition DELETED (lfb > target), recreated fresh
          Some({
            "fromBlock": 103,
            "toBlock": None,
            "retry": 0,
            "p": "0",
          }),
          // Chain 100: partition KEPT (lfb <= target), chunk history preserved
          Some({
            "fromBlock": 103,
            "toBlock": Some(106),
            "retry": 0,
            "p": "0",
          }),
        ),
        ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
      )

      // Set the same value as before rollback
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
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
            blockNumber: 104,
            logIndex: 2,
            handler,
          },
        ],
        ~resolveAt=#first,
        ~latestFetchedBlockNumber=104,
      )
      sourceMock1337.resolveGetItemsOrThrow([], ~resolveAt=#first, ~latestFetchedBlockNumber=104)

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
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
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
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
            },
            // Block 102 for chain 100 is skipped,
            // since it doesn't have events processed or block hash
            {
              id: 9.,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 103,
              blockHash: Js.Null.Null,
            },
            {
              id: 10.,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 104,
              blockHash: Js.Null.Value("0x104"),
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
    "Should NOT be in reorg threshold on restart when DB is only initialized (sourceBlockNumber=0, progressBlockNumber=-1)",
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

      Assert.deepEqual(
        await indexerMock.metric("envio_reorg_threshold"),
        [{value: "0", labels: Js.Dict.empty()}],
        ~message="Should NOT be in reorg threshold when we just created the indexer",
      )

      // Restart immediately without writing any batches
      // At this point: progressBlockNumber=-1, sourceBlockNumber=0 in DB
      let indexerMock = await indexerMock.restart()
      await Utils.delay(0)

      Assert.deepEqual(
        await indexerMock.metric("envio_reorg_threshold"),
        [{value: "0", labels: Js.Dict.empty()}],
        ~message="Should NOT be in reorg threshold when sourceBlockNumber is 0 and DB just initialized",
      )
    },
  )

  Async.it("Should NOT have duplicate queries after rollback with chunked partitions", async () => {
    // 1. Setup mock source and indexer
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

    // 3. Process 2 queries to build chunk history (3+ block ranges each)
    // Query 1: 101-103 (range=3) -> enables prevQueryRange=3
    switch sourceMock.getItemsOrThrowCalls {
    | [call] => call.resolve([], ~latestFetchedBlockNumber=103)
    | _ => Assert.fail("Step 3 should have a single pending call")
    }
    await indexerMock.getBatchWritePromise()

    // Query 2: 104-106 (range=3) -> enables prevPrevQueryRange=3
    // After this, chunking will be enabled with chunkRange=min(3,3)=3
    // A new query batch should be created with chunks
    switch sourceMock.getItemsOrThrowCalls {
    | [call] => call.resolve([], ~latestFetchedBlockNumber=106)
    | _ => Assert.fail("Step 3 should have a single pending call")
    }
    await indexerMock.getBatchWritePromise()

    // 4. Verify chunked queries are created (queries with toBlock set)
    // chunkRange=3, chunkSize=ceil(5.4)=6 -> 2 chunks per fetchNextQuery call
    // fetchNextQuery is called twice (on response handling and batch write), so 4 chunks total
    switch sourceMock.getItemsOrThrowCalls {
    | [chunk1, chunk2, chunk3, chunk4] =>
      Assert.deepEqual(
        (chunk1.payload, chunk2.payload, chunk3.payload, chunk4.payload),
        (
          {"fromBlock": 107, "toBlock": Some(112), "retry": 0, "p": "0"},
          {"fromBlock": 113, "toBlock": Some(118), "retry": 0, "p": "0"},
          {"fromBlock": 119, "toBlock": Some(124), "retry": 0, "p": "0"},
          {"fromBlock": 125, "toBlock": Some(130), "retry": 0, "p": "0"},
        ),
        ~message=`Should create 2 chunks per fetchNextQuery call.
The 3-4 chunks are not really expected, but created since we call fetchNextQuery twice:
- on response handling
- on batch write finish`,
      )

      // 5. Resolve LAST chunk of first batch FIRST with PARTIAL range: 113-115 instead of 113-118
      // This leaves a gap at 116-118 in the same partition (no new partition created)
      chunk2.resolve([], ~latestFetchedBlockNumber=115)

      // 6. Resolve first chunk normally (107-112)
      // Main partition consumes up to 115, detects gap before 119, creates gap-fill query
      chunk1.resolve([], ~latestFetchedBlockNumber=112)

      await indexerMock.getBatchWritePromise()

      Assert.deepEqual(
        sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
        [
          chunk3.payload,
          chunk4.payload,
          {
            "fromBlock": 116,
            "toBlock": Some(118),
            "retry": 0,
            // Gap-fill query for the partial chunk range, same partition
            "p": "0",
          },
          {
            "fromBlock": 131,
            "toBlock": Some(136),
            "retry": 0,
            "p": "0",
          },
          {
            "fromBlock": 137,
            "toBlock": Some(142),
            "retry": 0,
            "p": "0",
          },
          {
            "fromBlock": 143,
            "p": "0",
            "retry": 0,
            "toBlock": Some(148),
          },
          {
            "fromBlock": 149,
            "p": "0",
            "retry": 0,
            "toBlock": Some(154),
          },
          {
            "fromBlock": 155,
            "p": "0",
            "retry": 0,
            "toBlock": Some(160),
          },
          {
            "fromBlock": 161,
            "p": "0",
            "retry": 0,
            "toBlock": Some(166),
          },
        ],
        ~message="Should create gap-fill query for partial chunk range in same partition",
      )

    | _ => Assert.fail("Step 4 should have 4 chunks")
    }

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

    Assert.deepEqual(
      sourceMock.getBlockHashesCalls,
      [[100, 103, 106, 112]],
      ~message="Should have called getBlockHashes to find rollback depth",
    )

    // Rollback to block 112
    sourceMock.resolveGetBlockHashes([
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 103, blockHash: "0x103", blockTimestamp: 100},
      {blockNumber: 106, blockHash: "0x106", blockTimestamp: 100},
      {blockNumber: 112, blockHash: "0x112", blockTimestamp: 100},
    ])

    // Clean up pending calls from before rollback
    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all)

    await indexerMock.getRollbackReadyPromise()

    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      [
        // Partition recreated fresh (no chunk history), single unchunked query
        {
          "fromBlock": 115,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        },
      ],
      ~message="Should NOT have duplicate queries - only partition 0, no partition 1",
    )
  })

  Async.it(
    "Should efficiently refetch only blocks after rollback target with chunked partitions",
    async () => {
      // Setup mock source and indexer
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

      // Query 1: 101-103 (range=3) -> enables prevQueryRange=3
      switch sourceMock.getItemsOrThrowCalls {
      | [call] => call.resolve([], ~latestFetchedBlockNumber=103)
      | _ => Assert.fail("Should have a single pending call for query 1")
      }
      await indexerMock.getBatchWritePromise()

      // Query 2: 104-106 (range=3) -> enables prevPrevQueryRange=3
      // After this, chunking will be enabled with chunkRange=min(3,3)=3
      switch sourceMock.getItemsOrThrowCalls {
      | [call] => call.resolve([], ~latestFetchedBlockNumber=106)
      | _ => Assert.fail("Should have a single pending call for query 2")
      }
      await indexerMock.getBatchWritePromise()

      // Chunked queries: chunk1=107-112, chunk2=113-118
      // chunkRange=3, chunkSize=ceil(5.4)=6
      let calls = sourceMock.getItemsOrThrowCalls
      Assert.ok(calls->Array.length >= 2, ~message="Should have at least 2 chunked queries")
      let chunk1 = calls->Array.getUnsafe(0)
      let chunk2 = calls->Array.getUnsafe(1)
      Assert.deepEqual(
        (chunk1.payload, chunk2.payload),
        (
          {"fromBlock": 107, "toBlock": Some(112), "retry": 0, "p": "0"},
          {"fromBlock": 113, "toBlock": Some(118), "retry": 0, "p": "0"},
        ),
        ~message="Should create chunked queries",
      )

      // Resolve chunk1 to half its range, chunk2 to half its range
      chunk1.resolve([], ~latestFetchedBlockNumber=109) // half of 107-112
      chunk2.resolve([], ~latestFetchedBlockNumber=115) // first half of 113-118, stores checkpoint at 115
      await indexerMock.getBatchWritePromise()
      // lfb=109 (chunk2 unconsumed due to gap 110-112)

      // Resolve chunk2's second half: continuation from 116+ resolves to 118
      // This stores a reorg checkpoint at block 118
      let continuationCall = sourceMock.getItemsOrThrowCalls->Array.getUnsafe(1)
      Assert.ok(
        continuationCall.payload["fromBlock"] >= 116,
        ~message=`Continuation should start from >= 116, got ${continuationCall.payload["fromBlock"]->Int.toString}`,
      )
      continuationCall.resolve([], ~latestFetchedBlockNumber=118)
      await Utils.delay(0)

      // Trigger rollback: prevRangeLastBlock at 118 with reorged hash
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={
          blockNumber: 118,
          blockHash: "0x118-reorged",
        },
        ~resolveAt=#first,
      )
      await Utils.delay(0)
      await Utils.delay(0)

      // Stored checkpoints below reorgBlockNumber(118): [100, 103, 106, 109, 112, 115]
      Assert.deepEqual(
        sourceMock.getBlockHashesCalls,
        [[100, 103, 106, 109, 112, 115]],
        ~message="Should have called getBlockHashes to find rollback depth",
      )

      // All blocks up to 115 are valid -> rollback target = 115
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

      // After rollback to 115:
      // - lfb=109 (unchanged), chunk2 survives with fetchedBlock=115
      // - continuation(116+) removed (fromBlock > 115)
      // Two queries expected:
      //   1. Gap-fill finishing chunk1 range (fromBlock=110)
      //   2. After rollback target (fromBlock=116)
      let queries = sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)

      Assert.deepEqual(
        queries,
        [
          {
            "fromBlock": 110,
            "p": "0",
            "retry": 0,
            "toBlock": Some(112),
          },
          {
            "fromBlock": 116,
            "p": "0",
            "retry": 0,
            "toBlock": Some(121),
          },
          {
            "fromBlock": 122,
            "p": "0",
            "retry": 0,
            "toBlock": Some(127),
          },
        ],
        ~message="First query should finish chunk1 range starting from block 110, Second query should start after rollback target at block 116",
      )
    },
  )

  Async.it(
    "Repro: infinite rollback loop when deep reorg reaches threshold boundary",
    async () => {
      // Setup: knownHeight=300, maxReorgDepth=200, threshold=100
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
      // dataByBlockNumber now has block 100 with hash "0x100"

      // Index block 101, which also registers block 101 in dataByBlockNumber
      sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=101)
      await indexerMock.getBatchWritePromise()

      // Trigger reorg at block 101 (above threshold — a valid reorg)
      // via prevRangeLastBlock having a different hash for block 101
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={blockNumber: 101, blockHash: "0x101-reorged"},
      )
      await Utils.delay(0)
      await Utils.delay(0)

      // getThresholdBlockNumbersBelowBlock(~blockNumber=101) returns [100]
      // (blocks >= 100 AND < 101), so getBlockHashes IS called for block 100
      Assert.deepEqual(
        sourceMock.getBlockHashesCalls,
        [[100]],
        ~message="Should call getBlockHashes to find rollback depth",
      )

      // Deep reorg: block 100 (the threshold block) ALSO changed its hash.
      // getLatestValidScannedBlock finds no match → returns None.
      // Fallback: getHighestBlockBelowThreshold = 300 - 200 = 100.
      // BUG: rollbackToValidBlockNumber(~blockNumber=100) keeps block 100
      // with old hash "0x100" because it uses <= (inclusive).
      sourceMock.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x100-deep-reorg", blockTimestamp: 100},
      ])

      await indexerMock.getRollbackReadyPromise()

      // Verify re-fetch starts from 101
      Assert.deepEqual(
        sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
        Some({
          "fromBlock": 101,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        }),
        ~message="Should re-fetch from block 101",
      )

      // Re-fetch response: the source now provides the post-reorg hash for block 100
      // via prevRangeLastBlock (parent hash of the first block in the range)
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=101,
        ~prevRangeLastBlock={blockNumber: 100, blockHash: "0x100-deep-reorg"},
      )

      // BUG: This triggers a SECOND reorg detection at block 100 because
      // dataByBlockNumber[100] still has "0x100" but prevRangeLastBlock has "0x100-deep-reorg".
      // This creates an infinite loop: each rollback keeps block 100 with the old hash,
      // and each re-fetch detects the mismatch again.
      await Utils.delay(0)
      await Utils.delay(0)
      await Utils.delay(0)
      await indexerMock.getRollbackReadyPromise()

      // Verify: a second rollback happened, proving the infinite loop.
      Assert.deepEqual(
        await indexerMock.metric("envio_rollback_count"),
        [{value: "2", labels: Js.Dict.empty()}],
        ~message="BUG REPRO: Second reorg detected, proving the infinite rollback loop",
      )
    },
  )
})
