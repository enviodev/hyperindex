open Belt
open RescriptMocha
open Mocha

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

describe_only("Rollback tests", () => {
  it("Detects reorgs and actions a rollback", () => {
    let chainManager = ChainManager.makeFromConfig(~configs=Config.config)
    let initState = GlobalState.make(~chainManager)
    let gsManager = initState->GlobalStateManager.make
    let chain = ChainMap.Chain.Chain_1
    let getState = () => gsManager->GlobalStateManager.getState
    let getChainFetcher = () => getState().chainManager.chainFetchers->ChainMap.get(chain)

    //Stub wait for new block
    let waitForNewBlock = (~logger, ~currentBlockHeight, ~setCurrentBlockHeight, ~chainWorker) => {
      (logger, currentBlockHeight, chainWorker)->ignore
      Mock.mockChainData->MockChainData.getHeight->setCurrentBlockHeight
    }

    //Stub executeNextQuery with mock data
    let executeNextQueryWithMockChainData = (
      mockChainData,
      ~logger,
      ~query,
      ~currentBlockHeight,
      ~setCurrentBlockHeight,
      ~dispatchAction,
      ~chain,
      ~chainWorker,
    ) => {
      (logger, currentBlockHeight, setCurrentBlockHeight, chainWorker)->ignore

      let response = mockChainData->MockChainData.executeQuery(query)
      dispatchAction(GlobalState.BlockRangeResponse(chain, response))
    }
    let executeNextQuery = executeNextQueryWithMockChainData(Mock.mockChainData)

    //Hold next tasks temporarily here so they do not get actioned off automatically
    let tasks = ref([])

    //Stub dispatch action to set state and not dispatch task but store in 
    //the tasks ref
    let dispatchAction = action => {
      let (nextState, nextTasks) = GlobalState.actionReducer(
        gsManager->GlobalStateManager.getState,
        action,
      )
      gsManager->GlobalStateManager.setState(nextState)
      tasks := tasks.contents->Array.concat(nextTasks)
    }

    //Run check and fetch for chain with stubs injected
    GlobalState.checkAndFetchForChain(
      ~executeNextQuery,
      ~waitForNewBlock,
      ~dispatchAction,
      ~state=getState(),
      chain,
    )

    Assert.equal(
      tasks.contents->Array.length,
      1,
      ~message="should only be one task of next query now that currentBlockHeight is set",
    )
    let nextTask = tasks.contents->Js.Array2.pop->Option.getExn
    Assert.deep_equal(nextTask, NextQuery(Chain(chain)))

    //Run check and fetch for chain with stubs injected
    GlobalState.checkAndFetchForChain(
      ~executeNextQuery,
      ~waitForNewBlock,
      ~dispatchAction,
      ~state=getState(),
      chain,
    )
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
    let executeNextQuery = executeNextQueryWithMockChainData(Mock.mockChainDataReorg)
    GlobalState.checkAndFetchForChain(
      ~executeNextQuery,
      ~waitForNewBlock,
      ~dispatchAction,
      ~state=getState(),
      chain,
    )
    Assert.deep_equal(
      tasks.contents,
      [Rollback],
      ~message="should detect rollback with reorg chain",
    )
  })
})
