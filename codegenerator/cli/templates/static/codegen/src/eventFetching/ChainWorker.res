// TODO: add back warnings when ready!
type chainId = int
exception UndefinedChainConfig(chainId)
exception IncorrectSyncSource(Config.syncSource)

@@warning("-27")
module type S = {
  type t

  let make: (~caughtUpToHeadHook: t => promise<unit>=?, Config.chainConfig) => t

  let stopFetchingEvents: t => promise<unit>

  let startFetchingEvents: (
    t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => promise<unit>

  let addNewRangeQueriedCallback: t => promise<unit>

  let getLatestFetchedBlockTimestamp: t => int

  let addDynamicContractAndFetchMissingEvents: (
    t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock: int,
    ~fromLogIndex: int,
    ~logger: Pino.t,
  ) => promise<array<Types.eventBatchQueueItem>>
}

module SkarWorker: S = HyperSyncWorker.Make(HyperSync.SkarHyperSync)
module EthArchiveWorker: S = HyperSyncWorker.Make(HyperSync.EthArchiveHyperSync)
module RawEventsWorker: S = RawEventsWorker
module RpcWorker: S = RpcWorker

type chainWorker =
  | Rpc(RpcWorker.t)
  | Skar(SkarWorker.t)
  | EthArchive(EthArchiveWorker.t)
  | RawEvents(RawEventsWorker.t)

module PolyMorphicChainWorkerFunctions = {
  /* Why use thes polymorphic functions rather than calling function directly on
  the chainworker?

  We could just call the function on the worker when matching on the chainWorker type.
  ie. ... | Rpc(worker) => worker->RpcWorker.startFetchingEvents() ...

  Instead we have these polymorphic functions that take a tuple with worker with it's module type,
  and calls the chain worker function.

  The only real benefit is that it forces us to use functions on the ChainWorker module signature.
  Which will hopefully keep this somewhat modular. 

  The chainworkerModTuple type enforces that the worker type and module conform to the chainworker 
  signature. And the polymorphic functions only call functions on that signature.

  chainWorker variants can be converted to this type, and used with the polymorphic functions.

  It's not the prettiest interface, and if readability is ever chosen over this enforced module signature
  pattern then these polymorphic functions can be removed and the functions can be accessed/called directly
  on the underlying worker module.
 */

  type chainWorkerModTuple<'workerType> = ('workerType, module(S with type t = 'workerType))

  let startFetchingEvents = (
    type workerType,
    chainWorkerModTuple: chainWorkerModTuple<workerType>,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => {
    let (worker, workerMod) = chainWorkerModTuple
    let module(ChainWorker) = workerMod
    worker->ChainWorker.startFetchingEvents(~logger, ~fetchedEventQueue)
  }

  let addNewRangeQueriedCallback = (
    type workerType,
    chainWorkerModTuple: chainWorkerModTuple<workerType>,
  ) => {
    let (worker, workerMod) = chainWorkerModTuple
    let module(M) = workerMod
    worker->M.addNewRangeQueriedCallback
  }

  let getLatestFetchedBlockTimestamp = (
    type workerType,
    chainWorkerModTuple: chainWorkerModTuple<workerType>,
  ) => {
    let (worker, workerMod) = chainWorkerModTuple
    let module(M) = workerMod
    worker->M.getLatestFetchedBlockTimestamp
  }

  let addDynamicContractAndFetchMissingEvents = (
    type workerType,
    chainWorkerModTuple: chainWorkerModTuple<workerType>,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock,
    ~fromLogIndex,
    ~logger,
  ): promise<array<Types.eventBatchQueueItem>> => {
    let (worker, workerMod) = chainWorkerModTuple
    let module(M) = workerMod
    //Note: Only defining f so my syntax highlighting doesn't break -> Jono
    let f = worker->M.addDynamicContractAndFetchMissingEvents
    f(~dynamicContracts, ~fromBlock, ~fromLogIndex, ~logger)
  }

  type chainWorkerMod =
    | RpcWorkerMod(chainWorkerModTuple<RpcWorker.t>)
    | SkarWorkerMod(chainWorkerModTuple<SkarWorker.t>)
    | EthArchiveWorkerMod(chainWorkerModTuple<EthArchiveWorker.t>)
    | RawEventsWorkerMod(chainWorkerModTuple<RawEventsWorker.t>)

  let chainWorkerToChainMod = (worker: chainWorker) => {
    switch worker {
    | Rpc(w) => RpcWorkerMod((w, module(RpcWorker)))
    | Skar(w) => SkarWorkerMod((w, module(SkarWorker)))
    | EthArchive(w) => EthArchiveWorkerMod((w, module(EthArchiveWorker)))
    | RawEvents(w) => RawEventsWorkerMod((w, module(RawEventsWorker)))
    }
  }
}

let startFetchingEvents = (worker: chainWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  open PolyMorphicChainWorkerFunctions
  switch worker->chainWorkerToChainMod {
  | RpcWorkerMod(w) => w->startFetchingEvents
  | SkarWorkerMod(w) => w->startFetchingEvents
  | EthArchiveWorkerMod(w) => w->startFetchingEvents
  | RawEventsWorkerMod(w) => w->startFetchingEvents
  }
}

let addNewRangeQueriedCallback = (worker: chainWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  open PolyMorphicChainWorkerFunctions
  switch worker->chainWorkerToChainMod {
  | RpcWorkerMod(w) => w->addNewRangeQueriedCallback
  | SkarWorkerMod(w) => w->addNewRangeQueriedCallback
  | EthArchiveWorkerMod(w) => w->addNewRangeQueriedCallback
  | RawEventsWorkerMod(w) => w->addNewRangeQueriedCallback
  }
}

let getLatestFetchedBlockTimestamp = (worker: chainWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  open PolyMorphicChainWorkerFunctions
  switch worker->chainWorkerToChainMod {
  | RpcWorkerMod(w) => w->getLatestFetchedBlockTimestamp
  | SkarWorkerMod(w) => w->getLatestFetchedBlockTimestamp
  | EthArchiveWorkerMod(w) => w->getLatestFetchedBlockTimestamp
  | RawEventsWorkerMod(w) => w->getLatestFetchedBlockTimestamp
  }
}

let addDynamicContractAndFetchMissingEvents = (worker: chainWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  open PolyMorphicChainWorkerFunctions
  switch worker->chainWorkerToChainMod {
  | RpcWorkerMod(w) => w->addDynamicContractAndFetchMissingEvents
  | SkarWorkerMod(w) => w->addDynamicContractAndFetchMissingEvents
  | EthArchiveWorkerMod(w) => w->addDynamicContractAndFetchMissingEvents
  | RawEventsWorkerMod(w) => w->addDynamicContractAndFetchMissingEvents
  }
}

type caughtUpToHeadCallback<'worker> = option<'worker => promise<unit>>
type workerSelectionWithCallback =
  | RpcSelectedWithCallback(caughtUpToHeadCallback<RpcWorker.t>)
  | SkarSelectedWithCallback(caughtUpToHeadCallback<SkarWorker.t>)
  | EthArchiveSelectedWithCallback(caughtUpToHeadCallback<EthArchiveWorker.t>)
  | RawEventsSelectedWithCallback(caughtUpToHeadCallback<RawEventsWorker.t>)

let make = (selectedWorker: workerSelectionWithCallback, ~chainConfig) => {
  switch selectedWorker {
  | RpcSelectedWithCallback(caughtUpToHeadHook) =>
    Rpc(RpcWorker.make(~caughtUpToHeadHook?, chainConfig))
  | SkarSelectedWithCallback(caughtUpToHeadHook) =>
    Skar(SkarWorker.make(~caughtUpToHeadHook?, chainConfig))
  | EthArchiveSelectedWithCallback(caughtUpToHeadHook) =>
    EthArchive(EthArchiveWorker.make(~caughtUpToHeadHook?, chainConfig))
  | RawEventsSelectedWithCallback(caughtUpToHeadHook) =>
    RawEvents(RawEventsWorker.make(~caughtUpToHeadHook?, chainConfig))
  }
}
