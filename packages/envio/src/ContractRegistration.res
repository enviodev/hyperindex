// The contractRegister loop: runs a chain's contractRegister handlers over the
// blocks of its backlog, in their own pass over the buffer, apart from the
// response that fetched them. Processing never reads past the block before the
// lowest backlog block, so an address registered at a block indexes that block's
// later logs too.

// Items one run builds at most; a run ends at the first block boundary past it.
let targetItems = 5_000

let invokeContractRegister = (runtime: HandlerRuntime.t, item: Internal.item) => {
  let contractRegister = switch (item->Internal.castUnsafeEventItem).onEventRegistration {
  | {contractRegister: Some(contractRegister)} => contractRegister
  | {contractRegister: None, eventConfig: {name: eventName}} =>
    JsError.throwWithMessage("Contract register is not set for event " ++ eventName)
  }
  contractRegister({
    event: item->Ecosystem.getItemEvent(~ecosystem=runtime->HandlerRuntime.ecosystem),
    context: runtime.contractRegisterContext,
  })
}

// Runs every item's contractRegister concurrently, collecting what they add
// in call order.
let runOrThrow = async (items: array<Internal.item>, ~runtime, ~chainState) => {
  let registrations: array<AddressStore.registration> = []
  let chainLogger = chainState->ChainState.logger
  let ecosystem = runtime->HandlerRuntime.ecosystem
  let _ = await items
  ->Array.map(async item => {
    let run: RunScope.contractRegisterRun = {
      item,
      isResolved: false,
      chainLogger,
      ecosystem,
      registrations,
    }
    let scope = RunScope.ContractRegister(run)
    switch await RunScope.enter(scope, invokeContractRegister, runtime, item) {
    | exception exn =>
      scope->RunScope.resolve
      exn->ErrorHandling.mkLogAndRaise(
        ~msg="Event contractRegister failed, please fix the error to keep the indexer running smoothly",
        ~logger=run->RunScope.contractRegisterLogger,
      )
    | () => scope->RunScope.resolve
    }
  })
  ->Promise.all
  registrations
}

// One run over the front of the chain's backlog. Its result is dropped when a
// rollback started meanwhile: the blocks it read may no longer exist, and the
// rollback already took the backlog back to its target.
let runChain = async (state: IndexerState.t, ~chainId, ~runtime, ~stateId) => {
  let chainState = state->IndexerState.getChainState(~chainId)
  let blockNumbers = chainState->ChainState.beginContractRegisterRun
  let built = await chainState
  ->ChainState.chainBuffer
  ->ChainBuffer.buildContractRegisterItems(~blockNumbers, ~targetItems)
  let items = built->StoredItems.read(~context=chainState->ChainState.itemContext)
  let lastBlock = built.lastBlock
  let registrations = await runOrThrow(items, ~runtime, ~chainState)
  chainState
  ->ChainState.logger
  ->Logger.trace(
    "Finished contractRegister run",
    ~params={
      "blocks": blockNumbers->Array.length,
      "lastBlock": lastBlock,
      "items": items->Array.length,
      "registrations": registrations->Array.length,
      "stale": state->IndexerState.isStale(~stateId),
      "backlog": (chainState->ChainState.fetchStateOf).contractRegisterBacklog,
    },
  )
  if !(state->IndexerState.isStale(~stateId)) {
    chainState->ChainState.registerContracts(
      ~registrations,
      ~builtBlockNumbers=switch lastBlock {
      | Some(lastBlock) => blockNumbers->Array.filter(block => block <= lastBlock)
      | None => []
      },
    )
  }
}

// Runs the chain's backlog until it is empty, one run at a time, kicking
// fetching (a registration can add partitions) and processing (the ready
// frontier moved) after each.
let rec drainChain = async (
  state: IndexerState.t,
  ~chainId,
  ~runtime,
  ~scheduleFetch,
  ~scheduleProcessing,
) => {
  let chainState = state->IndexerState.getChainState(~chainId)
  let stateId = state->IndexerState.epoch
  if (
    !(state->IndexerState.isStopped) &&
    !(state->IndexerState.isResolvingReorg) &&
    chainState->ChainState.hasContractRegisterBacklog &&
    !(chainState->ChainState.isRegisteringContracts)
  ) {
    try {
      await runChain(state, ~chainId, ~runtime, ~stateId)
      chainState->ChainState.endContractRegisterRun
      ChainMetadata.stage(state)
      scheduleFetch()
      scheduleProcessing()
      await drainChain(state, ~chainId, ~runtime, ~scheduleFetch, ~scheduleProcessing)
    } catch {
    | exn =>
      chainState->ChainState.endContractRegisterRun
      IndexerState.errorExit(state, exn->ErrorHandling.make(~logger=chainState->ChainState.logger))
    }
  }
}
