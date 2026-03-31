open Belt
open Vitest

// A workaround for ReScript v11 issue, where it makes the field optional
// instead of setting a value to undefined. It's fixed in v12.
let undefined = (%raw(`undefined`): option<'a>)

describe("E2E rollback tests", () => {
  let testSingleChainRollback = async (
    ~t,
    ~sourceMock: Mock.Source.t,
    ~indexerMock: Mock.Indexer.t,
    ~firstHistoryCheckpointId=2n,
  ) => {
    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
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
    ).toEqual(
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
      ),
    )

    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
    ).toEqual(
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
    ).toEqual(
      [[100]],
    )
    sourceMock.resolveGetBlockHashes([
      // The block 100 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
    ])

    await indexerMock.getRollbackReadyPromise()

    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
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
    ).toEqual(
      (
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
      ),
    )
  }

  Async.it(
    "Should stay in reorg threshold on restart when progress is past threshold",
    async t => {
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
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
      ))

      t.expect(
        sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
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

      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
      ).toEqual(
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
      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
      ).toEqual(
        [{value: "1", labels: Js.Dict.empty()}],
      )

      // After restart, both chains have knownHeight from sourceBlockNumber,
      // so they don't need to call getHeightOrThrow
      t.expect(
        sourceMock1337.getHeightOrThrowCalls->Array.length,
        ~message="should not call getHeightOrThrow on restart (uses sourceBlockNumber as knownHeight)",
      ).toEqual(
        0,
      )

      // Both chains are ready immediately, so chain 1337 should continue fetching
      t.expect(
        sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
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
        sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
        ~message="Continue normally inside of the reorg threshold",
      ).toEqual(
        Some({
          "fromBlock": 201,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        }),
      )

      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
      ).toEqual(
        [{value: "1", labels: Js.Dict.empty()}],
      )
    },
  )

  Async.it("Rollback of a single chain indexer", async t => {
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

    await Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)
    await testSingleChainRollback(~t, ~sourceMock, ~indexerMock)
  })

  Async.it(
    "Stores checkpoints inside of the reorg threshold for batches without items",
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
      )
      await Utils.delay(0)

      await Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

      sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=102)

      await indexerMock.getBatchWritePromise()

      t.expect(
        await indexerMock.queryCheckpoints(),
        ~message="Should have added a checkpoint even though there are no items in the batch",
      ).toEqual(
        [
          {
            id: 2n,
            eventsProcessed: 0,
            chainId: 1337,
            blockNumber: 102,
            blockHash: Js.Null.Value("0x102"),
          },
        ],
      )
    },
  )

  Async.it("Shouldn't detect reorg for rollbacked block", async t => {
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

    await Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

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
    ).toEqual(
      [[100]],
    )
    sourceMock.resolveGetBlockHashes([
      // The block 100 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
    ])

    await indexerMock.getRollbackReadyPromise()
    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      ~message="Should rollback fetch state and re-request items",
    ).toEqual(
      [
        {
          "fromBlock": 101,
          "toBlock": None,
          "retry": 0,
          // IDs reset on rollback, recreated partition starts at 0
          "p": "0",
        },
      ],
    )

    sourceMock.resolveGetItemsOrThrow(
      [],
      ~latestFetchedBlockNumber=102,
      ~latestFetchedBlockHash="0x102-reorged",
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      await indexerMock.queryCheckpoints(),
      ~message="Should update the checkpoint without retriggering a reorg",
    ).toEqual(
      [
        {
          id: 4n,
          eventsProcessed: 0,
          chainId: 1337,
          blockNumber: 102,
          blockHash: Js.Null.Value("0x102-reorged"),
        },
      ],
    )
  })

  Async.it(
    "Single chain rollback should also work for unordered multichain indexer when another chains are stale",
    async t => {
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
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1),
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock2),
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

    await Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

    let calls = []
    let handler = async (
      {event}: Internal.genericHandlerArgs<Indexer.eventLog<unknown>, Indexer.handlerContext>,
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
            context.addSimpleNft(Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0))
          },
          handler,
        },
        {
          blockNumber: 103,
          logIndex: 2,
          contractRegister: async ({context}) => {
            context.addSimpleNft(Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(1))
          },
          handler,
        },
        {
          blockNumber: 104,
          logIndex: 2,
          contractRegister: async ({context}) => {
            context.addSimpleNft(Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(2))
          },
          handler,
        },
      ],
      ~latestFetchedBlockNumber=104,
    )


    await indexerMock.getBatchWritePromise()


    t.expect(
      (calls, sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)),
      ~message=`Creates a new partition for DCs and queries it in parallel with the original partition without blocking`,
    ).toEqual(
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
    )
    t.expect(
      await (indexerMock.queryRaw(InternalTable.DynamicContractRegistry.entityConfig): promise<array<InternalTable.DynamicContractRegistry.t>>),
      ~message="Shouldn't store dynamic contracts at this point",
    ).toEqual(
      [],
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

    t.expect(
      (calls, sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)),
      ~message=`Should process the block 102 after DC partition finished fetching it`,
    ).toEqual(
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
    )
    t.expect(
      await (indexerMock.queryRaw(InternalTable.DynamicContractRegistry.entityConfig): promise<array<InternalTable.DynamicContractRegistry.t>>),
      ~message="Added the processed dynamic contract to the db",
    ).toEqual(
      [
        {
          id: `1337-${Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0)->Address.toString}`,
          chainId: 1337,
          registeringEventBlockNumber: 102,
          registeringEventLogIndex: 2,
          registeringEventBlockTimestamp: 102,
          registeringEventContractName: "MockContract",
          registeringEventName: "MockEvent",
          registeringEventSrcAddress: "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
          contractAddress: Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0),
          contractName: "SimpleNft",
        },
      ],
    )

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#last, ~latestFetchedBlockNumber=103)

    await indexerMock.getBatchWritePromise()

    t.expect(
      (await (indexerMock.queryRaw(InternalTable.DynamicContractRegistry.entityConfig): promise<array<InternalTable.DynamicContractRegistry.t>>))->Array.length,
      ~message="Should add the processed dynamic contracts to the db",
    ).toEqual(
      2,
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

    t.expect(
      sourceMock.getBlockHashesCalls,
      ~message="Should have called getBlockHashes to find rollback depth",
    ).toEqual(
      [[100, 101, 102]],
    )
    sourceMock.resolveGetBlockHashes([
      // The block 102 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
      {blockNumber: 102, blockHash: "0x102", blockTimestamp: 102},
    ])

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all)


    await indexerMock.getRollbackReadyPromise()


    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      ~message="Should rollback fetch state and re-request items",
    ).toEqual(
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
    )

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#first, ~latestFetchedBlockNumber=104)
    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#first, ~latestFetchedBlockNumber=104)

    // Wait for empty batches to process and new queries to be dispatched.
    // Background writes add microtask yields that delay query dispatching.
    while sourceMock.getItemsOrThrowCalls->Array.length === 0 {
      await Utils.delay(1)
    }

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
      await (indexerMock.queryRaw(InternalTable.DynamicContractRegistry.entityConfig): promise<array<InternalTable.DynamicContractRegistry.t>>),
      ~message="Should have only one dynamic contract in the db. The second one rollbacked from db, the third one rollbacked from fetch state",
    ).toEqual(
      [
        {
          id: `1337-${Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0)->Address.toString}`,
          chainId: 1337,
          registeringEventBlockNumber: 102,
          registeringEventLogIndex: 2,
          registeringEventBlockTimestamp: 102,
          registeringEventContractName: "MockContract",
          registeringEventName: "MockEvent",
          registeringEventSrcAddress: "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
          contractAddress: Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0),
          contractName: "SimpleNft",
        },
      ],
    )
    // After the db rollback, both partitions continue from block 105 (no chunk history yet)
    let payloads = sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)
    t.expect(
      payloads->Js.Array2.map(p => (p["p"], p["fromBlock"], p["toBlock"])),
      ~message="Should correctly continue fetching from block 105 after rolling back the db",
    ).toEqual(
      [("2", 105, None), ("0", 105, None)],
    )
  })

  Async.it("Rollback of unordered multichain indexer (single entity id change)", async t => {
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
      {context}: Internal.genericHandlerArgs<Indexer.eventLog<unknown>, Indexer.handlerContext>,
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
    ).toEqual(
      (
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
      ),
    )

    t.expect(
      {
        let metrics = await indexerMock.metric("envio_progress_events")
        // For some reason the test returns the metrics in different order
        metrics->Js.Array2.sortInPlaceWith((a, b) => a.value->Obj.magic - b.value->Obj.magic)
      },
      ~message="Events count before rollback",
    ).toEqual(
      [
        {value: "2", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "4", labels: Js.Dict.fromArray([("chainId", "1337")])},
      ],
    )
    t.expect(
      {
        let metrics = await indexerMock.metric("envio_progress_block")
        // For some reason the test returns the metrics in different order
        metrics->Js.Array2.sortInPlaceWith((a, b) => a.value->Obj.magic - b.value->Obj.magic)
      },
      ~message="Progress block number before rollback",
    ).toEqual(
      [
        {value: "106", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "109", labels: Js.Dict.fromArray([("chainId", "1337")])},
      ],
    )
    t.expect(
      await indexerMock.metric("envio_rollback_events"),
      ~message="Rollbacked events count before rollback",
    ).toEqual(
      [{value: "0", labels: Js.Dict.empty()}],
    )
    t.expect(
      await indexerMock.metric("envio_rollback_total"),
      ~message="Rollbacks count before rollback",
    ).toEqual(
      [{value: "0", labels: Js.Dict.empty()}],
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

    t.expect(
      sourceMock1337.getBlockHashesCalls,
      ~message="Should have called getBlockHashes to find rollback depth",
    ).toEqual(
      [[100, 103]],
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

    t.expect(
      await indexerMock.metric("envio_progress_events"),
      ~message="Events count after rollback",
    ).toEqual(
      [
        {value: "1", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "2", labels: Js.Dict.fromArray([("chainId", "1337")])},
      ],
    )
    t.expect(
      await indexerMock.metric("envio_progress_block"),
      ~message="Progress block number after rollback",
    ).toEqual(
      [
        {value: "105", labels: Js.Dict.fromArray([("chainId", "100")])},
        {value: "105", labels: Js.Dict.fromArray([("chainId", "1337")])},
      ],
    )
    t.expect(
      await indexerMock.metric("envio_rollback_events"),
      ~message="Rollbacked events count after rollback",
    ).toEqual(
      [{value: "3", labels: Js.Dict.empty()}],
    )
    t.expect(
      await indexerMock.metric("envio_rollback_total"),
      ~message="Rollbacks count after rollback",
    ).toEqual(
      [{value: "1", labels: Js.Dict.empty()}],
    )

    t.expect(
      (
        sourceMock100.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
        sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      ),
      ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
    ).toEqual(
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
    )

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
    ).toEqual(
      (
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
            blockNumber: 111,
            blockHash: Js.Null.Value("0x111"),
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
      ),
    )
  })

  // Fixes duplicate history bug before 2.31
  Async.it(
    "Rollback of unordered multichain indexer (single entity id change + another entity on non-reorg chain)",
    async t => {
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
        {context}: Internal.genericHandlerArgs<Indexer.eventLog<unknown>, Indexer.handlerContext>,
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
      ).toEqual(
        (
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
        ),
      )
      t.expect(
        await Promise.all2((
          indexerMock.query(EntityWithBigDecimal),
          indexerMock.queryHistory(EntityWithBigDecimal),
        )),
        ~message="Should also add another entity for a non-reorg chain, which should also be rollbacked",
      ).toEqual(
        (
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
        ),
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

      t.expect(
        sourceMock1337.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual(
        [[100, 103]],
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

      t.expect(
        (
          sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.first,
          sourceMock100.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.first,
        ),
        ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
      ).toEqual(
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
      )

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
      ).toEqual(
        (
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
              blockNumber: 111,
              blockHash: Js.Null.Value("0x111"),
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
        ),
      )
      t.expect(
        await Promise.all2((
          indexerMock.query(EntityWithBigDecimal),
          indexerMock.queryHistory(EntityWithBigDecimal),
        )),
        ~message="Should also add another entity for a non-reorg chain, which should also be rollbacked (theoretically)",
      ).toEqual(
        (
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
        ),
      )
    },
  )

  Async.it(
    "Rollback of ordered multichain indexer (single entity id change + another entity on non-reorg chain)",
    async t => {
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
        {context}: Internal.genericHandlerArgs<Indexer.eventLog<unknown>, Indexer.handlerContext>,
      ) => {
        context.\"SimpleEntity".set({
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
              context.\"EntityWithBigDecimal".set({
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

      t.expect(
        await Promise.all3((
          indexerMock.queryCheckpoints(),
          indexerMock.query(SimpleEntity),
          indexerMock.queryHistory(SimpleEntity),
        )),
        ~message=`Should create multiple history rows:
Sorted by timestamp and chain id`,
      ).toEqual(
        (
          [
            {
              id: 2n,
              eventsProcessed: 0,
              chainId: 100,
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
            },
            {
              id: 3n,
              eventsProcessed: 0,
              chainId: 1337,
              blockNumber: 100,
              blockHash: Js.Null.Value("0x100"),
            },
            {
              id: 4n,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
            },
            {
              id: 5n,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 103,
              blockHash: Js.Null.Null,
            },
            {
              id: 6n,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 103,
              blockHash: Js.Null.Value("0x103"),
            },
            {
              id: 7n,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 104,
              blockHash: Js.Null.Value("0x104"),
            },
          ],
          [
            {
              Indexer.Entities.SimpleEntity.id: "1",
              value: "call-2",
            },
          ],
          [
            Set({
              checkpointId: 4n,
              entityId: "1",
              entity: {
                Indexer.Entities.SimpleEntity.id: "1",
                value: "call-0",
              },
            }),
            Set({
              checkpointId: 6n,
              entityId: "1",
              entity: {
                Indexer.Entities.SimpleEntity.id: "1",
                value: "call-1",
              },
            }),
            Set({
              checkpointId: 7n,
              entityId: "1",
              entity: {
                Indexer.Entities.SimpleEntity.id: "1",
                value: "call-2",
              },
            }),
          ],
        ),
      )
      t.expect(
        await Promise.all2((
          indexerMock.query(EntityWithBigDecimal),
          indexerMock.queryHistory(EntityWithBigDecimal),
        )),
        ~message="Should also add another entity for a non-reorg chain, which should also be rollbacked (theoretically)",
      ).toEqual(
        (
          [
            {
              id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            },
          ],
          [
            Set({
              checkpointId: 5n,
              entityId: "foo",
              entity: {
                Indexer.Entities.EntityWithBigDecimal.id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              },
            }),
          ],
        ),
      )

      t.expect(
        await indexerMock.metric("envio_progress_events"),
        ~message="Events count before rollback",
      ).toEqual(
        [
          {value: "2", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "2", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
      )
      t.expect(
        await indexerMock.metric("envio_progress_block"),
        ~message="Progress block number before rollback",
      ).toEqual(
        [
          {value: "104", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "103", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
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

      t.expect(
        sourceMock1337.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual(
        [[100, 102, 103]],
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

      t.expect(
        await indexerMock.metric("envio_progress_events"),
        ~message="Events count after rollback",
      ).toEqual(
        [
          {value: "0", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "1", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
      )
      t.expect(
        await indexerMock.metric("envio_progress_block"),
        ~message="Progress block number after rollback",
      ).toEqual(
        [
          {value: "102", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "102", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
      )

      t.expect(
        (
          sourceMock1337.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.first,
          sourceMock100.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.first,
        ),
        ~message="Should rollback fetch state and re-request items for both chains (since chain 100 was touching the same entity as chain 1337)",
      ).toEqual(
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
      )

      // Set the same value as before rollback
      sourceMock100.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 2,
            handler: async ({context}) => {
              context.\"EntityWithBigDecimal".set({
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

      t.expect(
        await Promise.all3((
          indexerMock.queryCheckpoints(),
          indexerMock.query(SimpleEntity),
          indexerMock.queryHistory(SimpleEntity),
        )),
      ).toEqual(
        (
          [
            {
              id: 2n,
              eventsProcessed: 0,
              chainId: 100,
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
            },
            {
              id: 3n,
              eventsProcessed: 0,
              chainId: 1337,
              blockNumber: 100,
              blockHash: Js.Null.Value("0x100"),
            },
            {
              id: 4n,
              eventsProcessed: 1,
              chainId: 1337,
              blockNumber: 102,
              blockHash: Js.Null.Value("0x102"),
            },
            // Block 102 for chain 100 is skipped,
            // since it doesn't have events processed or block hash
            {
              id: 9n,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 103,
              blockHash: Js.Null.Null,
            },
            {
              id: 10n,
              eventsProcessed: 1,
              chainId: 100,
              blockNumber: 104,
              blockHash: Js.Null.Value("0x104"),
            },
          ],
          [
            {
              Indexer.Entities.SimpleEntity.id: "1",
              value: "call-3",
            },
          ],
          [
            Set({
              checkpointId: 4n,
              entityId: "1",
              entity: {
                Indexer.Entities.SimpleEntity.id: "1",
                value: "call-0",
              },
            }),
            Set({
              checkpointId: 10n,
              entityId: "1",
              entity: {
                Indexer.Entities.SimpleEntity.id: "1",
                value: "call-3",
              },
            }),
          ],
        ),
      )
      t.expect(
        await Promise.all2((
          indexerMock.query(EntityWithBigDecimal),
          indexerMock.queryHistory(EntityWithBigDecimal),
        )),
        ~message="Should also add another entity for a non-reorg chain, which should also be rollbacked (theoretically)",
      ).toEqual(
        (
          [
            {
              id: "foo",
              bigDecimal: BigDecimal.fromFloat(0.),
            },
          ],
          [
            Set({
              checkpointId: 9n,
              entityId: "foo",
              entity: {
                Indexer.Entities.EntityWithBigDecimal.id: "foo",
                bigDecimal: BigDecimal.fromFloat(0.),
              },
            }),
          ],
        ),
      )
    },
  )

  Async.it("Double reorg should NOT cause negative event counter (regression test)", async t => {
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

    await Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

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
    ).toEqual(
      [{value: "1", labels: Js.Dict.fromArray([("chainId", "1337")])}],
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

    t.expect(
      sourceMock.getBlockHashesCalls,
      ~message="Should have called getBlockHashes for first reorg",
    ).toEqual(
      [[100, 101]],
    )

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
    ).toEqual(
      [{value: "0", labels: Js.Dict.fromArray([("chainId", "1337")])}],
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

    t.expect(
      sourceMock.getBlockHashesCalls,
      ~message="Should have called getBlockHashes for second reorg",
    ).toEqual(
      [[100, 101], [100]],
    )
    // Rollback to block 100 - blocks 101-103 are reorged
    sourceMock.resolveGetBlockHashes([{blockNumber: 100, blockHash: "0x100", blockTimestamp: 100}])
    await indexerMock.getRollbackReadyPromise()

    // Check metrics after processing - should have 2 events
    t.expect(
      await indexerMock.metric("envio_progress_events"),
      ~message="Shouldn't go to negative with the counter",
    ).toEqual(
      [{value: "0", labels: Js.Dict.fromArray([("chainId", "1337")])}],
    )

    // Process batch after rollback
    sourceMock.resolveGetItemsOrThrow([])
    await indexerMock.getBatchWritePromise()

    t.expect(
      await indexerMock.query(SimpleEntity),
      ~message="Should have all entities rolled back",
    ).toEqual(
      [],
    )
  })

  Async.it(
    "Should NOT be in reorg threshold on restart when DB is only initialized (sourceBlockNumber=0, progressBlockNumber=-1)",
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
      )

      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
        ~message="Should NOT be in reorg threshold when we just created the indexer",
      ).toEqual(
        [{value: "0", labels: Js.Dict.empty()}],
      )

      // Restart immediately without writing any batches
      // At this point: progressBlockNumber=-1, sourceBlockNumber=0 in DB
      let indexerMock = await indexerMock.restart()
      await Utils.delay(0)

      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
        ~message="Should NOT be in reorg threshold when sourceBlockNumber is 0 and DB just initialized",
      ).toEqual(
        [{value: "0", labels: Js.Dict.empty()}],
      )
    },
  )

  Async.it(
    "Multi-chain reorg→rollback→reorg loop: reorg chain repeatedly reorgs while other chain's events get rolled back each time (negative counter regression)",
    async t => {
      // Reproduces the bug where:
      // 1. Both chains process events, then chain 1337 detects reorg → rollback to block 100
      // 2. After rollback, chain 1337 detects ANOTHER reorg at block 100 → rollback to block 100 again
      // 3. Second rollback subtracts events that were already rolled back → counter goes negative
      // The root cause: only the reorg chain's counter is restored (line 412-424 in GlobalState),
      // but the non-reorg chain's counter stays at 0 while DB still has the old checkpoints.
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

      // Both chains enter reorg threshold (blocks 1-100 fetched, knownHeight=300)
      let _ = await Promise.all2((
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
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
          metrics->Js.Array2.sortInPlaceWith((a, b) => a.value->Obj.magic - b.value->Obj.magic)
        },
        ~message="Events count before rollback",
      ).toEqual(
        [
          {value: "1", labels: Js.Dict.fromArray([("chainId", "1337")])},
          {value: "2", labels: Js.Dict.fromArray([("chainId", "100")])},
        ],
      )

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
          metrics->Js.Array2.sortInPlaceWith((a, b) => a.value->Obj.magic - b.value->Obj.magic)
        },
        ~message="After first rollback: all events should be rolled back to 0",
      ).toEqual(
        [
          {value: "0", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "0", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
      )

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
      // Only chain 1337's counter was restored (GlobalState line 412-424),
      // but chain 100's counter stayed at 0 while DB still had the old checkpoints.
      t.expect(
        {
          let metrics = await indexerMock.metric("envio_progress_events")
          metrics->Js.Array2.sortInPlaceWith((a, b) =>
            (a.labels->Js.Dict.get("chainId")->Option.getWithDefault(""))->Obj.magic -
              (b.labels->Js.Dict.get("chainId")->Option.getWithDefault(""))->Obj.magic
          )
        },
        ~message="After second rollback: event counters should NOT be negative",
      ).toEqual(
        [
          {value: "0", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "0", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
      )
    },
  )

  Async.it(
    "Reorg-on-reorg restores ALL chains' counters, not just the reorg chain's",
    async t => {
      // Root cause test: validatePartitionQueryResponse must restore counters
      // for every chain when re-reorging from RollbackReady state.
      // Without the fix, only the reorg chain's counter is restored,
      // causing non-reorg chains to go negative on the second rollback.
      let sourceMock1337 = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMock100 = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      let sourceMock137 = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#137,
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
          {
            chain: #137,
            sourceConfig: Config.CustomSources([sourceMock137.source]),
          },
        ],
      )
      await Utils.delay(0)

      // All three chains enter reorg threshold
      let _ = await Promise.all3((
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1337),
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock100),
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock137),
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
          metrics->Js.Array2.sortInPlaceWith((a, b) => a.value->Obj.magic - b.value->Obj.magic)
        },
        ~message="Events count before rollback: chain 1337=1, chain 100=2, chain 137=2",
      ).toEqual(
        [
          {value: "1", labels: Js.Dict.fromArray([("chainId", "1337")])},
          {value: "2", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "2", labels: Js.Dict.fromArray([("chainId", "137")])},
        ],
      )

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
          metrics->Js.Array2.sortInPlaceWith((a, b) =>
            (a.labels->Js.Dict.get("chainId")->Option.getWithDefault(""))->Obj.magic -
              (b.labels->Js.Dict.get("chainId")->Option.getWithDefault(""))->Obj.magic
          )
        },
        ~message="After first rollback: all chains' counters should be 0",
      ).toEqual(
        [
          {value: "0", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "0", labels: Js.Dict.fromArray([("chainId", "137")])},
          {value: "0", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
      )

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
          metrics->Js.Array2.sortInPlaceWith((a, b) =>
            (a.labels->Js.Dict.get("chainId")->Option.getWithDefault(""))->Obj.magic -
              (b.labels->Js.Dict.get("chainId")->Option.getWithDefault(""))->Obj.magic
          )
        },
        ~message="After second rollback: non-reorg chains (100, 137) must NOT go negative",
      ).toEqual(
        [
          {value: "0", labels: Js.Dict.fromArray([("chainId", "100")])},
          {value: "0", labels: Js.Dict.fromArray([("chainId", "137")])},
          {value: "0", labels: Js.Dict.fromArray([("chainId", "1337")])},
        ],
      )
    },
  )

  Async.it("Should NOT have duplicate queries after rollback with chunked partitions", async t => {
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

    await Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

    // 3. Process 2 queries to build chunk history (3+ block ranges each)
    // Query 1: 101-103 (range=3) -> enables prevQueryRange=3
    switch sourceMock.getItemsOrThrowCalls {
    | [call] => call.resolve([], ~latestFetchedBlockNumber=103)
    | _ => Js.Exn.raiseError("Step 3 should have a single pending call")
    }
    await indexerMock.getBatchWritePromise()

    // Query 2: 104-106 (range=3) -> enables prevPrevQueryRange=3
    // After this, chunking will be enabled with chunkRange=min(3,3)=3
    // A new query batch should be created with chunks
    switch sourceMock.getItemsOrThrowCalls {
    | [call] => call.resolve([], ~latestFetchedBlockNumber=106)
    | _ => Js.Exn.raiseError("Step 3 should have a single pending call")
    }
    await indexerMock.getBatchWritePromise()

    // 4. Verify chunked queries are created (queries with toBlock set)
    // chunkRange=3, chunkSize=ceil(5.4)=6 -> 2 chunks per fetchNextQuery call
    // fetchNextQuery is called twice (on response handling and batch write), so 4 chunks total
    switch sourceMock.getItemsOrThrowCalls {
    | [chunk1, chunk2, chunk3, chunk4] =>
      t.expect(
        (chunk1.payload, chunk2.payload, chunk3.payload, chunk4.payload),
        ~message=`Should create 2 chunks per fetchNextQuery call.
The 3-4 chunks are not really expected, but created since we call fetchNextQuery twice:
- on response handling
- on batch write finish`,
      ).toEqual(
        (
          {"fromBlock": 107, "toBlock": Some(112), "retry": 0, "p": "0"},
          {"fromBlock": 113, "toBlock": Some(118), "retry": 0, "p": "0"},
          {"fromBlock": 119, "toBlock": Some(124), "retry": 0, "p": "0"},
          {"fromBlock": 125, "toBlock": Some(130), "retry": 0, "p": "0"},
        ),
      )

      // 5. Resolve LAST chunk of first batch FIRST with PARTIAL range: 113-115 instead of 113-118
      // This leaves a gap at 116-118 in the same partition (no new partition created)
      chunk2.resolve([], ~latestFetchedBlockNumber=115)

      // 6. Resolve first chunk normally (107-112)
      // Main partition consumes up to 115, detects gap before 119, creates gap-fill query
      chunk1.resolve([], ~latestFetchedBlockNumber=112)

      await indexerMock.getBatchWritePromise()

      let expectedQueries = [
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
      ]
      t.expect(
        sourceMock.getItemsOrThrowCalls
        ->Js.Array2.map(c => c.payload)
        // Slice to avoid including potentially extra fetch queries
        ->Js.Array2.slice(~start=0, ~end_=expectedQueries->Js.Array2.length),
        ~message="Should create gap-fill query for partial chunk range in same partition",
      ).toEqual(expectedQueries)

    | _ => Js.Exn.raiseError("Step 4 should have 4 chunks")
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

    t.expect(
      sourceMock.getBlockHashesCalls,
      ~message="Should have called getBlockHashes to find rollback depth",
    ).toEqual(
      [[100, 103, 106, 112]],
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

    t.expect(
      sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload),
      ~message="Should NOT have duplicate queries - only partition 0, no partition 1",
    ).toEqual(
      [
        // Partition recreated fresh (no chunk history), single unchunked query
        {
          "fromBlock": 115,
          "toBlock": None,
          "retry": 0,
          "p": "0",
        },
      ],
    )
  })

  Async.it(
    "Should efficiently refetch only blocks after rollback target with chunked partitions",
    async t => {
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

      await Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

      // Query 1: 101-103 (range=3) -> enables prevQueryRange=3
      switch sourceMock.getItemsOrThrowCalls {
      | [call] => call.resolve([], ~latestFetchedBlockNumber=103)
      | _ => Js.Exn.raiseError("Should have a single pending call for query 1")
      }
      await indexerMock.getBatchWritePromise()

      // Query 2: 104-106 (range=3) -> enables prevPrevQueryRange=3
      // After this, chunking will be enabled with chunkRange=min(3,3)=3
      switch sourceMock.getItemsOrThrowCalls {
      | [call] => call.resolve([], ~latestFetchedBlockNumber=106)
      | _ => Js.Exn.raiseError("Should have a single pending call for query 2")
      }
      await indexerMock.getBatchWritePromise()

      // Chunked queries: chunk1=107-112, chunk2=113-118
      // chunkRange=3, chunkSize=ceil(5.4)=6
      let calls = sourceMock.getItemsOrThrowCalls
      t.expect(calls->Array.length >= 2, ~message="Should have at least 2 chunked queries").toBeTruthy()
      let chunk1 = calls->Array.getUnsafe(0)
      let chunk2 = calls->Array.getUnsafe(1)
      t.expect(
        (chunk1.payload, chunk2.payload),
        ~message="Should create chunked queries",
      ).toEqual(
        (
          {"fromBlock": 107, "toBlock": Some(112), "retry": 0, "p": "0"},
          {"fromBlock": 113, "toBlock": Some(118), "retry": 0, "p": "0"},
        ),
      )

      // Resolve chunk1 to half its range, chunk2 to half its range
      chunk1.resolve([], ~latestFetchedBlockNumber=109) // half of 107-112
      chunk2.resolve([], ~latestFetchedBlockNumber=115) // first half of 113-118, stores checkpoint at 115
      await indexerMock.getBatchWritePromise()
      // lfb=109 (chunk2 unconsumed due to gap 110-112)

      // Resolve chunk2's second half: continuation from 116+ resolves to 118
      // This stores a reorg checkpoint at block 118
      let continuationCall = switch sourceMock.getItemsOrThrowCalls->Js.Array2.find(call => {
        call.payload["fromBlock"] == 116
      }) {
      | Some(call) => call
      | None => Js.Exn.raiseError("Should have a pending continuation call with fromBlock == 116")
      }
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
      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual(
        [[100, 103, 106, 109, 112, 115]],
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

      t.expect(
        queries,
        ~message="First query should finish chunk1 range starting from block 110, Second query should start after rollback target at block 116",
      ).toEqual(
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
      )
    },
  )

  Async.it(
    "Should not enter infinite reorg loop when reorg chain has no events processed since target checkpoint",
    async t => {
      let sourceMock1 = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMock2 = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      // batchSize=1 ensures that chain 100's single event fills the batch,
      // causing chain 1337 to be SKIPPED in prepareUnorderedBatch.
      // This means chain 1337 gets no checkpoint at block 101.
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
        ~batchSize=1,
      )
      await Utils.delay(0)

      let _ = await Promise.all2((
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1),
        Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock2),
      ))

      // Chain 1337 fetches block 101 with 0 events.
      // registerReorgGuard stores block hash "0x101" for block 101.
      sourceMock1.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=101,
        ~resolveAt=#first,
      )

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
      ).toEqual(
        [[100]],
      )
      sourceMock1.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      ])

      await indexerMock.getRollbackReadyPromise()

      let actualPayloads = sourceMock1.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)
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
      ).toEqual(
        [],
      )
    },
  )
})
