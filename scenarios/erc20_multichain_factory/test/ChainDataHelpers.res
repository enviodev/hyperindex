open Belt

let getDefaultAddress = (chain, contractName) => {
  let chainConfig = (Config.getGenerated().chainMap)->ChainMap.get(chain)
  let contract = chainConfig.contracts->Js.Array2.find(c => c.name == contractName)->Option.getExn
  let defaultAddress = contract.addresses[0]->Option.getExn
  defaultAddress
}

open Enums.EventType

module ERC20 = {
  let contractName = "ERC20"
  let getDefaultAddress = getDefaultAddress(_, contractName)
  module Transfer = {
    let accessor = v => Types.ERC20_Transfer(v)
    let schema = Types.ERC20.Transfer.eventArgsSchema
    let eventName = ERC20_Transfer
    let mkEventConstrWithParamsAndAddress =
      MockChainData.makeEventConstructor(~accessor, ~schema, ~eventName, ...)

    let mkEventConstr = (params, ~chain) =>
      mkEventConstrWithParamsAndAddress(~srcAddress=getDefaultAddress(chain), ~params, ...)
  }
}

module ERC20Factory = {
  let contractName = "ERC20Factory"
  let getDefaultAddress = getDefaultAddress(_, contractName)

  module TokenCreated = {
    let accessor = v => Types.ERC20Factory_TokenCreated(v)
    let schema = Types.ERC20Factory.TokenCreated.eventArgsSchema
    let eventName = ERC20Factory_TokenCreated

    let mkEventConstrWithParamsAndAddress =
      MockChainData.makeEventConstructor(~accessor, ~schema, ~eventName, ...)

    let mkEventConstr = (params, ~chain) =>
      mkEventConstrWithParamsAndAddress(~srcAddress=getDefaultAddress(chain), ~params, ...)
  }
  module DeleteUser = {
    let accessor = v => Types.ERC20Factory_DeleteUser(v)
    let schema = Types.ERC20Factory.DeleteUser.eventArgsSchema
    let eventName = ERC20Factory_DeleteUser

    let mkEventConstrWithParamsAndAddress =
      MockChainData.makeEventConstructor(~accessor, ~schema, ~eventName, ...)

    let mkEventConstr = (params, ~chain) =>
      mkEventConstrWithParamsAndAddress(~srcAddress=getDefaultAddress(chain), ~params, ...)
  }
}

module Stubs = {
  type t = {
    mockChainDataMap: ChainMap.t<MockChainData.t>,
    tasks: ref<array<GlobalState.task>>,
    gsManager: GlobalStateManager.t,
  }

  let make = (~mockChainDataMap, ~tasks, ~gsManager) => {
    mockChainDataMap,
    tasks,
    gsManager,
  }
  let getTasks = ({tasks}) => tasks.contents
  let getMockChainData = ({mockChainDataMap}, chain) => mockChainDataMap->ChainMap.get(chain)

  //Stub executeNextQuery with mock data
  let makeExecuteNextQuery = async (
    stubData: t,
    ~logger,
    ~chainWorker,
    ~currentBlockHeight,
    ~setCurrentBlockHeight,
    ~chain,
    ~query,
    ~dispatchAction,
  ) => {
    (logger, currentBlockHeight, setCurrentBlockHeight, chainWorker)->ignore

    let response = stubData->getMockChainData(chain)->MockChainData.executeQuery(query)
    dispatchAction(GlobalState.BlockRangeResponse(chain, response))
  }

  let getChainFromWorker = (worker: SourceWorker.sourceWorker) =>
    switch worker {
    | Rpc(w) => w.chainConfig.chain
    | HyperSync(w) => w.chainConfig.chain
    }

  //Stub for getting block hashes instead of the worker
  let makeGetBlockHashes = stubData => sourceWorker => async (~blockNumbers) => {
    let chain = sourceWorker->getChainFromWorker
    stubData->getMockChainData(chain)->MockChainData.getBlockHashes(~blockNumbers)->Ok
  }

  let replaceNexQueryCheckAllChainsWithGivenChain = ({tasks}: t, chain) => {
    tasks :=
      tasks.contents->Array.map(t =>
        switch t {
        | GlobalState.NextQuery(CheckAllChains) => GlobalState.NextQuery(Chain(chain))
        | task => task
        }
      )
  }

  //Stub wait for new block
  let makeWaitForNewBlock = async (
    stubData: t,
    ~logger,
    ~chainWorker: SourceWorker.sourceWorker,
    ~currentBlockHeight,
    ~setCurrentBlockHeight,
  ) => {
    (logger, currentBlockHeight, chainWorker)->ignore
    let chain = chainWorker->getChainFromWorker
    stubData->getMockChainData(chain)->MockChainData.getHeight->setCurrentBlockHeight
  }
  //Stub dispatch action to set state and not dispatch task but store in
  //the tasks ref
  let makeDispatchAction = ({gsManager, tasks}, action) => {
    let (nextState, nextTasks) = GlobalState.actionReducer(
      gsManager->GlobalStateManager.getState,
      action,
    )
    gsManager->GlobalStateManager.setState(nextState)
    tasks := tasks.contents->Array.concat(nextTasks)
  }

  let makeDispatchTask = (stubData: t, task) => {
    GlobalState.injectedTaskReducer(
      ~executeNextQuery=makeExecuteNextQuery(stubData, ...),
      ~waitForNewBlock=makeWaitForNewBlock(stubData, ...),
      ~rollbackLastBlockHashesToReorgLocation=ChainFetcher.rollbackLastBlockHashesToReorgLocation(
        ~getBlockHashes=makeGetBlockHashes(stubData),
        _,
      ),
      ~registeredEvents=RegisteredEvents.global,
    )(
      ~dispatchAction=makeDispatchAction(stubData, _),
      stubData.gsManager->GlobalStateManager.getState,
      task,
    )
  }

  let dispatchAllTasks = async (stubData: t) => {
    let tasksToRun = stubData.tasks.contents
    stubData.tasks := []
    let _ =
      await tasksToRun
      ->Array.map(task => makeDispatchTask(stubData, task))
      ->Js.Promise.all
  }
}
