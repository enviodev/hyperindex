// What user code of one indexer runs against: the handler context both passes
// share and the contract register context, each built once. Created when the
// indexer loop starts and handed to the code that runs handlers and contract
// registers.

type t = {
  params: UserContext.params,
  handlerContext: Internal.handlerContext,
  contractRegisterContext: Internal.contractRegisterContext,
  mutable isRealtime: bool,
}

let isRealtimeOf = (chainStates: dict<ChainState.t>) =>
  chainStates->Dict.valuesToArray->Array.every(ChainState.isReady)

let makeChains = (chainStates: dict<ChainState.t>, ~isRealtime): Internal.chains => {
  let chains = Dict.make()
  chainStates->Utils.Dict.forEach(cs => {
    let id = (cs->ChainState.chainConfig).id
    chains->Dict.set(id->ChainId.toString, ({id, isRealtime}: Internal.chainInfo))
  })
  chains
}

let make = (indexerState: IndexerState.t) => {
  let config = indexerState->IndexerState.config
  let chainStates = indexerState->IndexerState.chainStates
  let isRealtime = chainStates->isRealtimeOf
  let params: UserContext.params = {
    indexerState,
    loadManager: indexerState->IndexerState.loadManager,
    persistence: indexerState->IndexerState.persistence,
    config,
    chains: chainStates->makeChains(~isRealtime),
  }
  {
    params,
    handlerContext: UserContext.makeHandlerContext(params),
    contractRegisterContext: ContractRegisterContext.make(~config),
    isRealtime,
  }
}

// `context.chain` as of the batch about to run. Only the realtime flag, shared
// by every chain, can change, so the chain objects are rebuilt only when it
// flips, and one a handler kept stays a consistent snapshot.
let refreshChains = (runtime: t) => {
  let chainStates = runtime.params.indexerState->IndexerState.chainStates
  let isRealtime = chainStates->isRealtimeOf
  if isRealtime !== runtime.isRealtime {
    runtime.isRealtime = isRealtime
    runtime.params.chains = chainStates->makeChains(~isRealtime)
  }
}

let ecosystem = (runtime: t) => runtime.params.config.ecosystem

let chainLoggerFor = (runtime: t, item: Internal.item) =>
  runtime.params.indexerState
  ->IndexerState.getChainState(~chainId=item->Internal.getItemChainId)
  ->ChainState.logger
