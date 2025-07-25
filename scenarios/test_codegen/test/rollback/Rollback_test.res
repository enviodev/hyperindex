open Belt
open RescriptMocha

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
    let block2 = Mock.mockChainData->MockChainData.getBlock(~blockNumber=2)->Option.getUnsafe

    Assert.deepEqual(
      tasks.contents->Utils.getVariantsTags,
      ["UpdateEndOfBlockRangeScannedData", "ProcessPartitionQueryResponse"],
    )
    Assert.deepEqual(
      tasks.contents->Js.Array2.unsafe_get(0),
      UpdateEndOfBlockRangeScannedData({
        blockNumberThreshold: -198,
        chain: MockConfig.chain1337,
        nextEndOfBlockRangeScannedData: {
          blockHash: block2.blockHash,
          blockNumber: block2.blockNumber,
          chainId: 1337,
        },
      }),
    )

    await dispatchAllTasksInitalChain()

    Assert.deepEqual(
      tasks.contents,
      [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch, NextQuery(Chain(chain))],
      ~message="should successfully have actioned batch",
    )

    Assert.equal(
      getChainFetcher().fetchState->FetchState.queueSize,
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
      isUnorderedMultichainMode: true,
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

    let block2 = Mock.mockChainData->MockChainData.getBlock(~blockNumber=2)->Option.getUnsafe
    Assert.deepEqual(
      tasks.contents->Utils.getVariantsTags,
      ["UpdateEndOfBlockRangeScannedData", "ProcessPartitionQueryResponse"],
    )
    Assert.deepEqual(
      tasks.contents->Js.Array2.unsafe_get(0),
      UpdateEndOfBlockRangeScannedData({
        blockNumberThreshold: -198,
        chain: MockConfig.chain1337,
        nextEndOfBlockRangeScannedData: {
          blockHash: block2.blockHash,
          blockNumber: block2.blockNumber,
          chainId: 1337,
        },
      }),
    )

    await dispatchAllTasksInitalChain()

    Assert.deepEqual(
      tasks.contents,
      [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch, NextQuery(Chain(chain))],
      ~message="should successfully have processed batch",
    )

    Assert.equal(
      getChainFetcher().fetchState->FetchState.queueSize,
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

    let block2 =
      Mock.mockChainDataReorg
      ->MockChainData.getBlock(~blockNumber=2)
      ->Option.getUnsafe

    Assert.deepEqual(
      tasks.contents->Utils.getVariantsTags,
      [
        "UpdateChainMetaDataAndCheckForExit",
        "UpdateEndOfBlockRangeScannedData",
        "ProcessPartitionQueryResponse",
      ],
    )
    Assert.deepEqual(
      tasks.contents->Js.Array2.unsafe_get(1),
      GlobalState.UpdateEndOfBlockRangeScannedData({
        blockNumberThreshold: -198,
        chain: MockConfig.chain1337,
        nextEndOfBlockRangeScannedData: {
          blockHash: block2.blockHash,
          blockNumber: block2.blockNumber,
          chainId: 1337,
        },
      }),
    )

    await dispatchAllTasksReorgChain()

    Assert.deepEqual(
      tasks.contents,
      [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch, NextQuery(Chain(chain))],
      ~message="Query should have returned with batch to process",
    )

    await dispatchAllTasksReorgChain()

    let block4 =
      Mock.mockChainDataReorg
      ->MockChainData.getBlock(~blockNumber=4)
      ->Option.getUnsafe

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
    Assert.deepEqual(
      tasks.contents->Js.Array2.unsafe_get(1),
      GlobalState.UpdateEndOfBlockRangeScannedData({
        blockNumberThreshold: -196,
        chain: MockConfig.chain1337,
        nextEndOfBlockRangeScannedData: {
          blockHash: block4.blockHash,
          blockNumber: block4.blockNumber,
          chainId: 1337,
        },
      }),
    )

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
