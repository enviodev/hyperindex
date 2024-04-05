open Belt
open RescriptMocha
open Mocha
let {
  it: it_promise,
  it_only: it_promise_only,
  it_skip: it_skip_promise,
  before: before_promise,
} = module(RescriptMocha.Promise)

module Mock = {
  let mockChainDataEmpty = MockChainData.make(
    ~chain=Chain_1,
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
      [UpdatedGravatar.mkEventConstr(MockEvents.setGravatar1)],
      [
        UpdatedGravatar.mkEventConstr(MockEvents.setGravatar2),
        NewGravatar.mkEventConstr(MockEvents.newGravatar3),
        UpdatedGravatar.mkEventConstr(MockEvents.setGravatar3),
      ],
    ])

  let blocksReorg =
    blocksBase->Array.concat([
      [UpdatedGravatar.mkEventConstr(MockEvents.setGravatar1)],
      [
        UpdatedGravatar.mkEventConstr(MockEvents.setGravatar1),
        UpdatedGravatar.mkEventConstr(MockEvents.setGravatar2),
      ],
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
  let waitForNewBlock = async (
    ~logger,
    ~chainWorker,
    ~currentBlockHeight,
    ~setCurrentBlockHeight,
  ) => {
    (logger, currentBlockHeight, chainWorker)->ignore
    Mock.mockChainData->MockChainData.getHeight->setCurrentBlockHeight
  }

  //Stub executeNextQuery with mock data
  let executeNextQueryWithMockChainData = async (
    mockChainData,
    ~logger,
    ~chainWorker,
    ~currentBlockHeight,
    ~setCurrentBlockHeight,
    ~chain,
    ~query,
    ~dispatchAction,
  ) => {
    (logger, currentBlockHeight, setCurrentBlockHeight, chainWorker)->ignore

    let response = mockChainData->MockChainData.executeQuery(query)
    dispatchAction(GlobalState.BlockRangeResponse(chain, response))
  }

  //Stub for getting block hashes instead of the worker
  let getBlockHashes = async (mockChainData, _chainFetcher, ~blockNumbers) =>
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
      ~executeNextQuery=executeNextQueryWithMockChainData(mockChainData),
      ~waitForNewBlock,
      ~rollbackLastBlockHashesToReorgLocation=ChainFetcher.rollbackLastBlockHashesToReorgLocation(
        ~getBlockHashes=getBlockHashes(mockChainData),
      ),
      ~dispatchAction=dispatchAction(gsManager),
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

let setupDb = async (~shouldDropRawEvents) => {
  open Migrations
  Logging.info("Provisioning Database")
  // TODO: we should make a hash of the schema file (that gets stored in the DB) and either drop the tables and create new ones or keep this migration.
  //       for now we always run the down migration.
  // if (process.env.MIGRATE === "force" || hash_of_schema_file !== hash_of_current_schema)
  let _exitCodeDown = await runDownMigrations(~shouldExit=false, ~shouldDropRawEvents)
  // else
  //   await clearDb()

  let _exitCodeUp = await runUpMigrations(~shouldExit=false)
}
describe_only("Rollback tests", () => {
  it_promise("Detects reorgs and actions a rollback", async () => {
    let chainManager = ChainManager.makeFromConfig(~configs=Config.config)
    let initState = GlobalState.make(~chainManager)
    let gsManager = initState->GlobalStateManager.make
    let chain = ChainMap.Chain.Chain_1
    let getState = () => gsManager->GlobalStateManager.getState
    let getChainFetcher = () => getState().chainManager.chainFetchers->ChainMap.get(chain)

    open Stubs
    let dispatchTaskInitalChain = dispatchTask(gsManager, Mock.mockChainData)
    let dispatchTaskReorgChain = dispatchTask(gsManager, Mock.mockChainDataReorg)
    let dispatchAllTasksInitalChain = () => dispatchAllTasks(gsManager, Mock.mockChainData)

    await dispatchTaskInitalChain(NextQuery(Chain(chain)))

    Assert.deep_equal(
      tasks.contents,
      [NextQuery(Chain(chain))],
      ~message="should only be one task of next query now that currentBlockHeight is set",
    )

    await dispatchAllTasksInitalChain()

    Assert.deep_equal(
      tasks.contents,
      [UpdateChainMetaData, ProcessEventBatch, NextQuery(Chain(chain))],
      ~message="should successfully have processed batch",
    )

    Assert.equal(
      getChainFetcher().fetchState->FetchState.queueSize,
      3,
      ~message="should have 3 events on the queue from the first 3 blocks of inital chainData",
    )

    tasks := []
    await dispatchTaskReorgChain(NextQuery(Chain(chain)))
    Assert.deep_equal(
      tasks.contents,
      [Rollback],
      ~message="should detect rollback with reorg chain",
    )
  })

  it_promise_only("runs end to end", async () => {
    Logging.setLogLevel(#trace)
    await setupDb(~shouldDropRawEvents=true)

    let chainManager = ChainManager.makeFromConfig(~configs=Config.config)
    let initState = GlobalState.make(~chainManager)
    let gsManager = initState->GlobalStateManager.make
    let chain = ChainMap.Chain.Chain_1
    let getState = () => gsManager->GlobalStateManager.getState
    let getChainFetcher = () => getState().chainManager.chainFetchers->ChainMap.get(chain)

    open Stubs
    let dispatchTaskInitalChain = dispatchTask(gsManager, Mock.mockChainData)
    let dispatchTaskReorgChain = dispatchTask(gsManager, Mock.mockChainDataReorg)
    let dispatchAllTasksInitalChain = () => dispatchAllTasks(gsManager, Mock.mockChainData)
    let dispatchAllTasksReorgChain = () => dispatchAllTasks(gsManager, Mock.mockChainDataReorg)

    await dispatchTaskInitalChain(NextQuery(Chain(chain)))

    Assert.deep_equal(
      tasks.contents,
      [NextQuery(Chain(chain))],
      ~message="should only be one task of next query now that currentBlockHeight is set",
    )

    await dispatchAllTasksInitalChain()

    Assert.deep_equal(
      tasks.contents,
      [UpdateChainMetaData, ProcessEventBatch, NextQuery(Chain(chain))],
      ~message="should successfully have processed batch",
    )

    Assert.equal(
      getChainFetcher().fetchState->FetchState.queueSize,
      3,
      ~message="should have 3 events on the queue from the first 3 blocks of inital chainData",
    )

    await dispatchAllTasksReorgChain()
    Assert.deep_equal(
      tasks.contents,
      [Rollback],
      ~message="should detect rollback with reorg chain",
    )

    await dispatchAllTasksReorgChain()
  })
})
