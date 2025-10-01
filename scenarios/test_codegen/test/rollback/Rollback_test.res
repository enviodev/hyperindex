open Belt
open RescriptMocha

module M = Mock

let config = RegisterHandlers.registerAllHandlers()
// Keep only chain1337
let config = Config.make(
  ~shouldRollbackOnReorg=true,
  ~shouldSaveFullHistory=false,
  ~isUnorderedMultichainMode=false,
  ~chains=config.chainMap
  ->ChainMap.entries
  ->Array.keepMap(((chain, config)) => chain == MockConfig.chain1337 ? Some(config) : None),
  ~enableRawEvents=false,
  ~registrations=?config.registrations,
)

module Mock = {
  let mockChainDataEmpty = MockChainData.make(
    ~chainConfig=config.chainMap->ChainMap.get(MockConfig.chain1337),
    ~maxBlocksReturned=3,
    ~blockTimestampInterval=25,
  )

  open ChainDataHelpers.Gravatar
  let blocksBase = [
    [],
    [
      NewGravatar.mkEventConstr(MockEvents.newGravatar1),
      NewGravatar.mkEventConstr(MockEvents.newGravatar2),
    ],
  ]
  let blocksInitial =
    blocksBase->Array.concat([
      [UpdatedGravatar.mkEventConstr(MockEvents.setGravatar1)],
      [UpdatedGravatar.mkEventConstr(MockEvents.setGravatar2)],
      [
        NewGravatar.mkEventConstr(MockEvents.newGravatar3),
        UpdatedGravatar.mkEventConstr(MockEvents.setGravatar3),
      ],
    ])

  let blocksReorg =
    blocksBase->Array.concat([
      [UpdatedGravatar.mkEventConstr(MockEvents.setGravatar2)],
      [UpdatedGravatar.mkEventConstr(MockEvents.setGravatar1)],
      [
        NewGravatar.mkEventConstr(MockEvents.newGravatar3),
        UpdatedGravatar.mkEventConstr(MockEvents.setGravatar3),
      ],
    ])

  let applyBlocks = mcd =>
    mcd->Array.reduce(mockChainDataEmpty, (accum, next) => {
      accum->MockChainData.addBlock(~makeLogConstructors=next)
    })

  let mockChainData = blocksInitial->applyBlocks
  let mockChainDataReorg = blocksReorg->applyBlocks
}

module Stubs = {
  //Stub wait for new block
  let waitForNewBlock = async (_sourceManager, ~currentBlockHeight) => {
    currentBlockHeight->ignore
    Mock.mockChainData->MockChainData.getHeight
  }

  //Stub executePartitionQuery with mock data
  let executePartitionQueryWithMockChainData = mockChainData => async (
    _,
    ~query,
    ~currentBlockHeight as _,
  ) => {
    mockChainData->MockChainData.executeQuery(query)
  }

  //Stub for getting block hashes instead of the worker
  let getBlockHashes = mockChainData => async (~blockNumbers, ~logger as _) =>
    mockChainData->MockChainData.getBlockHashes(~blockNumbers)->Ok

  //Hold next tasks temporarily here so they do not get actioned off automatically
  let tasks = ref([])

  //Stub dispatch action to set state and not dispatch task but store in
  //the tasks ref
  let dispatchAction = (gsManager, action) => {
    let (nextState, nextTasks) = GlobalState.actionReducer(
      gsManager->GlobalStateManager.getState,
      action,
    )
    gsManager->GlobalStateManager.setState(nextState)
    tasks := tasks.contents->Array.concat(nextTasks)
  }

  let dispatchTask = (gsManager, mockChainData, task) => {
    GlobalState.injectedTaskReducer(
      ~executeQuery=executePartitionQueryWithMockChainData(mockChainData),
      ~waitForNewBlock,
      ~getLastKnownValidBlock=chainFetcher =>
        chainFetcher->ChainFetcher.getLastKnownValidBlock(
          ~getBlockHashes=getBlockHashes(mockChainData),
        ),
    )(
      ~dispatchAction=action => dispatchAction(gsManager, action),
      gsManager->GlobalStateManager.getState,
      task,
    )
  }

  let dispatchAllTasks = async (gsManager, mockChainData) => {
    let tasksToRun = tasks.contents
    tasks := []
    let _ =
      await tasksToRun
      ->Array.map(task => dispatchTask(gsManager, mockChainData, task))
      ->Js.Promise.all
  }
}

module Sql = {
  /**
NOTE: Do not use this for queries in the indexer

Exposing
*/
  @send
  external unsafe: (Postgres.sql, string) => promise<'a> = "unsafe"

  let query = unsafe(Db.sql, _)

  let getAllRowsInTable = tableName => query(`SELECT * FROM public."${tableName}";`)
}

let setupDb = async () => {
  open Migrations
  Logging.info("Provisioning Database")
  let _exitCodeUp = await runUpMigrations(~shouldExit=false, ~reset=true)
}

describe("Single Chain Simple Rollback", () => {
  Async.it("Detects reorgs and actions a rollback", async () => {
    await setupDb()

    let chainManager = ChainManager.makeFromConfig(~config)
    let initState = GlobalState.make(~config, ~chainManager)
    let gsManager = initState->GlobalStateManager.make
    let chain = MockConfig.chain1337
    let getState = () => gsManager->GlobalStateManager.getState
    let getChainFetcher = () => getState().chainManager.chainFetchers->ChainMap.get(chain)

    open Stubs
    let dispatchTaskInitalChain = dispatchTask(gsManager, Mock.mockChainData, ...)
    let dispatchTaskReorgChain = dispatchTask(gsManager, Mock.mockChainDataReorg, ...)
    let dispatchAllTasksInitalChain = () => dispatchAllTasks(gsManager, Mock.mockChainData)
    tasks := []

    await dispatchTaskInitalChain(NextQuery(Chain(chain)))

    Assert.deepEqual(
      tasks.contents,
      [NextQuery(Chain(chain))],
      ~message="should only be one task of next query now that currentBlockHeight is set",
    )

    await dispatchAllTasksInitalChain()
    // let block2 = Mock.mockChainData->MockChainData.getBlock(~blockNumber=2)->Option.getUnsafe

    Assert.deepEqual(
      tasks.contents->Utils.getVariantsTags,
      ["UpdateEndOfBlockRangeScannedData", "ProcessPartitionQueryResponse"],
    )
    // Assert.deepEqual(
    //   tasks.contents->Js.Array2.unsafe_get(0),
    //   UpdateEndOfBlockRangeScannedData({
    //     blockNumberThreshold: -198,
    //     chain: MockConfig.chain1337,
    //     nextEndOfBlockRangeScannedData: {
    //       blockHash: block2.blockHash,
    //       blockNumber: block2.blockNumber,
    //       chainId: 1337,
    //     },
    //   }),
    // )

    await dispatchAllTasksInitalChain()

    Assert.deepEqual(
      tasks.contents,
      [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch, NextQuery(Chain(chain))],
      ~message="should successfully have actioned batch",
    )

    Assert.equal(
      getChainFetcher().fetchState->FetchState.bufferSize,
      3,
      ~message="should have 3 events on the queue from the first 3 blocks of inital chainData",
    )

    tasks := []
    await dispatchTaskReorgChain(NextQuery(Chain(chain)))
    Assert.deepEqual(tasks.contents, [Rollback], ~message="should detect rollback with reorg chain")
  })

  Async.it("Successfully rolls back single chain indexer to expected values", async () => {
    await setupDb()

    let chainManager = {
      ...ChainManager.makeFromConfig(~config),
      multichain: Unordered,
    }
    let initState = GlobalState.make(~config, ~chainManager)
    let gsManager = initState->GlobalStateManager.make
    let chain = MockConfig.chain1337
    let getState = () => gsManager->GlobalStateManager.getState
    let getChainFetcher = () => getState().chainManager.chainFetchers->ChainMap.get(chain)

    open Stubs
    let dispatchTaskInitalChain = dispatchTask(gsManager, Mock.mockChainData, ...)
    let dispatchAllTasksInitalChain = () => dispatchAllTasks(gsManager, Mock.mockChainData, ...)
    let dispatchAllTasksReorgChain = () => dispatchAllTasks(gsManager, Mock.mockChainDataReorg, ...)
    tasks := []

    await dispatchTaskInitalChain(NextQuery(Chain(chain)))

    Assert.deepEqual(
      tasks.contents,
      [NextQuery(Chain(chain))],
      ~message="should only be one task of next query now that currentBlockHeight is set",
    )

    await dispatchAllTasksInitalChain()

    // let block2 = Mock.mockChainData->MockChainData.getBlock(~blockNumber=2)->Option.getUnsafe
    Assert.deepEqual(
      tasks.contents->Utils.getVariantsTags,
      ["UpdateEndOfBlockRangeScannedData", "ProcessPartitionQueryResponse"],
    )
    // Assert.deepEqual(
    //   tasks.contents->Js.Array2.unsafe_get(0),
    //   UpdateEndOfBlockRangeScannedData({
    //     blockNumberThreshold: -198,
    //     chain: MockConfig.chain1337,
    //     nextEndOfBlockRangeScannedData: {
    //       blockHash: block2.blockHash,
    //       blockNumber: block2.blockNumber,
    //       chainId: 1337,
    //     },
    //   }),
    // )

    await dispatchAllTasksInitalChain()

    Assert.deepEqual(
      tasks.contents,
      [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch, NextQuery(Chain(chain))],
      ~message="should successfully have processed batch",
    )

    Assert.equal(
      getChainFetcher().fetchState->FetchState.bufferSize,
      3,
      ~message="should have 3 events on the queue from the first 3 blocks of inital chainData",
    )

    await dispatchAllTasksReorgChain()

    let getAllGravatars = async () =>
      (await Sql.getAllRowsInTable("Gravatar"))->Array.map(
        S.parseJsonOrThrow(_, Entities.Gravatar.schema),
      )

    let gravatars = await getAllGravatars()

    let toBigInt = BigInt.fromInt
    let toString = BigInt.toString

    let expectedGravatars: array<Entities.Gravatar.t> = [
      {
        displayName: MockEvents.setGravatar1.displayName,
        id: MockEvents.setGravatar1.id->toString,
        imageUrl: MockEvents.setGravatar1.imageUrl,
        owner_id: MockEvents.setGravatar1.owner->Utils.magic,
        size: MEDIUM,
        updatesCount: 2->toBigInt,
      },
      {
        displayName: MockEvents.newGravatar2.displayName,
        id: MockEvents.newGravatar2.id->toString,
        imageUrl: MockEvents.newGravatar2.imageUrl,
        owner_id: MockEvents.newGravatar2.owner->Utils.magic,
        size: SMALL,
        updatesCount: 1->toBigInt,
      },
    ]

    Assert.deepEqual(
      gravatars,
      expectedGravatars,
      ~message="2 Gravatars should have been set and the first one updated in the first 3 events",
    )

    Assert.deepEqual(
      tasks.contents,
      [
        GlobalState.NextQuery(CheckAllChains),
        Rollback,
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        PruneStaleEntityHistory,
      ],
      ~message="should detect rollback with reorg chain",
    )

    await dispatchAllTasksReorgChain()

    Assert.deepEqual(
      tasks.contents,
      [GlobalState.NextQuery(CheckAllChains), ProcessEventBatch],
      ~message="Rollback should have actioned, and now next queries and process event batch should action",
    )

    await dispatchAllTasksReorgChain()

    // let block2 =
    //   Mock.mockChainDataReorg
    //   ->MockChainData.getBlock(~blockNumber=2)
    //   ->Option.getUnsafe

    Assert.deepEqual(
      tasks.contents->Utils.getVariantsTags,
      ["UpdateEndOfBlockRangeScannedData", "ProcessPartitionQueryResponse"],
    )
    // Assert.deepEqual(
    //   tasks.contents->Js.Array2.unsafe_get(0),
    //   GlobalState.UpdateEndOfBlockRangeScannedData({
    //     blockNumberThreshold: -198,
    //     chain: MockConfig.chain1337,
    //     nextEndOfBlockRangeScannedData: {
    //       blockHash: block2.blockHash,
    //       blockNumber: block2.blockNumber,
    //       chainId: 1337,
    //     },
    //   }),
    // )

    await dispatchAllTasksReorgChain()

    Assert.deepEqual(
      tasks.contents,
      [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch, NextQuery(Chain(chain))],
      ~message="Query should have returned with batch to process",
    )

    await dispatchAllTasksReorgChain()

    // let block4 =
    //   Mock.mockChainDataReorg
    //   ->MockChainData.getBlock(~blockNumber=4)
    //   ->Option.getUnsafe

    Assert.deepEqual(
      tasks.contents->Utils.getVariantsTags,
      [
        "NextQuery",
        "UpdateEndOfBlockRangeScannedData",
        "ProcessPartitionQueryResponse",
        "UpdateChainMetaDataAndCheckForExit",
        "ProcessEventBatch",
        "PruneStaleEntityHistory",
      ],
    )
    // Assert.deepEqual(
    //   tasks.contents->Js.Array2.unsafe_get(1),
    //   GlobalState.UpdateEndOfBlockRangeScannedData({
    //     blockNumberThreshold: -196,
    //     chain: MockConfig.chain1337,
    //     nextEndOfBlockRangeScannedData: {
    //       blockHash: block4.blockHash,
    //       blockNumber: block4.blockNumber,
    //       chainId: 1337,
    //     },
    //   }),
    // )

    let expectedGravatars: array<Entities.Gravatar.t> = [
      {
        displayName: MockEvents.newGravatar1.displayName,
        id: MockEvents.newGravatar1.id->toString,
        imageUrl: MockEvents.newGravatar1.imageUrl,
        owner_id: MockEvents.newGravatar1.owner->Utils.magic,
        size: SMALL,
        updatesCount: 1->toBigInt,
      },
      {
        displayName: MockEvents.setGravatar2.displayName,
        id: MockEvents.setGravatar2.id->toString,
        imageUrl: MockEvents.setGravatar2.imageUrl,
        owner_id: MockEvents.setGravatar2.owner->Utils.magic,
        size: MEDIUM,
        updatesCount: 2->toBigInt,
      },
    ]

    let gravatars = await getAllGravatars()
    Assert.deepEqual(
      gravatars,
      expectedGravatars,
      ~message="First gravatar should roll back and change and second should have received an update",
    )
  })
})

// A workaround for ReScript v11 issue, where it makes the field optional
// instead of setting a value to undefined. It's fixed in v12.
let undefined = (%raw(`undefined`): option<'a>)

describe("E2E rollback tests", () => {
  let initialEnterReorgThreshold = async (~sourceMock: M.Source.t) => {
    Assert.deepEqual(
      sourceMock.getHeightOrThrowCalls->Array.length,
      1,
      ~message="should have called getHeightOrThrow to get initial height",
    )
    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    let expectedGetItemsCall1 = {"fromBlock": 0, "toBlock": Some(100), "retry": 0}

    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls,
      [expectedGetItemsCall1],
      ~message="Should request items until reorg threshold",
    )
    sourceMock.resolveGetItemsOrThrow([])
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)
  }

  let testSingleChainRollback = async (~sourceMock: M.Source.t, ~indexerMock: M.Indexer.t) => {
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
            // This should create a new history row
            context.simpleEntity.set({
              id: "2",
              value: "value-2",
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
      await Promise.all2((
        indexerMock.query(module(Entities.SimpleEntity)),
        indexerMock.queryHistory(module(Entities.SimpleEntity)),
      )),
      (
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
          {
            current: {
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 0,
            },
            previous: undefined,
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "value-2",
            }),
          },
          {
            current: {
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 0,
            },
            previous: undefined,
            entityData: Set({
              Entities.SimpleEntity.id: "2",
              value: "value-1",
            }),
          },
          {
            current: {
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 1,
            },
            previous: Some({
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 0,
            }),
            entityData: Set({
              Entities.SimpleEntity.id: "2",
              value: "value-2",
            }),
          },
          {
            current: {
              chain_id: 1337,
              block_timestamp: 102,
              block_number: 102,
              log_index: 0,
            },
            previous: undefined,
            entityData: Set({
              Entities.SimpleEntity.id: "3",
              value: "value-1",
            }),
          },
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
      [[100, 102]],
      ~message="Should have called getBlockHashes to find rollback depth",
    )
    sourceMock.resolveGetBlockHashes([
      // The block 100 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 102, blockHash: "0x102-reorged", blockTimestamp: 102},
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
      await Promise.all2((
        indexerMock.query(module(Entities.SimpleEntity)),
        indexerMock.queryHistory(module(Entities.SimpleEntity)),
      )),
      (
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
          {
            current: {
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 1,
            },
            previous: undefined,
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "value-1",
            }),
          },
          {
            current: {
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 1,
            },
            previous: undefined,
            entityData: Set({
              Entities.SimpleEntity.id: "2",
              value: "value-2",
            }),
          },
        ],
      ),
      ~message="Should correctly rollback entities",
    )
  }

  Async.it("Rollback of a single chain indexer", async () => {
    let sourceMock = M.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await M.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sources: [sourceMock.source],
        },
      ],
    )
    await Utils.delay(0)

    await initialEnterReorgThreshold(~sourceMock)
    await testSingleChainRollback(~sourceMock, ~indexerMock)
  })

  Async.it(
    "Single chain rollback should also work for unordered multichain indexer when another chains are stale",
    async () => {
      let sourceMock1 = M.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMock2 = M.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      let indexerMock = await M.Indexer.make(
        ~chains=[
          {
            chain: #1337,
            sources: [sourceMock1.source],
          },
          {
            chain: #100,
            sources: [sourceMock2.source],
          },
        ],
      )
      await Utils.delay(0)

      let _ = await Promise.all2((
        initialEnterReorgThreshold(~sourceMock=sourceMock1),
        initialEnterReorgThreshold(~sourceMock=sourceMock2),
      ))

      await testSingleChainRollback(~sourceMock=sourceMock1, ~indexerMock)
    },
  )

  Async.it("Rollback Dynamic Contract", async () => {
    let sourceMock = M.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await M.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sources: [sourceMock.source],
        },
      ],
    )
    await Utils.delay(0)

    await initialEnterReorgThreshold(~sourceMock)

    let calls = []
    let handler: Types.HandlerTypes.loader<unit, unit> = async ({event}) => {
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
      [[100, 101, 102, 103, 104]],
      ~message="Should have called getBlockHashes to find rollback depth",
    )
    sourceMock.resolveGetBlockHashes([
      // The block 102 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
      {blockNumber: 102, blockHash: "0x102", blockTimestamp: 102},
      {blockNumber: 103, blockHash: "0x103-reorged", blockTimestamp: 103},
      {blockNumber: 104, blockHash: "0x104-reorged", blockTimestamp: 104},
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
    let sourceMock1337 = M.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let sourceMock100 = M.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#100,
    )
    let indexerMock = await M.Indexer.make(
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
    )
    await Utils.delay(0)

    let _ = await Promise.all2((
      initialEnterReorgThreshold(~sourceMock=sourceMock1337),
      initialEnterReorgThreshold(~sourceMock=sourceMock100),
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
    sourceMock1337.resolveGetItemsOrThrow([
      {
        blockNumber: 102,
        logIndex: 4,
        handler,
      },
    ])
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await Promise.all2((
        indexerMock.query(module(Entities.SimpleEntity)),
        indexerMock.queryHistory(module(Entities.SimpleEntity)),
      )),
      (
        [
          {
            Entities.SimpleEntity.id: "1",
            value: "call-5",
          },
        ],
        [
          {
            current: {
              chain_id: 100,
              block_timestamp: 101,
              block_number: 101,
              log_index: 2,
            },
            previous: undefined,
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-0",
            }),
          },
          {
            current: {
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 1,
            },
            previous: Some({
              chain_id: 100,
              block_timestamp: 101,
              block_number: 101,
              log_index: 2,
            }),
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-1",
            }),
          },
          {
            current: {
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 2,
            },
            previous: Some({
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 1,
            }),
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-2",
            }),
          },
          {
            current: {
              chain_id: 1337,
              block_timestamp: 102,
              block_number: 102,
              log_index: 2,
            },
            previous: Some({
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 2,
            }),
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-3",
            }),
          },
          {
            current: {
              chain_id: 100,
              block_timestamp: 102,
              block_number: 102,
              log_index: 2,
            },
            previous: Some({
              chain_id: 1337,
              block_timestamp: 102,
              block_number: 102,
              log_index: 2,
            }),
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-4",
            }),
          },
          {
            current: {
              chain_id: 1337,
              block_timestamp: 102,
              block_number: 102,
              log_index: 4,
            },
            // FIXME: This looks wrong
            previous: Some({
              chain_id: 1337,
              block_timestamp: 102,
              block_number: 102,
              log_index: 2,
            }),
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-5",
            }),
          },
        ],
      ),
      ~message=`Should create multiple history rows:
Sorted for the batch for block number 101
Different batches for block number 102`,
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
      [[100, 101, 102, 103]],
      ~message="Should have called getBlockHashes to find rollback depth",
    )
    sourceMock1337.resolveGetBlockHashes([
      // The block 101 is untouched so we can rollback to it
      {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
      {blockNumber: 102, blockHash: "0x102-reorged", blockTimestamp: 102},
      {blockNumber: 103, blockHash: "0x103-reorged", blockTimestamp: 103},
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
      await Promise.all2((
        indexerMock.query(module(Entities.SimpleEntity)),
        indexerMock.queryHistory(module(Entities.SimpleEntity)),
      )),
      (
        [
          {
            Entities.SimpleEntity.id: "1",
            value: "call-4",
          },
        ],
        [
          {
            current: {
              chain_id: 100,
              block_timestamp: 101,
              block_number: 101,
              log_index: 2,
            },
            previous: undefined,
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-0",
            }),
          },
          {
            current: {
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 1,
            },
            previous: Some({
              chain_id: 100,
              block_timestamp: 101,
              block_number: 101,
              log_index: 2,
            }),
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-1",
            }),
          },
          {
            current: {
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 2,
            },
            previous: Some({
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 1,
            }),
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-2",
            }),
          },
          {
            current: {
              chain_id: 100,
              block_timestamp: 102,
              block_number: 102,
              log_index: 2,
            },
            previous: Some({
              chain_id: 1337,
              block_timestamp: 101,
              block_number: 101,
              log_index: 2,
            }),
            entityData: Set({
              Entities.SimpleEntity.id: "1",
              value: "call-4",
            }),
          },
        ],
      ),
    )
  })
})
